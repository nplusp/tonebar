import CoreAudio
import EQCore
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "io.github.nplusp.Tonebar", category: "SystemEqualizer")

/// Keeps a `TapSession` alive on whatever the current output device is.
@Observable
final class SystemEqualizer {
    enum State: Equatable {
        case off
        case needsPermission
        case running(device: String, sampleRate: Double)
        case failed(String)
    }

    private(set) var state: State = .off

    @ObservationIgnored private let equalizer = StereoEqualizer()
    @ObservationIgnored private var settings: EQSettings = .flat
    @ObservationIgnored private var session: TapSession?
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var deviceListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var sampleRateListener: (AudioObjectID, AudioObjectPropertyListenerBlock)?
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var lastRenderedCycles: UInt64 = 0
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var nextRetry = Date.distantPast

    func apply(_ settings: EQSettings) {
        self.settings = settings
        equalizer.update(settings, sampleRate: session?.sampleRate ?? 48_000)
    }

    func start() async {
        wantsRunning = true
        let permission = AudioCapturePermission.status
        log.info("System audio permission: \(String(describing: permission), privacy: .public)")
        switch permission {
        case .authorized:
            break
        case .denied:
            state = .needsPermission
            return
        case .unknown:
            let granted = await AudioCapturePermission.request()
            log.info("System audio permission request answered: \(granted, privacy: .public)")
            guard wantsRunning else { return }
            guard granted else {
                state = .needsPermission
                return
            }
        }
        listenForDefaultDeviceChanges()
        startWatchdog()
        restartSession()
    }

    func stop() {
        wantsRunning = false
        watchdog?.invalidate()
        watchdog = nil
        stopListeningForDefaultDeviceChanges()
        teardownSession()
        state = .off
    }

    private func restartSession() {
        teardownSession()
        guard wantsRunning else { return }
        do {
            let session = try TapSession.start(equalizer: equalizer, settings: settings)
            self.session = session
            lastRenderedCycles = 0
            consecutiveFailures = 0
            listenForSampleRateChanges(of: session)
            state = .running(device: session.deviceName, sampleRate: session.sampleRate)
        } catch {
            // Some failures repeat every time (an unsupported device format), so retries back
            // off from 3 s to a minute instead of rebuilding the route every watchdog tick.
            let delay = min(60, 3 * pow(2, Double(consecutiveFailures)))
            consecutiveFailures += 1
            nextRetry = Date(timeIntervalSinceNow: delay)
            log.error("Could not start: \(String(describing: error), privacy: .public); retrying in \(delay, privacy: .public) s")
            state = .failed(String(describing: error))
        }
    }

    private func teardownSession() {
        if let (device, block) = sampleRateListener {
            var address = HAL.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
            sampleRateListener = nil
        }
        session?.stop()
        session = nil
    }

    private func listenForDefaultDeviceChanges() {
        guard deviceListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.wantsRunning else { return }
                let current = try? HAL.defaultOutputDevice()
                guard current != self.session?.deviceID else { return }
                log.info("Default output device changed")
                self.restartSession()
            }
        }
        var address = HAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        deviceListener = block
    }

    private func stopListeningForDefaultDeviceChanges() {
        guard let deviceListener else { return }
        var address = HAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, deviceListener)
        self.deviceListener = nil
    }

    private func listenForSampleRateChanges(of session: TapSession) {
        let block: AudioObjectPropertyListenerBlock = { [weak self, weak session] _, _ in
            MainActor.assumeIsolated {
                guard let self, let session else { return }
                session.refreshSampleRate(equalizer: self.equalizer, settings: self.settings)
                self.state = .running(device: session.deviceName, sampleRate: session.sampleRate)
            }
        }
        var address = HAL.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectAddPropertyListenerBlock(session.aggregateDeviceID, &address, .main, block)
        sampleRateListener = (session.aggregateDeviceID, block)
    }

    /// The HAL can drop an aggregate device without telling us — after sleep, or when
    /// coreaudiod restarts. If the IO proc stops being called, rebuild the route.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wantsRunning else { return }
                guard let renderer = self.session?.renderer else {
                    if Date() >= self.nextRetry {
                        self.restartSession()
                    }
                    return
                }
                let cycles = renderer.renderedCycles
                let peaks = renderer.takePeaks()
                log.debug("IO cycles \(cycles, privacy: .public), peak in \(peaks.input, privacy: .public) out \(peaks.output, privacy: .public)")
                if cycles == self.lastRenderedCycles {
                    log.notice("IO stalled; rebuilding the audio route")
                    self.restartSession()
                } else {
                    self.lastRenderedCycles = cycles
                }
            }
        }
    }
}

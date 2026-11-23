import CoreAudio
import EQCore
import Foundation
import OSLog

private let log = Logger(subsystem: "io.github.nplusp.Tonebar", category: "TapSession")

/// One live route: system audio → process tap → equalizer → output device.
///
/// The tap mutes every other process only while this session reads it
/// (`mutedWhenTapped`), so if the IO stops for any reason — this app crashing included —
/// the system falls back to playing unprocessed audio instead of going silent.
final class TapSession {
    let deviceName: String
    let deviceID: AudioDeviceID
    private(set) var sampleRate: Double = 0
    private(set) var renderer: TapRenderer?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private init(deviceID: AudioDeviceID, deviceName: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    static func start(equalizer: StereoEqualizer, settings: EQSettings) throws -> TapSession {
        let deviceID = try HAL.defaultOutputDevice()
        guard deviceID != kAudioObjectUnknown else {
            throw CoreAudioError(operation: "find an output device", status: kAudioHardwareBadDeviceError)
        }
        let session = TapSession(deviceID: deviceID, deviceName: (try? HAL.readString(deviceID, kAudioObjectPropertyName)) ?? "Output")
        do {
            try session.build(equalizer: equalizer, settings: settings)
            return session
        } catch {
            session.stop()
            throw error
        }
    }

    private func build(equalizer: StereoEqualizer, settings: EQSettings) throws {
        try HAL.allowIdleSleepDuringIO()
        let deviceUID = try HAL.readString(deviceID, kAudioDevicePropertyDeviceUID)

        let excluded = try HAL.currentProcessObject().map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "Tonebar"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try HAL.check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")

        let tapFormat = try HAL.read(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard HAL.isFloat32(tapFormat) else {
            throw CoreAudioError(operation: "use the tap's sample format", status: kAudioDeviceUnsupportedFormatError)
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tonebar",
            kAudioAggregateDeviceUIDKey: "io.github.nplusp.Tonebar.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try HAL.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")

        for stream in try HAL.readArray(aggregateID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, of: AudioStreamID.self) {
            let format = try HAL.read(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
            guard HAL.isFloat32(format) else {
                throw CoreAudioError(operation: "use \(deviceName)'s sample format", status: kAudioDeviceUnsupportedFormatError)
            }
        }

        // The aggregate lists the device's own input streams (a headset microphone) before the tap.
        let deviceInputStreams = try HAL.readArray(deviceID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, of: AudioStreamID.self).count
        let aggregateInputStreams = try HAL.readArray(aggregateID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, of: AudioStreamID.self).count

        sampleRate = try HAL.read(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
        equalizer.update(settings, sampleRate: sampleRate)
        equalizer.reset()
        let renderer = TapRenderer(equalizer: equalizer, tapBufferIndex: deviceInputStreams)
        self.renderer = renderer

        try HAL.check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, Self.ioBlock(renderer)), "create IO proc")
        if deviceInputStreams > 0 {
            try disableInputStreams(before: deviceInputStreams, of: aggregateInputStreams)
        }
        try HAL.check(AudioDeviceStart(aggregateID, ioProcID), "start IO")

        log.info("""
            Routing through \(self.deviceName, privacy: .public) at \(self.sampleRate, privacy: .public) Hz; \
            tap \(tapFormat.mChannelsPerFrame, privacy: .public)ch, \
            input streams device=\(deviceInputStreams, privacy: .public) aggregate=\(aggregateInputStreams, privacy: .public)
            """)
    }

    /// Opening a headset's microphone would switch Bluetooth headphones to their low-quality
    /// call profile, so the IO proc only takes the tap's streams.
    private func disableInputStreams(before tapIndex: Int, of streamCount: Int) throws {
        guard let ioProcID, streamCount > tapIndex else { return }
        let headerSize = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let size = headerSize + MemoryLayout<UInt32>.stride * streamCount
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }

        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(streamCount)
        let isOn = (raw + headerSize).bindMemory(to: UInt32.self, capacity: streamCount)
        for stream in 0..<streamCount {
            isOn[stream] = stream < tapIndex ? 0 : 1
        }
        var address = HAL.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        try HAL.check(AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(size), raw), "disable device input streams")
    }

    /// Built outside the main actor: the HAL calls it on its real-time IO thread.
    nonisolated private static func ioBlock(_ renderer: TapRenderer) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in renderer.render(input: input, output: output) }
    }

    func refreshSampleRate(equalizer: StereoEqualizer, settings: EQSettings) {
        guard let rate = try? HAL.read(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)),
              rate > 0, rate != sampleRate else { return }
        sampleRate = rate
        equalizer.update(settings, sampleRate: rate)
        log.info("Sample rate changed to \(rate, privacy: .public) Hz")
    }

    var aggregateDeviceID: AudioObjectID { aggregateID }

    /// Tears down in reverse order of creation; safe on a partially built session.
    func stop() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        renderer = nil
    }
}

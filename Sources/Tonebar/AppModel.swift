import EQCore
import Foundation
import Observation
import OSLog
import ServiceManagement

private let log = Logger(subsystem: "io.github.nplusp.Tonebar", category: "AppModel")

@Observable
final class AppModel {
    private enum Key {
        static let settings = "settings"
        static let isEnabled = "isEnabled"
        static let didAutoRegisterLoginItem = "didAutoRegisterLoginItem"
    }

    let engine = SystemEqualizer()

    var settings: EQSettings {
        didSet {
            guard settings != oldValue else { return }
            engine.apply(settings)
            if let data = try? JSONEncoder().encode(settings) {
                defaults.set(data, forKey: Key.settings)
            }
        }
    }

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Key.isEnabled)
            syncEngine()
        }
    }

    private(set) var launchesAtLogin: Bool

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: Key.settings)
            .flatMap { try? JSONDecoder().decode(EQSettings.self, from: $0) } ?? .flat
        isEnabled = defaults.object(forKey: Key.isEnabled) as? Bool ?? true
        launchesAtLogin = SMAppService.mainApp.status == .enabled

        // Launch at login is on by default, once: if the user turns it off later, it stays off.
        if !defaults.bool(forKey: Key.didAutoRegisterLoginItem) {
            defaults.set(true, forKey: Key.didAutoRegisterLoginItem)
            setLaunchesAtLogin(true)
        }

        engine.apply(settings)
        syncEngine()
    }

    var activePreset: Preset? { Preset.matching(settings) }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    func retry() {
        engine.stop()
        syncEngine()
    }

    private func syncEngine() {
        if isEnabled {
            Task { await engine.start() }
        } else {
            engine.stop()
        }
    }
}

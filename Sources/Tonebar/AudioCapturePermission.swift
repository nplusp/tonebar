import Foundation

/// "System Audio Recording" permission, which a process tap needs to hear other apps.
///
/// macOS has no public API to query or request it, so this goes through the private TCC
/// framework the way Apple's own clients do. If the framework or its symbols are missing,
/// the status is reported as `.unknown` and the system prompts on first use instead.
enum AudioCapturePermission {
    enum Status { case authorized, denied, unknown }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @Sendable @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
        guard let framework, let pointer = dlsym(framework, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static var status: Status {
        guard let preflight = symbol("TCCAccessPreflight", as: Preflight.self) else { return .unknown }
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user hasn't decided yet; returns the decision.
    static func request() async -> Bool {
        guard let request = symbol("TCCAccessRequest", as: Request.self) else { return true }
        return await withCheckedContinuation { continuation in
            // TCC answers on its own queue, so the callback must not inherit main-actor isolation.
            request(service, nil) { @Sendable granted in continuation.resume(returning: granted) }
        }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
}

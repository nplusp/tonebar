import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let operation: String
    let status: OSStatus

    var description: String {
        "\(operation) failed (\(HAL.fourCC(UInt32(bitPattern: status)).map { "'\($0)'" } ?? "\(status)"))"
    }
}

/// Thin typed wrappers over the AudioObject property C API.
nonisolated enum HAL {
    static func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
        guard status == noErr else { throw CoreAudioError(operation: operation(), status: status) }
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<Value: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                            initial: Value) throws -> Value {
        var address = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<Value>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "read \(name(selector))")
        return value
    }

    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "read \(name(selector))")
        guard let value else { throw CoreAudioError(operation: "read \(name(selector))", status: kAudioHardwareUnspecifiedError) }
        return value.takeRetainedValue() as String
    }

    static func readArray<Element>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                   of _: Element.Type) throws -> [Element] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "size \(name(selector))")
        let count = Int(size) / MemoryLayout<Element>.stride
        guard count > 0 else { return [] }
        return try [Element](unsafeUninitializedCapacity: count) { buffer, initialized in
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!), "read \(name(selector))")
            initialized = Int(size) / MemoryLayout<Element>.stride
        }
    }

    static func defaultOutputDevice() throws -> AudioDeviceID {
        try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(kAudioObjectUnknown))
    }

    /// The HAL's object for this process, used to keep our own output out of the tap.
    /// Nil if the HAL has not registered us as a client yet.
    static func currentProcessObject() throws -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                             UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
                  "translate pid to process object")
        return object == kAudioObjectUnknown ? nil : object
    }

    /// By default any running IO keeps the Mac from idle sleep. The equalizer's IO runs
    /// even in silence, so it opts out; apps actually playing audio still hold their own
    /// assertion, so sleep is not allowed mid-song.
    static func allowIdleSleepDuringIO() throws {
        var address = address(kAudioHardwarePropertySleepingIsAllowed)
        var allowed: UInt32 = 1
        try check(AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                             UInt32(MemoryLayout<UInt32>.size), &allowed),
                  "allow idle sleep")
    }

    static func isFloat32(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
    }

    /// Core Audio selectors and many error codes are four printable ASCII characters.
    static func fourCC(_ value: UInt32) -> String? {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func name(_ selector: AudioObjectPropertySelector) -> String {
        fourCC(selector) ?? "\(selector)"
    }
}

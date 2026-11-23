import CoreAudio
import Synchronization

/// Moves one IO cycle of audio from a process tap to an output device through the equalizer.
///
/// The aggregate device's input buffer list holds the output device's own input streams
/// first (a headset microphone, say) and the tap's streams after them; `tapBufferIndex`
/// is where the tap starts. Samples are 32-bit float, the HAL's IO format.
///
/// Output mapping: the first two output channels get left and right, a mono output gets
/// their average, and any further channels (surround, extra outputs) get silence.
public final class TapRenderer: @unchecked Sendable {
    public static let chunkCapacity = 4096

    public let equalizer: StereoEqualizer
    public let tapBufferIndex: Int

    private let left: UnsafeMutableBufferPointer<Float>
    private let right: UnsafeMutableBufferPointer<Float>
    private let cycles = Atomic<UInt64>(0)
    private let inputPeakBits = Atomic<UInt32>(0)
    private let outputPeakBits = Atomic<UInt32>(0)

    public init(equalizer: StereoEqualizer, tapBufferIndex: Int) {
        self.equalizer = equalizer
        self.tapBufferIndex = tapBufferIndex
        left = .allocate(capacity: Self.chunkCapacity)
        right = .allocate(capacity: Self.chunkCapacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// IO cycles rendered so far; lets the owner notice a stalled device.
    public var renderedCycles: UInt64 { cycles.load(ordering: .relaxed) }

    /// Loudest absolute sample before and after the equalizer since the previous call.
    /// For diagnostics only: a reset racing with the IO thread may drop one buffer's peak.
    public func takePeaks() -> (input: Float, output: Float) {
        (Float(bitPattern: inputPeakBits.exchange(0, ordering: .relaxed)),
         Float(bitPattern: outputPeakBits.exchange(0, ordering: .relaxed)))
    }

    public func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        cycles.add(1, ordering: .relaxed)
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        let frameCount = tapBufferIndex < inputs.count ? Self.frameCount(inputs[tapBufferIndex]) : 0

        var start = 0
        while start < frameCount {
            let count = min(Self.chunkCapacity, frameCount - start)
            let chunkLeft = UnsafeMutableBufferPointer(rebasing: left[0..<count])
            let chunkRight = UnsafeMutableBufferPointer(rebasing: right[0..<count])
            gather(from: inputs, start: start, into: chunkLeft, chunkRight)
            Self.recordPeak(of: chunkLeft, chunkRight, in: inputPeakBits)
            equalizer.process(left: chunkLeft, right: chunkRight)
            Self.recordPeak(of: chunkLeft, chunkRight, in: outputPeakBits)
            scatter(chunkLeft, chunkRight, to: outputs, start: start)
            start += count
        }

        for buffer in outputs {
            let frames = Self.frameCount(buffer)
            guard frames > frameCount, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = Int(buffer.mNumberChannels)
            (data + frameCount * channels).update(repeating: 0, count: (frames - frameCount) * channels)
        }
    }

    private static func recordPeak(of left: UnsafeMutableBufferPointer<Float>, _ right: UnsafeMutableBufferPointer<Float>,
                                   in storage: borrowing Atomic<UInt32>) {
        var peak: Float = 0
        for index in 0..<left.count {
            peak = max(peak, abs(left[index]), abs(right[index]))
        }
        if peak > Float(bitPattern: storage.load(ordering: .relaxed)) {
            storage.store(peak.bitPattern, ordering: .relaxed)
        }
    }

    private static func frameCount(_ buffer: AudioBuffer) -> Int {
        guard buffer.mNumberChannels > 0, buffer.mData != nil else { return 0 }
        return Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / Int(buffer.mNumberChannels)
    }

    private func gather(from buffers: UnsafeMutableAudioBufferListPointer, start: Int,
                        into left: UnsafeMutableBufferPointer<Float>, _ right: UnsafeMutableBufferPointer<Float>) {
        var filled = 0
        for index in tapBufferIndex..<buffers.count where filled < 2 {
            let buffer = buffers[index]
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = Int(buffer.mNumberChannels)
            let available = max(0, min(left.count, Self.frameCount(buffer) - start))
            for channel in 0..<channels where filled < 2 {
                let destination = filled == 0 ? left : right
                for frame in 0..<available {
                    destination[frame] = data[(start + frame) * channels + channel]
                }
                for frame in available..<destination.count {
                    destination[frame] = 0
                }
                filled += 1
            }
        }
        switch filled {
        case 0:
            left.update(repeating: 0)
            right.update(repeating: 0)
        case 1:
            _ = right.update(fromContentsOf: left)
        default:
            break
        }
    }

    private func scatter(_ left: UnsafeMutableBufferPointer<Float>, _ right: UnsafeMutableBufferPointer<Float>,
                         to buffers: UnsafeMutableAudioBufferListPointer, start: Int) {
        let totalChannels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        var channelBase = 0
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            defer { channelBase += channels }
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let writable = max(0, min(left.count, Self.frameCount(buffer) - start))
            for channel in 0..<channels {
                let outputChannel = channelBase + channel
                for frame in 0..<writable {
                    let sample: Float = switch (totalChannels, outputChannel) {
                    case (1, _): (left[frame] + right[frame]) * 0.5
                    case (_, 0): left[frame]
                    case (_, 1): right[frame]
                    default: 0
                    }
                    data[(start + frame) * channels + channel] = sample
                }
            }
        }
    }
}

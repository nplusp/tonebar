import CoreAudio
import Testing
@testable import EQCore

/// Owns interleaved float buffers laid out like a HAL IO buffer list.
private final class BufferList {
    let list: UnsafeMutableAudioBufferListPointer
    private let storage: [UnsafeMutableBufferPointer<Float>]

    /// `layout` is the channel count of each buffer; `fill(buffer, frame, channel)` gives the samples.
    init(frames: Int, layout: [Int], fill: (Int, Int, Int) -> Float = { _, _, _ in .nan }) {
        list = AudioBufferList.allocate(maximumBuffers: layout.count)
        storage = layout.map { .allocate(capacity: frames * $0) }
        for (index, channels) in layout.enumerated() {
            for frame in 0..<frames {
                for channel in 0..<channels {
                    storage[index][frame * channels + channel] = fill(index, frame, channel)
                }
            }
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(frames * channels * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(storage[index].baseAddress)
            )
        }
    }

    deinit {
        storage.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }

    func sample(buffer: Int, frame: Int, channel: Int) -> Float {
        storage[buffer][frame * Int(list[buffer].mNumberChannels) + channel]
    }
}

private func render(_ renderer: TapRenderer, _ input: BufferList, _ output: BufferList) {
    renderer.render(input: UnsafePointer(input.list.unsafeMutablePointer), output: output.list.unsafeMutablePointer)
}

/// Left channel ramps up, right ramps down, so a swapped or duplicated channel is visible.
/// Kept under the limiter's ceiling for every buffer size used here.
private func stereoRamp(_ frame: Int, _ channel: Int) -> Float {
    channel == 0 ? Float(frame) / 10_000 : -Float(frame) / 10_000
}

@Suite struct TapRendererTests {
    private let flat = StereoEqualizer(settings: .flat)

    @Test func `interleaved stereo tap reaches a stereo output unchanged`() {
        let renderer = TapRenderer(equalizer: flat, tapBufferIndex: 0)
        let input = BufferList(frames: 256, layout: [2]) { _, frame, channel in stereoRamp(frame, channel) }
        let output = BufferList(frames: 256, layout: [2])
        render(renderer, input, output)

        for frame in 0..<256 {
            #expect(output.sample(buffer: 0, frame: frame, channel: 0) == stereoRamp(frame, 0))
            #expect(output.sample(buffer: 0, frame: frame, channel: 1) == stereoRamp(frame, 1))
        }
        #expect(renderer.renderedCycles == 1)
    }

    @Test func `device microphone streams before the tap are skipped`() {
        let renderer = TapRenderer(equalizer: flat, tapBufferIndex: 1)
        // Buffer 0 is a headset mic full of 9s; buffer 1 is the tap.
        let input = BufferList(frames: 64, layout: [1, 2]) { buffer, frame, channel in
            buffer == 0 ? 9 : stereoRamp(frame, channel)
        }
        let output = BufferList(frames: 64, layout: [2])
        render(renderer, input, output)

        #expect(output.sample(buffer: 0, frame: 10, channel: 0) == stereoRamp(10, 0))
        #expect(output.sample(buffer: 0, frame: 10, channel: 1) == stereoRamp(10, 1))
    }

    @Test func `non-interleaved tap and output are mapped channel by channel`() {
        let renderer = TapRenderer(equalizer: flat, tapBufferIndex: 0)
        let input = BufferList(frames: 32, layout: [1, 1]) { buffer, frame, _ in stereoRamp(frame, buffer) }
        let output = BufferList(frames: 32, layout: [1, 1])
        render(renderer, input, output)

        #expect(output.sample(buffer: 0, frame: 7, channel: 0) == stereoRamp(7, 0))
        #expect(output.sample(buffer: 1, frame: 7, channel: 0) == stereoRamp(7, 1))
    }

    @Test func `mono output gets the average of both channels`() {
        let renderer = TapRenderer(equalizer: flat, tapBufferIndex: 0)
        let input = BufferList(frames: 16, layout: [2]) { _, _, channel in channel == 0 ? 0.5 : 0.25 }
        let output = BufferList(frames: 16, layout: [1])
        render(renderer, input, output)

        #expect(output.sample(buffer: 0, frame: 3, channel: 0) == 0.375)
    }

    @Test func `mono tap is copied to both output channels`() {
        let renderer = TapRenderer(equalizer: flat, tapBufferIndex: 0)
        let input = BufferList(frames: 16, layout: [1]) { _, _, _ in 0.5 }
        let output = BufferList(frames: 16, layout: [2])
        render(renderer, input, output)

        #expect(output.sample(buffer: 0, frame: 3, channel: 0) == 0.5)
        #expect(output.sample(buffer: 0, frame: 3, channel: 1) == 0.5)
    }

    @Test func `surround channels beyond the front pair are silenced`() {
        let renderer = TapRenderer(equalizer: flat, tapBufferIndex: 0)
        let input = BufferList(frames: 16, layout: [2]) { _, _, _ in 0.5 }
        let output = BufferList(frames: 16, layout: [6])
        render(renderer, input, output)

        for channel in 2..<6 {
            #expect(output.sample(buffer: 0, frame: 5, channel: channel) == 0)
        }
        #expect(output.sample(buffer: 0, frame: 5, channel: 0) == 0.5)
    }

    @Test func `missing tap stream renders silence instead of garbage`() {
        let renderer = TapRenderer(equalizer: flat, tapBufferIndex: 3)
        let input = BufferList(frames: 16, layout: [2]) { _, _, _ in 0.5 }
        let output = BufferList(frames: 16, layout: [2])
        render(renderer, input, output)

        for frame in 0..<16 {
            #expect(output.sample(buffer: 0, frame: frame, channel: 0) == 0)
        }
    }

    @Test func `buffers larger than one chunk are processed completely`() {
        let frames = TapRenderer.chunkCapacity * 2 + 17
        let renderer = TapRenderer(equalizer: flat, tapBufferIndex: 0)
        let input = BufferList(frames: frames, layout: [2]) { _, frame, channel in stereoRamp(frame, channel) }
        let output = BufferList(frames: frames, layout: [2])
        render(renderer, input, output)

        for frame in [0, TapRenderer.chunkCapacity - 1, TapRenderer.chunkCapacity, frames - 1] {
            #expect(output.sample(buffer: 0, frame: frame, channel: 0) == stereoRamp(frame, 0))
            #expect(output.sample(buffer: 0, frame: frame, channel: 1) == stereoRamp(frame, 1))
        }
    }

    @Test func `equalizer is applied on the way through`() {
        let renderer = TapRenderer(equalizer: StereoEqualizer(settings: EQSettings(gains: [], preamp: -6)), tapBufferIndex: 0)
        let input = BufferList(frames: 16, layout: [2]) { _, _, _ in 0.5 }
        let output = BufferList(frames: 16, layout: [2])
        render(renderer, input, output)

        #expect(abs(output.sample(buffer: 0, frame: 8, channel: 0) - 0.5 * 0.50118723) < 1e-6)
    }
}

@Suite struct TapRendererPeakTests {
    @Test func `peaks report the level before and after the equalizer, then reset`() {
        let renderer = TapRenderer(equalizer: StereoEqualizer(settings: EQSettings(gains: [], preamp: -12)), tapBufferIndex: 0)
        let input = BufferList(frames: 64, layout: [2]) { _, frame, _ in frame == 10 ? -0.8 : 0.1 }
        let output = BufferList(frames: 64, layout: [2])
        render(renderer, input, output)

        let peaks = renderer.takePeaks()
        #expect(peaks.input == 0.8)
        #expect(abs(peaks.output - 0.8 * 0.25118864) < 1e-6)
        #expect(renderer.takePeaks() == (0, 0))
    }
}

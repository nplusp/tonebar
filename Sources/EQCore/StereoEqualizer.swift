import Foundation
import Synchronization

/// The filter chain that runs on the Core Audio IO thread.
///
/// Threading contract: `update(_:sampleRate:)` and `reset()` may be called from any thread;
/// `process(left:right:)` must only be called from one thread at a time (the audio IO
/// thread). The IO thread never blocks: if an update is being written at that moment,
/// it keeps the previous coefficients for one more buffer.
public final class StereoEqualizer: @unchecked Sendable {
    private struct Parameters {
        var coefficients: [BiquadCoefficients]
        var preampLinear: Float
        var limiterRelease: Double
        var generation: UInt64
    }

    private struct ChannelState {
        var z1: Double = 0
        var z2: Double = 0
    }

    /// Output ceiling, just under full scale so converters never see an overshoot.
    public static let ceiling: Float = 0.98
    /// Time for the limiter to recover about 63 % of its gain reduction.
    public static let limiterReleaseSeconds = 0.15

    private let bandCount = EQSettings.bandFrequencies.count
    private let shared: Mutex<Parameters>

    // Owned by the IO thread. Sized once here so processing never allocates.
    private var active: [BiquadCoefficients]
    private var activePreamp: Float = 1
    private var activeGeneration: UInt64 = .max
    private var activeLimiterRelease: Double = 0
    // Double, not Float: near unity the per-sample recovery step falls below Float's
    // resolution and the gain would stall just under 1 forever.
    private var limiterGain: Double = 1
    private var leftState: [ChannelState]
    private var rightState: [ChannelState]
    private let resetRequested = Atomic<Bool>(false)

    public init(settings: EQSettings = .flat, sampleRate: Double = 48_000) {
        active = Array(repeating: .identity, count: bandCount)
        leftState = Array(repeating: ChannelState(), count: bandCount)
        rightState = Array(repeating: ChannelState(), count: bandCount)
        shared = Mutex(Parameters(
            coefficients: settings.coefficients(sampleRate: sampleRate),
            preampLinear: Float(pow(10, settings.preamp / 20)),
            limiterRelease: Self.releaseCoefficient(sampleRate: sampleRate),
            generation: 0
        ))
    }

    public func update(_ settings: EQSettings, sampleRate: Double) {
        let coefficients = settings.coefficients(sampleRate: sampleRate)
        let preamp = Float(pow(10, settings.preamp / 20))
        let release = Self.releaseCoefficient(sampleRate: sampleRate)
        shared.withLock { parameters in
            parameters.coefficients = coefficients
            parameters.preampLinear = preamp
            parameters.limiterRelease = release
            parameters.generation &+= 1
        }
    }

    /// Clears filter memory before the next buffer, so audio from a previous stream
    /// (another device, a stopped session) doesn't ring into the new one.
    public func reset() {
        resetRequested.store(true, ordering: .releasing)
    }

    public func process(left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>) {
        precondition(left.count == right.count, "stereo channels must have the same frame count")
        adoptPendingParameters()

        if resetRequested.exchange(false, ordering: .acquiring) {
            for band in 0..<bandCount {
                leftState[band] = ChannelState()
                rightState[band] = ChannelState()
            }
            limiterGain = 1
        }

        // A NaN or infinite sample from any app would otherwise live in the filter state
        // forever (silencing it) and reach the device as a click.
        let preamp = activePreamp
        for index in 0..<left.count {
            left[index] = left[index].isFinite ? left[index] * preamp : 0
            right[index] = right[index].isFinite ? right[index] * preamp : 0
        }

        for band in 0..<bandCount where active[band] != .identity {
            let filter = active[band]
            Self.run(filter, on: left, state: &leftState[band])
            Self.run(filter, on: right, state: &rightState[band])
        }
        limit(left: left, right: right)
    }

    /// Boosts plus the phase shift of the filters can push peaks past full scale even when
    /// the preamp cancels the boost on paper, and the device would clip them hard.
    /// Gain drops instantly to whatever keeps the louder channel at the ceiling (so nothing
    /// ever exceeds it) and recovers exponentially. Below the ceiling it is bit-transparent.
    private func limit(left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>) {
        let ceiling = Self.ceiling
        let release = activeLimiterRelease
        var gain = limiterGain
        for index in 0..<left.count {
            let peak = Double(max(abs(left[index]), abs(right[index])))
            if gain < 1 {
                gain = min(1, gain + (1 - gain) * release)
                if gain > 0.99999 { gain = 1 }
            }
            if peak * gain > Double(ceiling) {
                gain = Double(ceiling) / peak
            }
            if gain < 1 {
                let scale = Float(gain)
                // Rounding can land one ulp above the ceiling.
                left[index] = min(ceiling, max(-ceiling, left[index] * scale))
                right[index] = min(ceiling, max(-ceiling, right[index] * scale))
            }
        }
        limiterGain = gain
    }

    private static func releaseCoefficient(sampleRate: Double) -> Double {
        1 - exp(-1 / (limiterReleaseSeconds * sampleRate))
    }

    private func adoptPendingParameters() {
        shared.withLockIfAvailable { parameters in
            guard parameters.generation != activeGeneration else { return }
            for band in 0..<bandCount {
                let next = parameters.coefficients[band]
                // A band switched to bypass would otherwise keep its old memory and
                // replay it as a click when it is turned back on.
                if next == .identity && active[band] != .identity {
                    leftState[band] = ChannelState()
                    rightState[band] = ChannelState()
                }
                active[band] = next
            }
            activePreamp = parameters.preampLinear
            activeLimiterRelease = parameters.limiterRelease
            activeGeneration = parameters.generation
        }
    }

    /// Transposed direct form II: two state values per filter, and well behaved in floating
    /// point when coefficients change between buffers.
    private static func run(_ filter: BiquadCoefficients, on samples: UnsafeMutableBufferPointer<Float>, state: inout ChannelState) {
        var z1 = state.z1
        var z2 = state.z2
        for index in 0..<samples.count {
            let input = Double(samples[index])
            let output = filter.b0 * input + z1
            z1 = filter.b1 * input - filter.a1 * output + z2
            z2 = filter.b2 * input - filter.a2 * output
            samples[index] = Float(output)
        }
        // Decaying tails turn subnormal after a long silence, and subnormal arithmetic
        // is very slow on Intel CPUs.
        if abs(z1) < 1e-25 { z1 = 0 }
        if abs(z2) < 1e-25 { z2 = 0 }
        state.z1 = z1
        state.z2 = z2
    }
}

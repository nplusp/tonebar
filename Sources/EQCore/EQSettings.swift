import Foundation

/// What the user dialed in: one gain per band plus a preamp, all in decibels.
public struct EQSettings: Codable, Sendable, Equatable {
    /// ISO octave centers of a classic 10-band graphic equalizer.
    public static let bandFrequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let gainRange: ClosedRange<Double> = -12...12
    public static let preampRange: ClosedRange<Double> = -12...12
    /// Q ≈ √2 is a one-octave bandwidth, matching the octave spacing of the bands.
    public static let bandQ: Double = 1.41

    public private(set) var gains: [Double]
    public private(set) var preamp: Double

    public static let flat = EQSettings(gains: Array(repeating: 0, count: bandFrequencies.count), preamp: 0)

    /// Out-of-range values are clamped, NaN becomes 0 dB, and a gain list of the wrong length is padded with
    /// zeros or truncated, so a hand-edited or stale saved value can never reach the DSP.
    public init(gains: [Double], preamp: Double) {
        let count = Self.bandFrequencies.count
        let fitted = Array((gains + Array(repeating: 0, count: count)).prefix(count))
        self.gains = fitted.map { $0.sanitized(to: Self.gainRange) }
        self.preamp = preamp.sanitized(to: Self.preampRange)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            gains: try container.decode([Double].self, forKey: .gains),
            preamp: try container.decode(Double.self, forKey: .preamp)
        )
    }

    public mutating func setGain(_ gain: Double, band: Int) {
        gains[band] = gain.sanitized(to: Self.gainRange)
    }

    public mutating func setPreamp(_ value: Double) {
        preamp = value.sanitized(to: Self.preampRange)
    }

    public var isFlat: Bool { self == .flat }

    public func coefficients(sampleRate: Double) -> [BiquadCoefficients] {
        zip(Self.bandFrequencies, gains).map { frequency, gain in
            .peaking(frequency: frequency, gainDB: gain, q: Self.bandQ, sampleRate: sampleRate)
        }
    }

    /// Combined response of every band and the preamp at `frequency`, in dB.
    public func responseDB(at frequency: Double, sampleRate: Double) -> Double {
        let bands = coefficients(sampleRate: sampleRate).reduce(0) { total, filter in
            total + 20 * log10(filter.magnitude(at: frequency, sampleRate: sampleRate))
        }
        return bands + preamp
    }
}

extension Double {
    /// `min`/`max` pass NaN straight through, so it is mapped to 0 dB explicitly.
    func sanitized(to range: ClosedRange<Double>) -> Double {
        isNaN ? 0 : Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

import Foundation

/// Second-order IIR filter coefficients, normalized so that `a0 == 1`.
public struct BiquadCoefficients: Sendable, Equatable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double

    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// Peaking EQ from the RBJ Audio EQ Cookbook
    /// (https://www.w3.org/TR/audio-eq-cookbook/).
    ///
    /// Returns `.identity` for a 0 dB gain, and for a center frequency too close to Nyquist
    /// for the bilinear transform to place it (≥ 45 % of the sample rate): such a band cannot
    /// be represented at this rate, and a filter warped past Nyquist would boost the wrong range.
    public static func peaking(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        precondition(sampleRate > 0 && frequency > 0 && q > 0, "peaking filter needs positive frequency, Q and sample rate")
        guard gainDB != 0, frequency < sampleRate * 0.45 else { return .identity }

        let amplitude = pow(10, gainDB / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosOmega = cos(omega)
        let a0 = 1 + alpha / amplitude

        return BiquadCoefficients(
            b0: (1 + alpha * amplitude) / a0,
            b1: (-2 * cosOmega) / a0,
            b2: (1 - alpha * amplitude) / a0,
            a1: (-2 * cosOmega) / a0,
            a2: (1 - alpha / amplitude) / a0
        )
    }

    /// Linear magnitude of the frequency response |H(e^jω)| at `frequency`.
    public func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(omega), sin1 = sin(omega)
        let cos2 = cos(2 * omega), sin2 = sin(2 * omega)

        let numeratorReal = b0 + b1 * cos1 + b2 * cos2
        let numeratorImaginary = -(b1 * sin1 + b2 * sin2)
        let denominatorReal = 1 + a1 * cos1 + a2 * cos2
        let denominatorImaginary = -(a1 * sin1 + a2 * sin2)

        let numerator = numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary
        let denominator = denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary
        return (numerator / denominator).squareRoot()
    }
}

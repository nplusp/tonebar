import Foundation
import Testing
@testable import EQCore

private let sampleRate = 48_000.0

private func decibels(_ linear: Double) -> Double { 20 * log10(linear) }

/// Steady-state peak of a sine at `frequency` after it went through `equalizer`.
private func measuredGainDB(_ equalizer: StereoEqualizer, frequency: Double, amplitude: Float = 0.1) -> Double {
    let frameCount = Int(sampleRate)
    var left = (0..<frameCount).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    var right = left
    left.withUnsafeMutableBufferPointer { leftBuffer in
        right.withUnsafeMutableBufferPointer { rightBuffer in
            // Real IO buffers are small; chunking also exercises state carried across calls.
            var start = 0
            while start < frameCount {
                let count = min(512, frameCount - start)
                equalizer.process(
                    left: UnsafeMutableBufferPointer(rebasing: leftBuffer[start..<start + count]),
                    right: UnsafeMutableBufferPointer(rebasing: rightBuffer[start..<start + count])
                )
                start += count
            }
        }
    }
    // Skip the first half second so the filters have settled.
    let settled = (frameCount / 2)...
    let peak = left[settled].map { abs($0) }.max() ?? 0
    #expect(left[settled].elementsEqual(right[settled]), "channels diverged for identical input")
    return decibels(Double(peak / amplitude))
}

@Suite struct BiquadTests {
    @Test(arguments: [-12.0, -6.0, 3.0, 12.0])
    func `peaking filter reaches its gain at the center frequency`(gain: Double) {
        let filter = BiquadCoefficients.peaking(frequency: 1000, gainDB: gain, q: 1.41, sampleRate: sampleRate)
        #expect(abs(decibels(filter.magnitude(at: 1000, sampleRate: sampleRate)) - gain) < 0.01)
    }

    @Test func `peaking filter leaves far frequencies alone`() {
        let filter = BiquadCoefficients.peaking(frequency: 1000, gainDB: 12, q: 1.41, sampleRate: sampleRate)
        #expect(abs(decibels(filter.magnitude(at: 30, sampleRate: sampleRate))) < 0.1)
        #expect(abs(decibels(filter.magnitude(at: 20_000, sampleRate: sampleRate))) < 0.2)
    }

    @Test func `zero gain is an exact bypass`() {
        #expect(BiquadCoefficients.peaking(frequency: 1000, gainDB: 0, q: 1.41, sampleRate: sampleRate) == .identity)
    }

    @Test func `band too close to Nyquist is bypassed instead of warped`() {
        // At 32 kHz the 16 kHz band sits on Nyquist; at 44.1 kHz it can still be placed.
        #expect(BiquadCoefficients.peaking(frequency: 16_000, gainDB: 6, q: 1.41, sampleRate: 32_000) == .identity)
        #expect(BiquadCoefficients.peaking(frequency: 16_000, gainDB: 6, q: 1.41, sampleRate: 44_100) != .identity)
    }

    @Test(arguments: EQSettings.bandFrequencies)
    func `every band is stable at 44.1 kHz with maximum boost and cut`(frequency: Double) {
        for gain in [EQSettings.gainRange.lowerBound, EQSettings.gainRange.upperBound] {
            let filter = BiquadCoefficients.peaking(frequency: frequency, gainDB: gain, q: EQSettings.bandQ, sampleRate: 44_100)
            // Poles inside the unit circle ⇔ |a2| < 1 and |a1| < 1 + a2.
            #expect(abs(filter.a2) < 1)
            #expect(abs(filter.a1) < 1 + filter.a2)
        }
    }
}

@Suite struct EQSettingsTests {
    @Test func `out-of-range and NaN values are sanitized`() {
        let settings = EQSettings(gains: [40, -40, .nan], preamp: .infinity)
        #expect(settings.gains.count == EQSettings.bandFrequencies.count)
        #expect(settings.gains[0] == 12)
        #expect(settings.gains[1] == -12)
        #expect(settings.gains[2] == 0)
        #expect(settings.gains[3...].allSatisfy { $0 == 0 })
        #expect(settings.preamp == 12)
    }

    @Test func `too many gains are truncated`() {
        let settings = EQSettings(gains: Array(repeating: 3, count: 20), preamp: 0)
        #expect(settings.gains == Array(repeating: 3, count: 10))
    }

    @Test func `decoding goes through the sanitizing initializer`() throws {
        let json = #"{"gains":[99,1],"preamp":-99}"#
        let settings = try JSONDecoder().decode(EQSettings.self, from: Data(json.utf8))
        #expect(settings == EQSettings(gains: [12, 1], preamp: -12))
    }

    @Test func `settings survive a round trip`() throws {
        let original = Preset.all[3].settings
        let decoded = try JSONDecoder().decode(EQSettings.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test func `flat response is 0 dB everywhere`() {
        for frequency in [20.0, 100, 1000, 10_000, 20_000] {
            #expect(EQSettings.flat.responseDB(at: frequency, sampleRate: sampleRate) == 0)
        }
    }
}

@Suite struct PresetTests {
    @Test func `preset names are unique`() {
        #expect(Set(Preset.all.map(\.name)).count == Preset.all.count)
    }

    @Test(arguments: Preset.all)
    func `presets leave headroom`(preset: Preset) {
        let peak = stride(from: 20.0, through: 20_000, by: 5).map {
            preset.settings.responseDB(at: $0, sampleRate: sampleRate)
        }.max() ?? 0
        #expect(peak <= 0.5, "\(preset.name) peaks at \(peak) dB")
    }

    @Test func `matching finds the preset and rejects edits`() {
        var settings = Preset.all[1].settings
        #expect(Preset.matching(settings)?.name == Preset.all[1].name)
        settings.setGain(1, band: 9)
        #expect(Preset.matching(settings) == nil)
    }
}

@Suite struct StereoEqualizerTests {
    @Test func `flat settings pass audio through unchanged`() {
        let equalizer = StereoEqualizer(settings: .flat, sampleRate: sampleRate)
        #expect(abs(measuredGainDB(equalizer, frequency: 440)) < 0.001)
    }

    @Test func `a boosted band raises a sine at its frequency`() {
        var settings = EQSettings.flat
        settings.setGain(6, band: 5)  // 1 kHz
        let equalizer = StereoEqualizer(settings: settings, sampleRate: sampleRate)
        #expect(abs(measuredGainDB(equalizer, frequency: 1000) - 6) < 0.1)
    }

    @Test func `preamp scales the signal`() {
        let equalizer = StereoEqualizer(settings: EQSettings(gains: [], preamp: -6), sampleRate: sampleRate)
        #expect(abs(measuredGainDB(equalizer, frequency: 1000) + 6) < 0.01)
    }

    @Test func `update takes effect on the next buffer`() {
        let equalizer = StereoEqualizer(settings: .flat, sampleRate: sampleRate)
        #expect(abs(measuredGainDB(equalizer, frequency: 125)) < 0.001)

        var settings = EQSettings.flat
        settings.setGain(-9, band: 2)  // 125 Hz
        equalizer.update(settings, sampleRate: sampleRate)
        #expect(abs(measuredGainDB(equalizer, frequency: 125) + 9) < 0.1)
    }

    @Test func `matches the analytic response of the whole chain`() {
        let settings = Preset.all.first { $0.name == "Loudness" }!.settings
        let equalizer = StereoEqualizer(settings: settings, sampleRate: sampleRate)
        for frequency in [64.0, 500, 3000, 12_000] {
            let expected = settings.responseDB(at: frequency, sampleRate: sampleRate)
            #expect(abs(measuredGainDB(equalizer, frequency: frequency) - expected) < 0.15, "at \(frequency) Hz")
            equalizer.reset()
        }
    }

    @Test func `reset clears ringing from the previous stream`() {
        var settings = EQSettings.flat
        settings.setGain(12, band: 0)
        let equalizer = StereoEqualizer(settings: settings, sampleRate: sampleRate)
        _ = measuredGainDB(equalizer, frequency: 32)

        equalizer.reset()
        var left = [Float](repeating: 0, count: 256)
        var right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in equalizer.process(left: l, right: r) }
        }
        #expect(left.allSatisfy { $0 == 0 })
        #expect(right.allSatisfy { $0 == 0 })
    }
}

@Suite struct LimiterTests {
    private func process(_ equalizer: StereoEqualizer, _ left: inout [Float], _ right: inout [Float]) {
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in equalizer.process(left: l, right: r) }
        }
    }

    @Test func `peaks above full scale are held at the ceiling`() {
        let equalizer = StereoEqualizer(settings: EQSettings(gains: [], preamp: 6), sampleRate: sampleRate)
        var left = (0..<4800).map { Float(sin(2 * .pi * 100 * Double($0) / sampleRate)) }
        var right = left.map { $0 * 0.5 }
        process(equalizer, &left, &right)

        #expect(left.map(abs).max()! <= StereoEqualizer.ceiling)
        #expect(left.map(abs).max()! > StereoEqualizer.ceiling * 0.99, "limited too hard")
        // One gain for both channels keeps the stereo image where it was.
        #expect(zip(left, right).allSatisfy { abs($0 * 0.5 - $1) < 1e-6 })
    }

    @Test func `signals below the ceiling pass bit-exact`() {
        let equalizer = StereoEqualizer(settings: .flat, sampleRate: sampleRate)
        let original = (0..<4800).map { 0.9 * Float(sin(2 * .pi * 440 * Double($0) / sampleRate)) }
        var left = original, right = original
        process(equalizer, &left, &right)
        #expect(left == original)
    }

    @Test func `gain recovers after a loud burst`() {
        let equalizer = StereoEqualizer(settings: .flat, sampleRate: sampleRate)
        var burstLeft = [Float](repeating: 2, count: 64), burstRight = burstLeft
        process(equalizer, &burstLeft, &burstRight)
        #expect(burstLeft.allSatisfy { $0 == StereoEqualizer.ceiling })

        var quietLeft = [Float](repeating: 0.5, count: Int(sampleRate) * 2), quietRight = quietLeft
        process(equalizer, &quietLeft, &quietRight)
        #expect(quietLeft.first! < 0.5, "gain should still be reduced right after the burst")
        #expect(quietLeft.last! == 0.5, "gain should be back to unity after two seconds")
    }
}

@Suite struct CorruptInputTests {
    @Test func `a NaN sample does not silence the equalizer for good`() {
        var settings = EQSettings.flat
        settings.setGain(6, band: 5)
        let equalizer = StereoEqualizer(settings: settings, sampleRate: sampleRate)
        var left: [Float] = [0.1, .nan, 0.1], right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in equalizer.process(left: l, right: r) }
        }
        #expect(abs(measuredGainDB(equalizer, frequency: 1000) - 6) < 0.1)
    }

    @Test func `NaN and infinite samples never reach the device`() {
        let equalizer = StereoEqualizer(settings: .flat, sampleRate: sampleRate)
        var left: [Float] = [0.5, .nan, .infinity, -.infinity, 0.5], right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in equalizer.process(left: l, right: r) }
        }
        #expect(left == [0.5, 0, 0, 0, 0.5], "bad samples become silence and don't duck their neighbours")
        #expect(right == left)
    }
}

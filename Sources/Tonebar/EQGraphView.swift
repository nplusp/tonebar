import EQCore
import SwiftUI

/// The frequency-response curve with one draggable knob per band on top of it.
///
/// The x axis is logarithmic and spans ten octave-wide columns, one per band, so each
/// knob stands over its own center frequency. Knobs show each band's gain; the curve is
/// the combined response, which overlapping neighbours push above or below the knobs.
struct EQGraphView: View {
    @Binding var settings: EQSettings
    var isActive: Bool

    @State private var draggedBand: Int?
    @State private var hoveredBand: Int?

    private static let bandCount = EQSettings.bandFrequencies.count
    private static let range = EQSettings.gainRange
    private static let knobSize: CGFloat = 13
    private static let verticalInset: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                grid(in: size)
                curve(in: size)
                ForEach(0..<Self.bandCount, id: \.self) { band in
                    knob(band: band, in: size)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: size))
            .simultaneousGesture(resetGesture(in: size))
            .onContinuousHover { phase in
                if case .active(let location) = phase {
                    hoveredBand = band(atX: location.x, width: size.width)
                } else {
                    hoveredBand = nil
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Equalizer bands")
    }

    private func columnCenter(_ band: Int, width: CGFloat) -> CGFloat {
        width * (CGFloat(band) + 0.5) / CGFloat(Self.bandCount)
    }

    private func band(atX x: CGFloat, width: CGFloat) -> Int {
        min(Self.bandCount - 1, max(0, Int(x / width * CGFloat(Self.bandCount))))
    }

    private func y(forGain gain: Double, height: CGFloat) -> CGFloat {
        let usable = height - Self.verticalInset * 2
        let fraction = (gain - Self.range.lowerBound) / (Self.range.upperBound - Self.range.lowerBound)
        return Self.verticalInset + usable * (1 - CGFloat(fraction))
    }

    private func gain(forY y: CGFloat, height: CGFloat) -> Double {
        let usable = height - Self.verticalInset * 2
        let fraction = 1 - Double((y - Self.verticalInset) / usable)
        let raw = Self.range.lowerBound + fraction * (Self.range.upperBound - Self.range.lowerBound)
        return (raw * 2).rounded() / 2
    }

    /// Maps x to frequency so that column centers land on the band frequencies.
    private func frequency(atX x: CGFloat, width: CGFloat) -> Double {
        let lowest = EQSettings.bandFrequencies[0] / 2.squareRoot()
        let octaves = Double(x / width) * Double(Self.bandCount)
        return lowest * pow(2, octaves)
    }

    private func grid(in size: CGSize) -> some View {
        Canvas { context, size in
            for gain in [-6.0, 6.0] {
                let y = y(forGain: gain, height: size.height)
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                               with: .color(.primary.opacity(0.06)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            let zero = y(forGain: 0, height: size.height)
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: zero)); $0.addLine(to: CGPoint(x: size.width, y: zero)) },
                           with: .color(.primary.opacity(0.14)), lineWidth: 1)
            for band in 0..<Self.bandCount {
                let x = columnCenter(band, width: size.width)
                context.stroke(Path { $0.move(to: CGPoint(x: x, y: Self.verticalInset)); $0.addLine(to: CGPoint(x: x, y: size.height - Self.verticalInset)) },
                               with: .color(.primary.opacity(0.05)), lineWidth: 1)
            }
        }
    }

    private func curve(in size: CGSize) -> some View {
        let bandsOnly = EQSettings(gains: settings.gains, preamp: 0)
        let steps = 160
        let points = (0...steps).map { step -> CGPoint in
            let x = size.width * CGFloat(step) / CGFloat(steps)
            let response = bandsOnly.responseDB(at: frequency(atX: x, width: size.width), sampleRate: 48_000)
            return CGPoint(x: x, y: y(forGain: response.clamped(to: -14...14), height: size.height))
        }
        let line = Path { path in path.addLines(points) }
        let zero = y(forGain: 0, height: size.height)
        let fill = Path { path in
            path.move(to: CGPoint(x: 0, y: zero))
            // Not `addLines`: it starts a new subpath and the fill would close on a diagonal.
            points.forEach { path.addLine(to: $0) }
            path.addLine(to: CGPoint(x: size.width, y: zero))
            path.closeSubpath()
        }
        let tint = isActive ? Color.accentColor : Color.secondary
        return ZStack {
            fill.fill(tint.opacity(0.16))
            line.stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .animation(.smooth(duration: 0.25), value: settings)
    }

    private func knob(band: Int, in size: CGSize) -> some View {
        let gain = settings.gains[band]
        let isFocused = draggedBand == band || (draggedBand == nil && hoveredBand == band)
        let position = CGPoint(x: columnCenter(band, width: size.width), y: y(forGain: gain, height: size.height))

        return ZStack {
            Circle()
                .fill(.background)
                .overlay(Circle().strokeBorder(isActive ? Color.accentColor : .secondary, lineWidth: 2))
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .frame(width: Self.knobSize, height: Self.knobSize)
                .scaleEffect(isFocused ? 1.25 : 1)

            if isFocused {
                Text(Self.format(gain))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
                    .offset(y: gain > 6 ? 18 : -18)
                    .transition(.opacity)
            }
        }
        .position(position)
        .animation(.snappy(duration: 0.18), value: isFocused)
        .accessibilityElement()
        .accessibilityLabel(Self.label(forBand: band))
        .accessibilityValue(Self.format(gain))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: settings.setGain(gain + 0.5, band: band)
            case .decrement: settings.setGain(gain - 0.5, band: band)
            @unknown default: break
            }
        }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let band = draggedBand ?? band(atX: value.startLocation.x, width: size.width)
                draggedBand = band
                settings.setGain(gain(forY: value.location.y, height: size.height), band: band)
            }
            .onEnded { _ in draggedBand = nil }
    }

    private func resetGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2).onEnded { value in
            settings.setGain(0, band: band(atX: value.location.x, width: size.width))
        }
    }

    static func label(forBand band: Int) -> String {
        let frequency = EQSettings.bandFrequencies[band]
        return frequency >= 1000 ? "\(Int(frequency / 1000))K" : "\(Int(frequency))"
    }

    static func format(_ gain: Double) -> String {
        let magnitude = abs(gain).formatted(.number.precision(.fractionLength(gain.rounded() == gain ? 0 : 1)))
        return gain > 0 ? "+\(magnitude)" : gain < 0 ? "−\(magnitude)" : "0"
    }
}

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

public struct Preset: Sendable, Identifiable, Equatable {
    public let name: String
    public let settings: EQSettings

    public var id: String { name }

    public init(name: String, gains: [Double], preamp: Double) {
        self.name = name
        self.settings = EQSettings(gains: gains, preamp: preamp)
    }

    // Overlapping bands add up, so each curve peaks above its largest gain. Every preamp
    // pulls that peak back to about 0 dB; a boost without headroom clips on loud material.
    public static let all: [Preset] = [
        Preset(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], preamp: 0),
        Preset(name: "Bass Boost", gains: [6, 5.5, 4.5, 2.5, 0.5, 0, 0, 0, 0, 0], preamp: -7.5),
        Preset(name: "Bass Cut", gains: [-6, -5, -3.5, -1.5, 0, 0, 0, 0, 0, 0], preamp: 0),
        Preset(name: "Treble Boost", gains: [0, 0, 0, 0, 0, 0.5, 2, 4, 5.5, 6], preamp: -6.5),
        Preset(name: "Loudness", gains: [5, 4, 2, 0, -1, 0, 0, 1.5, 3.5, 4.5], preamp: -5.5),
        Preset(name: "Vocal", gains: [-3, -2.5, -1, 1, 3, 3.5, 3, 1.5, 0, -1], preamp: -4.5),
        Preset(name: "Podcast", gains: [-6, -5, -2, 1, 2.5, 3.5, 3.5, 2, 0, -2], preamp: -4.5),
        Preset(name: "Rock", gains: [4.5, 3.5, 2, 0, -1, -1, 0.5, 2, 3.5, 4], preamp: -5),
        Preset(name: "Electronic", gains: [5, 4.5, 1.5, 0, -2, 0.5, 0, 1, 4, 5], preamp: -5.5),
        Preset(name: "Acoustic", gains: [3, 3, 2, 1, 1, 1, 2, 2.5, 2, 1], preamp: -4),
        Preset(name: "Laptop Speakers", gains: [-4, -1, 3, 3, 1, 0, 0, 1.5, 2, 0], preamp: -3.5),
    ]

    public static func matching(_ settings: EQSettings) -> Preset? {
        all.first { $0.settings == settings }
    }
}

// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tonebar",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "EQCore"),
        .executableTarget(
            name: "Tonebar",
            dependencies: ["EQCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "EQCoreTests", dependencies: ["EQCore"]),
    ]
)

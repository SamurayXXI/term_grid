// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TermGrid",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "GridCore"),
        .target(
            name: "ProbeKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TermGrid",
            dependencies: ["GridCore", "ProbeKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "tgprobe",
            dependencies: ["ProbeKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "GridCoreTests", dependencies: ["GridCore"]),
    ]
)

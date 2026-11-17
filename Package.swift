// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TermGrid",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "GridCore"),
        .executableTarget(
            name: "TermGrid",
            dependencies: ["GridCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "tgprobe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "GridCoreTests", dependencies: ["GridCore"]),
    ]
)

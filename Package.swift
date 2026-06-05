// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "diskwipe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "diskwipe-engine",
            path: "Sources/diskwipe-engine",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DiskWipeApp",
            path: "Sources/DiskWipeApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

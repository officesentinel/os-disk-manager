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
        ),
        // P2.1: unit tests for pure functions inside the engine.
        // SPM lets a testTarget `@testable import` an executable target on
        // Swift 5.5+; main.swift's top-level code is wrapped into a synthetic
        // entry point and is NOT executed when the module is imported.
        .testTarget(
            name: "DiskwipeEngineTests",
            dependencies: ["diskwipe-engine"],
            path: "Tests/DiskwipeEngineTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

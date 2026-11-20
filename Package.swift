// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacStorageIntelligence",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "StorageCore", targets: ["StorageCore"]),
        .executable(name: "MacStorageIntelligence", targets: ["StorageApp"])
    ],
    targets: [
        .target(name: "StorageCore"),
        .executableTarget(name: "StorageApp", dependencies: ["StorageCore"]),
        .testTarget(name: "StorageCoreTests", dependencies: ["StorageCore"])
    ]
)

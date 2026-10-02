// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BLEProximity",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "BLEProximity", path: "Sources/BLEProximity")
    ]
)

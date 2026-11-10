// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Snapper",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Stitcher", path: "Sources/Stitcher"),
        .executableTarget(name: "Snapper", dependencies: ["Stitcher"], path: "Sources/Snapper"),
        .testTarget(name: "StitcherTests", dependencies: ["Stitcher"], path: "Tests/StitcherTests"),
    ]
)

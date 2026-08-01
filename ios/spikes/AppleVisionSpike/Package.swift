// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppleVisionSpike",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AppleVisionSpike",
            path: "Sources/AppleVisionSpike"
        )
    ]
)

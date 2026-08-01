// swift-tools-version: 5.9
import PackageDescription

// Logic lives here rather than in the app target so it can be unit-tested with
// `swift test` on any Mac, without an Xcode project or a simulator.
let package = Package(
    name: "CizgiCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CizgiCore", targets: ["CizgiCore"])
    ],
    targets: [
        .target(name: "CizgiCore", path: "Sources/CizgiCore"),
        .testTarget(
            name: "CizgiCoreTests",
            dependencies: ["CizgiCore"],
            path: "Tests/CizgiCoreTests"
        )
    ]
)

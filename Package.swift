// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SnekotEvents",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v8)],
    products: [.library(name: "SnekotEvents", targets: ["SnekotEvents"])],
    targets: [
        .target(name: "SnekotEvents"),
        .executableTarget(name: "smoke", dependencies: ["SnekotEvents"]),
        .testTarget(name: "SnekotEventsTests", dependencies: ["SnekotEvents"]),
    ]
)

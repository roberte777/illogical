// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IllogicalKit",
    platforms: [.macOS(.v14)],
    products: [
        // Pure Swift. Builds and tests without libghostty-vt present.
        .library(name: "IllogicalProtocol", targets: ["IllogicalProtocol"])
    ],
    targets: [
        .target(name: "IllogicalProtocol"),
        .testTarget(
            name: "IllogicalProtocolTests",
            dependencies: ["IllogicalProtocol"]
        ),
    ]
)

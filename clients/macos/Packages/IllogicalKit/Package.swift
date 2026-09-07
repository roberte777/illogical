// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IllogicalKit",
    platforms: [.macOS(.v14)],
    products: [
        // Pure Swift. Builds and tests without libghostty-vt present.
        .library(name: "IllogicalProtocol", targets: ["IllogicalProtocol"]),
        // Also pure Swift, and separate from the protocol on purpose: the
        // config file belongs to the machine you are sitting at, the protocol
        // to the machine the terminals run on. Neither needs the other.
        .library(name: "IllogicalConfig", targets: ["IllogicalConfig"]),
    ],
    targets: [
        .target(name: "IllogicalProtocol"),
        .testTarget(
            name: "IllogicalProtocolTests",
            dependencies: ["IllogicalProtocol"]
        ),
        .target(name: "IllogicalConfig"),
        .testTarget(
            name: "IllogicalConfigTests",
            dependencies: ["IllogicalConfig"]
        ),
    ]
)

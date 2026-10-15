// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TunnelDeck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TunnelDeck", targets: ["TunnelDeck"]),
        .executable(name: "TunnelDeckHelper", targets: ["TunnelDeckHelper"])
    ],
    targets: [
        .target(name: "TunnelCore"),
        .executableTarget(name: "TunnelDeck", dependencies: ["TunnelCore"]),
        .executableTarget(name: "TunnelDeckHelper", dependencies: ["TunnelCore"]),
        .testTarget(name: "TunnelCoreTests", dependencies: ["TunnelCore"]),
        .testTarget(name: "TunnelDeckTests", dependencies: ["TunnelDeck"])
    ],
    swiftLanguageModes: [.v5]
)

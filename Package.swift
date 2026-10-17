// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TunnelDeck",
    defaultLocalization: "en-US",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TunnelDeck", targets: ["TunnelDeck"]),
        .executable(name: "TunnelDeckHelper", targets: ["TunnelDeckHelper"])
    ],
    targets: [
        .target(name: "TunnelLocalization", resources: [.process("Resources")]),
        .target(name: "TunnelCore", dependencies: ["TunnelLocalization"]),
        .executableTarget(name: "TunnelDeck", dependencies: ["TunnelCore", "TunnelLocalization"]),
        .executableTarget(name: "TunnelDeckHelper", dependencies: ["TunnelCore", "TunnelLocalization"]),
        .testTarget(name: "TunnelLocalizationTests", dependencies: ["TunnelLocalization"]),
        .testTarget(name: "TunnelCoreTests", dependencies: ["TunnelCore"]),
        .testTarget(name: "TunnelDeckTests", dependencies: ["TunnelDeck"])
    ],
    swiftLanguageModes: [.v5]
)

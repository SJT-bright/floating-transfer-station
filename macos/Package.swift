// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FloatingTransferStationMac",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "FloatingTransferStationMac",
            targets: ["FloatingTransferStationMac"]
        )
    ],
    targets: [
        .executableTarget(
            name: "FloatingTransferStationMac",
            exclude: ["Resources/README.md"],
            resources: [.copy("Resources/GlassTap.wav"), .process("Resources/zh-Hans.lproj")]
        )
    ],
    swiftLanguageModes: [.v5]
)

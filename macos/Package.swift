// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FloatingTransferStationMac",
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
            resources: [.copy("Resources/GlassTap.wav")]
        )
    ],
    swiftLanguageModes: [.v5]
)

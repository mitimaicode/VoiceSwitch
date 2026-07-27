// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VoiceSwitch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VoiceSwitch", targets: ["VoiceSwitch"])
    ],
    targets: [
        .executableTarget(
            name: "VoiceSwitch",
            path: "Sources/VoiceSwitch"
        )
    ],
    swiftLanguageModes: [.v5]
)

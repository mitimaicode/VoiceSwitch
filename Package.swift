// swift-tools-version: 5.10

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
    swiftLanguageVersions: [.v5]
)

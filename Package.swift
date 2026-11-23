// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Overlay",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "Overlay", targets: ["Overlay"])
    ],
    targets: [
        .executableTarget(
            name: "Overlay",
            path: "Sources/Overlay",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)

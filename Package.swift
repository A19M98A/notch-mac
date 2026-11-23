// swift-tools-version: 5.9
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
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)

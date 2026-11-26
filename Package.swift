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
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "Overlay",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
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

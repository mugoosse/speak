// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "speak",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.4"),
    ],
    targets: [
        .executableTarget(
            name: "speak",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/speak",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                // Sparkle ships as a binary framework, and SwiftPM does not
                // embed frameworks into a bare executable. make_app.sh copies
                // it into Contents/Frameworks, so the runtime search path has
                // to point there or the app dies at launch with a dyld error.
                .unsafeFlags(["-Xlinker", "-rpath",
                              "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)

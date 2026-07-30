// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "speak",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.4"),
        // Already present transitively through mlx-audio-swift. Declared
        // explicitly so we can drive the model download ourselves and get a
        // progress callback: STT.loadModel does not forward one.
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "speak",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "Sources/speak",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
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

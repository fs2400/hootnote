// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hootnote",
    platforms: [.macOS("14.4")],
    dependencies: [
        // OpenAI Whisper (Large-v3 / Large-v3 Turbo) on Core ML + Neural Engine.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
        // Speaker diarization (pyannote + WeSpeaker), Silero voice-activity detection, optional Parakeet ASR.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "Hootnote",
            dependencies: [
                "CSpeexDSP",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Hootnote",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Acoustic echo cancellation (Xiph SpeexDSP 1.2.1, BSD), vendored. See Sources/CSpeexDSP/README.md.
        .target(
            name: "CSpeexDSP",
            path: "Sources/CSpeexDSP",
            exclude: ["COPYING", "README.md"],
            cSettings: [
                .define("FLOATING_POINT"),
                .define("USE_SMALLFT"),
                .define("EXPORT", to: ""),
                .unsafeFlags(["-w"]),
            ]
        ),
    ]
)

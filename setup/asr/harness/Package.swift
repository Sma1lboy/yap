// swift-tools-version: 5.9
// Small command-line wrappers that make the same library calls as the app, for setup/asr/bench.py.
// Pinned to the revisions in VoiceInk.xcodeproj's Package.resolved. Build: swift build -c release
// whisperbench compiles the app's LibWhisper.swift / WhisperChunking.swift (symlinked) against the
// whisper.xcframework `make whisper` builds; override its location with WHISPER_FRAMEWORK_DIR.
import Foundation
import PackageDescription

let whisperFrameworkDir = ProcessInfo.processInfo.environment["WHISPER_FRAMEWORK_DIR"]
    ?? NSHomeDirectory() + "/VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework/macos-arm64_x86_64"

let package = Package(
    name: "asr-harness", platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/Beingpax/Transcribe-cpp-swift.git", revision: "fb1c1ad99e8939a69fcfb613417d9635fb77ef42"),
        .package(url: "https://github.com/FluidInference/FluidAudio", revision: "5343241cd8a7576890e50925dec666bafc89d324"),
    ],
    targets: [
        .executableTarget(name: "tcppbench", dependencies: [.product(name: "TranscribeCpp", package: "Transcribe-cpp-swift")]),
        .executableTarget(name: "fluidbench", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(
            name: "whisperbench",
            swiftSettings: [.unsafeFlags(["-F", whisperFrameworkDir])],
            linkerSettings: [.unsafeFlags(["-F", whisperFrameworkDir, "-framework", "whisper",
                                           "-Xlinker", "-rpath", "-Xlinker", whisperFrameworkDir])]
        ),
    ]
)

// swift-tools-version: 5.9
// Small command-line wrappers that make the same library calls as the app, for setup/asr/bench.py.
// Pinned to the revisions in VoiceInk.xcodeproj's Package.resolved. Build: swift build -c release
import PackageDescription

let package = Package(
    name: "asr-harness", platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/Beingpax/Transcribe-cpp-swift.git", revision: "fb1c1ad99e8939a69fcfb613417d9635fb77ef42"),
        .package(url: "https://github.com/FluidInference/FluidAudio", revision: "5343241cd8a7576890e50925dec666bafc89d324"),
    ],
    targets: [
        .executableTarget(name: "tcppbench", dependencies: [.product(name: "TranscribeCpp", package: "Transcribe-cpp-swift")]),
        .executableTarget(name: "fluidbench", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
    ]
)

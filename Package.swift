// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpatialAudio",
    // Package minimum. Core Audio process taps (Step 6) need macOS 14.2+,
    // which SwiftPM cannot express; that is enforced at runtime with #available.
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpatialAudioApp", targets: ["SpatialAudioApp"]),
        .library(name: "SpatialAudioCore", targets: ["SpatialAudioCore"]),
    ],
    // No third-party dependencies. Add one only with a stated reason.
    dependencies: [],
    targets: [
        // Wait-free single-producer/single-consumer pose mailbox (C11 stdatomic). Needed because
        // Swift's Synchronization.Atomic requires macOS 15 and our minimum is 14.0.
        .target(name: "CPoseMailbox"),

        // Step 6a: the real-time half of the system-audio capture probe (one AudioDeviceIOProc, C11 atomics, no calls).
        // -Werror=function-effects makes clang reject any call from the CA_REALTIME_API ([[clang::nonblocking]]) callback to a
        // function it cannot prove non-blocking (a compile-time check next to scripts/scan-rt-callback.sh).
        .target(name: "CTapProbe", cSettings: [.unsafeFlags(["-Werror=function-effects"])]),

        // Pure logic: no hardware, no AVFoundation/Vision/CoreAudio. Unit-tested.
        .target(name: "SpatialAudioCore", dependencies: ["CPoseMailbox"]),

        // AVFoundation + Vision behind the HeadPoseProvider protocol.
        .target(name: "SpatialAudioTracking", dependencies: ["SpatialAudioCore"]),

        // Spatial renderer (AVAudioEnvironmentNode + HRTF), test tone, pose pump, scripted listening tests.
        .target(name: "SpatialAudioEngine", dependencies: ["SpatialAudioCore", "CTapProbe"]),

        // SwiftUI shell + debug HUD. No DSP or CV logic here.
        .executableTarget(
            name: "SpatialAudioApp",
            dependencies: ["SpatialAudioCore", "SpatialAudioTracking", "SpatialAudioEngine"]
        ),

        .testTarget(name: "SpatialAudioCoreTests", dependencies: ["SpatialAudioCore"]),
        .testTarget(name: "SpatialAudioTrackingTests", dependencies: ["SpatialAudioTracking", "SpatialAudioCore"]),
        .testTarget(name: "SpatialAudioEngineTests", dependencies: ["SpatialAudioEngine", "SpatialAudioCore", "CTapProbe"]),
    ],
    cLanguageStandard: .c11
)

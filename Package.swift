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
        // Pure logic: no hardware, no AVFoundation/Vision/CoreAudio. Unit-tested.
        .target(name: "SpatialAudioCore"),

        // AVFoundation + Vision behind the HeadPoseProvider protocol.
        .target(name: "SpatialAudioTracking", dependencies: ["SpatialAudioCore"]),

        // AudioSource / SpatialRenderer protocols and implementations.
        .target(name: "SpatialAudioEngine", dependencies: ["SpatialAudioCore"]),

        // SwiftUI shell + debug HUD. No DSP or CV logic here.
        .executableTarget(
            name: "SpatialAudioApp",
            dependencies: ["SpatialAudioCore", "SpatialAudioTracking", "SpatialAudioEngine"]
        ),

        .testTarget(name: "SpatialAudioCoreTests", dependencies: ["SpatialAudioCore"]),
        .testTarget(name: "SpatialAudioTrackingTests", dependencies: ["SpatialAudioTracking", "SpatialAudioCore"]),
    ]
)

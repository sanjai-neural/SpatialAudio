import Testing
import Foundation
import SpatialAudioCore
@testable import SpatialAudioEngine

/// Opt-in smoke test of the LIVE path (real output device, real timers). It is skipped unless SA_LIVE_AUDIO=1 because it
/// needs audio hardware and a machine that is awake; run it with
///
///     SA_LIVE_AUDIO=1 swift test --filter LiveEngineSmokeTests
///
/// It is SILENT by construction: the master volume is set to 0 before the engine starts and the test checks that. It opens no
/// camera and no microphone (the engine's input node is never touched). Timing numbers are printed for the record only;
/// the verdicts come from completion signals, never from a wall-clock deadline.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SA_LIVE_AUDIO"] == "1",
                              "set SA_LIVE_AUDIO=1 to run the silent hardware smoke test"))
struct LiveEngineSmokeTests {
    @Test func theLiveEngineStartsThePumpRunsAndEverythingStopsSilently() async throws {
        let renderer = try EnvironmentRenderer(mode: .live)
        renderer.outputVolume = 0
        #expect(renderer.outputVolume == 0, "the volume must be 0 before the engine starts, or this test would make sound")
        let session = ListeningTestSession(renderer: renderer, test: .headSweepYaw)
        try session.start()
        #expect(renderer.isRunning)

        let flowing = await waitUntil(timeout: .seconds(60)) {
            let s = session.snapshot
            return (s.applied?.steps ?? 0) >= 150 && (s.applied?.sinkWrites ?? 0) >= 20 && (s.applied?.mailboxSequence ?? 0) >= 20
        }
        let s = session.snapshot
        session.stop()
        #expect(flowing)
        #expect(!renderer.isRunning)
        #expect(renderer.outputVolume == 0)
        #expect(s.timing.ticks >= 100)
        #expect(renderer.notice == nil, "\(renderer.notice ?? "")")
        let d = renderer.diagnostics
        print("LIVE SMOKE (silent): output sample rate \(d.sampleRate) Hz, HRTFHQ applicable \(d.hrtfHQApplicable), headphone output type \(d.outputTypeIsHeadphones); "
            + "pump ticks \(s.timing.ticks), mean period \(String(format: "%.2f", s.timing.meanPeriodMilliseconds)) ms (nominal \(String(format: "%.2f", 512 / d.sampleRate * 1000)) ms), "
            + "max period \(String(format: "%.2f", s.timing.maxPeriodMilliseconds)) ms, sink writes \(s.applied?.sinkWrites ?? 0), mailbox sequence \(s.applied?.mailboxSequence ?? 0)")
    }
}

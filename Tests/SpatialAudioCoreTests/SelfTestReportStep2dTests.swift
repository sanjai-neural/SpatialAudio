import Testing
import Foundation
@testable import SpatialAudioCore

/// Step 2d additions to the report: quality attribution, baseline statistics, step evidence, INVALID loss test,
/// green-light states, and compatibility with the two reports written before these fields existed.
@Suite struct SelfTestReportStep2dTests {
    func report(simulated: Bool = false) -> SelfTestReport {
        SelfTestAnalyzer.analyze(simulateSession(), context: testContext(simulated: simulated))
    }

    @Test func schemaVersionTwoWithQualityGroupsThatSumToOne() throws {
        let r = report()
        #expect(r.schemaVersion == 2)
        let groups = try #require(r.qualityByPhase)
        let names = groups.map(\.name)
        for needle in ["statistics window (hold + rest)", "baseline", "hold: turn LEFT", "hold: look UP", "hold: tilt RIGHT EAR", "rest",
                       "loss test: turn (incl. waiting for lock)", "loss test: cover", "loss test: uncover", "whole run"] {
            #expect(names.contains(needle), "missing group \(needle)")
        }
        for g in groups {
            #expect(abs(g.limitingFractions.values.reduce(0, +) - 1) < 1e-9, "\(g.name)")
            #expect(g.frames > 0 && g.meanQuality >= 0 && g.meanQuality <= 1)
        }
        let cover = try #require(groups.first { $0.name == "loss test: cover" })
        #expect(cover.limitingFractions["no face"] ?? 0 > 0)                       // covered lens: no face, and the report says so
        #expect(cover.fractionBelowLossThreshold > 0.5)
    }

    @Test func theGateConfigurationInEffectIsRecordedInTheReport() {
        let r = report()
        #expect(r.config.gate == QualityGateConfig())
    }

    @Test func theLossSectionCarriesTheEvidenceWindow() throws {
        let ev = try #require(report().loss.stepEvidence)
        #expect(ev.frames.count > 10 && ev.frames.contains { $0.rawVisionDegrees != nil } && ev.classification.explanation.count > 10)
    }

    @Test func markdownShowsQualityBaselinesEvidenceAndTheGate() {
        let md = report().markdown()
        for needle in ["## 4. Tracking quality: which component limited it", "limiting component (share of frames)",
                       "### Baseline statistics of the instructed axis", "σ (MAD)", "required move",
                       "### Evidence around the largest pose step", "Shape:", "Quality gate: loss below 0.40 for 0.10 s",
                       "## 5. Camera release", "Coaching targets: turn 30° / look up 20° / tilt 20°", "cover cue waits until tracking has been LOCKED"] {
            #expect(md.contains(needle), "missing: \(needle)")
        }
        #expect(!md.contains("NaN") && md.range(of: #"(?i)\binf\b"#, options: .regularExpression) == nil)
    }

    @Test func greenLightStartsAsNotAnsweredForRealRunsAndNotAskedForSimulatedOnes() {
        #expect(report().greenLight == .notAnswered)
        #expect(report(simulated: true).greenLight == .notAsked)
        var r = report()
        #expect(r.markdown().contains("Green light (visual, user-reported):** NOT ANSWERED"))
        r.greenLight = .off
        #expect(r.markdown().contains("yes — the light went OFF"))
        r.greenLight = .stillOn
        #expect(r.markdown().contains("NO — the light is STILL ON"))
        // The raw values older reports used still decode.
        #expect(GreenLightAnswer(rawValue: "user reports OFF") == .off && GreenLightAnswer(rawValue: "not asked") == .notAsked)
    }

    @Test func aLikelyAxisIsPrintedAsLikelyAndNotApplied() {
        var r = report()
        let leaky = SignDetector.analyze(axis: .yaw, evidence: [
            RepetitionEvidence(reference: Array(repeating: VisionFaceAngles(yaw: 0, pitch: 0, roll: 0), count: 30), referenceFrames: 30,
                               hold: Array(repeating: VisionFaceAngles(yaw: 25 * .pi / 180, pitch: 20 * .pi / 180, roll: 0), count: 30), holdFrames: 30, mirroredFraction: 0),
            RepetitionEvidence(reference: Array(repeating: VisionFaceAngles(yaw: 0, pitch: 0, roll: 0), count: 30), referenceFrames: 30,
                               hold: Array(repeating: VisionFaceAngles(yaw: 26 * .pi / 180, pitch: 20 * .pi / 180, roll: 0), count: 30), holdFrames: 30, mirroredFraction: 0)])
        #expect(leaky.outcome == .likely)
        r.signs.yaw = leaky
        let md = r.markdown()
        #expect(md.contains("LIKELY (not applied)") && md.contains("never applied automatically"))
        #expect(r.signs.recommendedMapping(over: HeadAngleMapping()) == HeadAngleMapping())
    }

    @Test func theJSONRoundTripsAndStaysNumbersAndShortStrings() throws {
        let r = report()
        let data = try r.jsonData()
        let back = try SelfTestReport.decode(data)
        #expect(back == r)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.lowercased().contains("base64") && !text.contains("\"image") && !text.contains("jpeg") && text.count < 150_000)
        func walk(_ o: Any, _ visit: (Any) -> Void) {
            visit(o)
            if let d = o as? [String: Any] { d.values.forEach { walk($0, visit) } } else if let a = o as? [Any] { a.forEach { walk($0, visit) } }
        }
        let object = try JSONSerialization.jsonObject(with: data)
        var longest = 0
        walk(object) { if let s = $0 as? String { longest = max(longest, s.count) } }
        #expect(longest < 400, "a string of \(longest) characters in a numbers-only report")
    }

    @Test func aRealReportWrittenBeforeStep2dStillDecodes() throws {
        // Reads the committed 08:12 report (schema 1, no new fields). Skipped silently if the file is not where we expect it.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        url.appendPathComponent("docs/test-results/selftest-20261105-081218-normal-light.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let old = try SelfTestReport.decode(Data(contentsOf: url))
        #expect(old.schemaVersion == 1 && old.qualityByPhase == nil && old.loss.stepEvidence == nil && old.config.gate == nil)
        #expect(old.signs.yaw.outcome == .determined && old.loss.verdict == .fail)
        #expect(old.signs.yaw.repetitions.allSatisfy { $0.referenceStats == nil && $0.enoughMovement })     // `enoughMovement` falls back to `usable`
        #expect(old.greenLight == .notAsked)
        #expect(!old.isSimulated)
        _ = old.markdown()                                                         // an old report can still be rendered
    }
}

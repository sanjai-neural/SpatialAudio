import Testing
import Foundation
@testable import SpatialAudioCore

@Suite struct SelfTestEndToEndTests {
    // MARK: documented conventions (what the app currently assumes)

    @Test func documentedConventionsGiveDeterminedSignsAndNoInverts() throws {
        let report = SelfTestAnalyzer.analyze(simulateSession(), context: testContext())
        for axis in RotationAxis.allCases {
            let r = report.signs[axis]
            #expect(r.outcome == .determined, "\(axis): \(r.reasons)")
            #expect(r.invertNeeded == false, "\(axis)")
            #expect(r.repetitions.count == 2 && r.repetitions.allSatisfy { $0.usable })
        }
        #expect(report.signs.allDetermined)
        #expect(report.signs.yaw.rawVisionSign == 1 && report.signs.pitch.rawVisionSign == -1 && report.signs.roll.rawVisionSign == 1)
        #expect(report.signs.recommendedMapping(over: HeadAngleMapping()) == HeadAngleMapping())
    }

    @Test func measuredDeltasMatchTheSimulatedMovement() throws {
        let r = SelfTestAnalyzer.analyze(simulateSession(), context: testContext()).signs
        let yaw = try #require(r.yaw.repetitions.first), pitch = try #require(r.pitch.repetitions.first), roll = try #require(r.roll.repetitions.first)
        #expect(abs(yaw.intendedDeltaDegrees - 30) < 2)                 // the simulated person makes the coached moves: 30° / 20° / 20°
        #expect(abs(pitch.intendedDeltaDegrees - (-20)) < 2)            // up is raw-negative in Vision's convention
        #expect(abs(roll.intendedDeltaDegrees - 20) < 2)
        #expect(yaw.leakageRatio < 0.2 && pitch.leakageRatio < 0.2 && roll.leakageRatio < 0.2)
    }

    // MARK: a camera whose Vision conventions differ from the documented ones

    @Test func flippedYawConventionIsDetectedAndOnlyYawIsInverted() {
        let user = SimulatedUser(conventions: .init(yawPerLeft: -1))
        let report = SelfTestAnalyzer.analyze(simulateSession(user: user), context: testContext())
        #expect(report.signs.yaw.invertNeeded == true && report.signs.yaw.rawVisionSign == -1)
        #expect(report.signs.pitch.invertNeeded == false && report.signs.roll.invertNeeded == false)
        #expect(report.signs.recommendedMapping(over: HeadAngleMapping()) == HeadAngleMapping(invertYaw: true))
    }

    @Test func everyAxisFlippedIsDetected() {
        let user = SimulatedUser(conventions: .init(yawPerLeft: -1, pitchPerUp: 1, rollPerRightEar: -1))
        let report = SelfTestAnalyzer.analyze(simulateSession(user: user), context: testContext())
        #expect(report.signs.recommendedMapping(over: HeadAngleMapping()) == HeadAngleMapping(invertYaw: true, invertPitch: true, invertRoll: true))
    }

    @Test func detectionDoesNotDependOnTheMappingCurrentlyInEffect() {
        // The user had inverted yaw by hand before the test; the verdict is about the RAW signal, so it is the same.
        let wrongMapping = HeadAngleMapping(invertYaw: true, invertPitch: true, invertRoll: true)
        let report = SelfTestAnalyzer.analyze(simulateSession(mapping: wrongMapping), context: testContext(mapping: wrongMapping))
        #expect(report.signs.recommendedMapping(over: wrongMapping) == HeadAngleMapping())
        #expect(report.mappingDuringTest == wrongMapping)
    }

    @Test func mirroredFramesGiveTheSameInvertAnswerAsUnmirrored() {
        let user = SimulatedUser(framesMirrored: true)
        let report = SelfTestAnalyzer.analyze(simulateSession(user: user), context: testContext())
        #expect(report.signs.recommendedMapping(over: HeadAngleMapping()) == HeadAngleMapping())
        #expect(report.signs.yaw.framesMirrored == true)
        #expect(report.environment.framesMirroredFraction == 1)
    }

    // MARK: users who do not follow the script

    @Test func aTinyHeadTurnLeavesOnlyYawInconclusive() {
        let user = SimulatedUser(moveTargetsDegrees: AngleTriple(yaw: 6, pitch: 25, roll: 25))
        let report = SelfTestAnalyzer.analyze(simulateSession(user: user), context: testContext())
        #expect(report.signs.yaw.outcome == .inconclusive && report.signs.yaw.invertNeeded == nil)
        #expect(report.signs.pitch.outcome == .determined && report.signs.roll.outcome == .determined)
        let base = HeadAngleMapping(invertYaw: true)                                      // yaw must stay as it was
        #expect(report.signs.recommendedMapping(over: base).invertYaw == true)
    }

    @Test func movingOnlyTheEyesForLookUpIsInconclusive() {
        let user = SimulatedUser(moveTargetsDegrees: AngleTriple(yaw: 45, pitch: 2, roll: 25))
        #expect(SelfTestAnalyzer.analyze(simulateSession(user: user), context: testContext()).signs.pitch.outcome == .inconclusive)
    }

    @Test func notCoveringTheCameraMakesTheLossTestIncomplete() {
        var user = SimulatedUser()
        user.coverReactionSeconds = 1000                                                  // the hand never arrives
        let report = SelfTestAnalyzer.analyze(simulateSession(user: user), context: testContext())
        #expect(report.loss.verdict == .incomplete)
        #expect(report.signs.allDetermined)                                               // the sign part is unaffected
    }

    // MARK: whole-report properties

    @Test func healthyRunHasPassingLossTest() throws {
        let report = SelfTestAnalyzer.analyze(simulateSession(), context: testContext())
        #expect(report.loss.verdict == .pass, "\(report.loss.notes) \(report.loss.observedSequence)")
        #expect(report.loss.jumpCheckMeaningful)
        let travel = try #require(report.loss.heldPoseTravelDegrees)
        #expect(travel > 15)
    }

    @Test func statisticsWindowIsThirtySecondsAndMatchesTheSimulatedTimings() throws {
        let report = SelfTestAnalyzer.analyze(simulateSession(), context: testContext())
        let s = report.stats
        #expect(s.windowSeconds == 30 && s.sufficient)
        #expect(s.frameCount > 850 && s.frameCount < 910)                                 // 30 s at 30 fps
        let fps = try #require(s.fpsMean)
        #expect(abs(fps - 30) < 0.5)
        let delivery = try #require(s.deliveryMs), vision = try #require(s.visionMs), total = try #require(s.totalMs)
        #expect(abs(delivery.mean - 82) < 0.01 && abs(vision.mean - 14) < 0.01 && abs(total.mean - 96) < 0.01)
        #expect(delivery.p95 == 82 && delivery.max == 82)
        #expect(s.facePresentFraction > 0.99)
    }

    @Test func lightingTagIsRecorded() {
        #expect(SelfTestAnalyzer.analyze(simulateSession(lighting: .dimRoom), context: testContext()).lighting == .dimRoom)
    }

    @Test func simulatedInputIsLabelledEverywhere() {
        let report = SelfTestAnalyzer.analyze(simulateSession(), context: testContext(simulated: true))
        #expect(report.isSimulated)
        #expect(report.markdown().contains("SIMULATED INPUT"))
        #expect(!SelfTestAnalyzer.analyze(simulateSession(), context: testContext()).markdown().contains("SIMULATED INPUT"))
    }
}

@Suite struct SelfTestReportFormatTests {
    func sample() -> SelfTestReport {
        var r = SelfTestAnalyzer.analyze(simulateSession(), context: testContext())
        r.cameraRelease = CameraReleaseReport(wasRunningBeforeStop: true, isRunningAfterStop: false, inputsAfterStop: 0,
                                              outputsAfterStop: 0, stopNotificationsObserved: 1, callbacksAfterStop: 0,
                                              sessionObjectDeallocated: true, secondsSinceStop: 1.2)
        r.greenLight = .off
        r.appliedMapping = HeadAngleMapping(invertYaw: true)
        return r
    }

    @Test func jsonRoundTripIsLossless() throws {
        let r = sample()
        #expect(try SelfTestReport.decode(r.jsonData()) == r)
    }

    @Test func jsonHasNoNonFiniteNumbers() throws {
        let text = String(decoding: try sample().jsonData(), as: UTF8.self)
        #expect(!text.contains("NaN") && !text.lowercased().contains("infinity"))
    }

    /// The report is numbers and short strings only: every JSON leaf is a number, bool or string, no
    /// array is long (a pixel buffer or per-frame dump would be), and the file is small.
    @Test func reportContainsOnlyNumbersAndShortStrings() throws {
        let data = try sample().jsonData()
        #expect(data.count < 100_000)       // about 46 KB with the 31-frame evidence window; it was 9 KB before Step 2d
        func walk(_ any: Any, depth: Int = 0) {
            switch any {
            case let d as [String: Any]: for (_, v) in d { walk(v, depth: depth + 1) }
            case let a as [Any]:
                #expect(a.count <= 40, "array of \(a.count) items")
                for v in a { walk(v, depth: depth + 1) }
            case let s as String: #expect(s.count < 600)
            case is NSNumber: break
            default: Issue.record("unexpected JSON leaf type \(type(of: any))")
            }
        }
        walk(try JSONSerialization.jsonObject(with: data))
    }

    @Test func markdownContainsTheKeyFacts() {
        let md = sample().markdown()
        for needle in ["# SpatialAudio self-test report", "normal light", "DETERMINED", "## 2. Loss test", "PASS",
                       "## 3. Statistics (30 s window", "p95", "CLEAN", "yes — the light went OFF", "Applied by the user",
                       "Thresholds used (all untuned)", "LEFT = +yaw", "Mac16,12"] {
            #expect(md.contains(needle), "missing: \(needle)")
        }
        #expect(!md.contains("NaN") && !md.lowercased().contains("infinity"))
        #expect(md.range(of: #"(?i)\binf\b"#, options: .regularExpression) == nil)     // no printed "inf" / "-inf" numbers
    }

    @Test func releaseSectionWordingDependsOnTheInputSource() {
        let sim = SelfTestAnalyzer.analyze(simulateSession(), context: testContext(simulated: true)).markdown()
        #expect(sim.contains("n/a — simulated input has no camera hardware") && !sim.contains("not run"))
        let cam = SelfTestAnalyzer.analyze(simulateSession(), context: testContext(simulated: false)).markdown()
        #expect(cam.contains("not available (the camera was not stopped and read back)"))
        #expect(cam.contains("NOT ANSWERED"))                                    // the question was shown, nobody answered
        #expect(sim.contains("not asked (no camera light applies)"))
        #expect(!cam.contains("listed below") && cam.contains("listed in this report"))
    }

    @Test func markdownSaysINCONCLUSIVEWhenSo() {
        let user = SimulatedUser(moveTargetsDegrees: AngleTriple(yaw: 4, pitch: 25, roll: 25))
        let md = SelfTestAnalyzer.analyze(simulateSession(user: user), context: testContext()).markdown()
        #expect(md.contains("INCONCLUSIVE") && md.contains("too small"))
    }

    @Test func fileStemIsDeterministicAndTaggedByLighting() throws {
        let date = Date(timeIntervalSince1970: 1_793_889_012)                              // 2026-11-05T14:30:12Z
        let utc = try #require(TimeZone(identifier: "UTC")), ist = try #require(TimeZone(identifier: "Asia/Kolkata"))
        #expect(SelfTestReport.fileStem(date: date, timeZone: utc, lighting: .normalLight, simulated: false) == "selftest-20261105-143012-normal-light")
        #expect(SelfTestReport.fileStem(date: date, timeZone: utc, lighting: .dimRoom, simulated: false) == "selftest-20261105-143012-dim-room")
        #expect(SelfTestReport.fileStem(date: date, timeZone: ist, lighting: .normalLight, simulated: true) == "selftest-20261105-200012-normal-light-SIMULATED")
        #expect(SelfTestReport.timestamp(date, timeZone: utc) == "2026-11-05T14:30:12Z")
        #expect(SelfTestReport.timestamp(date, timeZone: ist) == "2026-11-05T20:00:12+05:30")
    }

    @Test func releaseReportCleanlinessRules() {
        func make(running: Bool = false, inputs: Int = 0, outputs: Int = 0, late: Int = 0) -> CameraReleaseReport {
            CameraReleaseReport(wasRunningBeforeStop: true, isRunningAfterStop: running, inputsAfterStop: inputs,
                                outputsAfterStop: outputs, stopNotificationsObserved: 1, callbacksAfterStop: late,
                                sessionObjectDeallocated: true, secondsSinceStop: 1)
        }
        #expect(make().isClean)
        #expect(!make(running: true).isClean && !make(inputs: 1).isClean && !make(outputs: 1).isClean && !make(late: 1).isClean)
    }

    @Test func savedMappingCodableViaHeadAngleMapping() throws {
        let m = HeadAngleMapping(invertYaw: true, invertPitch: false, invertRoll: true)
        #expect(try JSONDecoder().decode(HeadAngleMapping.self, from: JSONEncoder().encode(m)) == m)
    }
}

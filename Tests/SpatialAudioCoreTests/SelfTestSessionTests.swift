import Testing
@testable import SpatialAudioCore

@Suite struct SelfTestScriptTests {
    let script = SelfTestScript.standard

    @Test func structureMatchesTheRequestedSequence() {
        #expect(script.phases.count == 17)                       // getReady, baseline, 6×(hold+rest), lossTurn, cover, uncover
        #expect(script.phases.first?.kind == .getReady && script.phases[1].kind == .baseline)
        #expect(script.phases.suffix(3).map(\.kind) == [.lossTurn, .cover, .uncover])
        let holds = script.phases.filter { $0.kind == .hold }
        #expect(holds.map { $0.move! } == [.turnLeft, .turnLeft, .lookUp, .lookUp, .tiltRightEar, .tiltRightEar])
        #expect(holds.map { $0.repetition! } == [1, 2, 1, 2, 1, 2])
        #expect(holds.allSatisfy { $0.duration == 3 })           // "hold 3 s"
        #expect(script.phases[1].duration == 2)                  // "baseline 2 s"
        #expect(script.phases.first { $0.kind == .cover }?.duration == 5)   // "cover for 5 s"
    }

    @Test func idsMatchIndicesAndDurationsSumToTotal() {
        #expect(script.phases.enumerated().allSatisfy { $0.offset == $0.element.id })
        #expect(abs(script.totalDuration - script.phases.reduce(0) { $0 + $1.duration }) < 1e-12)
        #expect(script.totalDuration == 47)
    }

    @Test func everyHoldIsPrecededByAReferencePhaseWithAnalysisWindows() {
        for (i, p) in script.phases.enumerated() where p.kind == .hold {
            let before = script.phases[i - 1]
            #expect(before.kind == .baseline || before.kind == .rest)
            #expect(before.analysisWindow != nil && p.analysisWindow != nil)
            #expect(p.analysisWindow!.upperBound <= p.duration && before.analysisWindow!.upperBound <= before.duration)
        }
    }

    @Test func statsWindowIsExactlyThirtySecondsOfHoldAndRest() {
        #expect(script.statsWindowSeconds == 30)
        #expect(script.phases.filter(\.inStatsWindow).allSatisfy { $0.kind == .hold || $0.kind == .rest })
    }

    @Test func everyPhaseHasTextAndACue() {
        #expect(script.phases.allSatisfy { !$0.title.isEmpty && !$0.instruction.isEmpty })
        #expect(Set(script.phases.map(\.cue)).isSuperset(of: [.begin, .hold, .rest, .cover, .uncover]))
    }

    @Test func holdTitlesAreAllCapsForReadingFromTheSide() {
        let titles = script.phases.filter { $0.kind == .hold }.map(\.title)
        #expect(titles.first == "TURN LEFT — HOLD  (1 of 2)")
        #expect(titles.contains("LOOK UP — HOLD  (2 of 2)") && titles.contains("TILT RIGHT EAR — HOLD  (1 of 2)"))
        #expect(titles.allSatisfy { title in
            let head = title.components(separatedBy: "(")[0]          // the part before "(1 of 2)"
            return head == head.uppercased()
        })
    }

    @Test func instructionsSayWhichSideIsMeant() {
        let left = script.phases.first { $0.move == .turnLeft }!.instruction
        let ear = script.phases.first { $0.move == .tiltRightEar }!.instruction
        #expect(left.contains("YOUR left") && ear.contains("YOUR right"))
    }

    @Test func indexAtElapsedHonoursBoundaries() {
        #expect(script.index(atElapsed: 0) == 0)
        #expect(script.index(atElapsed: 2.999) == 0)
        #expect(script.index(atElapsed: 3.0) == 1)
        #expect(script.index(atElapsed: 46.999) == script.phases.count - 1)
        #expect(script.index(atElapsed: 47) == nil)
        #expect(script.index(atElapsed: -0.001) == nil)
        #expect(script.index(atElapsed: .nan) == nil)
    }
}

@Suite struct SelfTestSessionTests {
    func frame(at arrival: Double) -> SelfTestFrame {
        SelfTestFrame(arrival: arrival, captureTime: arrival, angles: VisionFaceAngles(yaw: 0, pitch: 0, roll: 0), frameMirrored: false,
                      state: .locked, pose: .identity, qualityOverall: 1, deliveryLatency: 0, visionDuration: 0, totalLatency: 0)
    }

    @Test func advanceEmitsEachPhaseStartExactlyOnceInOrder() {
        var s = SelfTestSession(lighting: .normalLight, startTime: 100)
        #expect(s.advance(to: 99.9).isEmpty)                                   // before the start
        #expect(s.advance(to: 100) == [.phaseStarted(index: 0)])
        #expect(s.advance(to: 100.5).isEmpty)
        #expect(s.advance(to: 103) == [.phaseStarted(index: 1)])
        #expect(s.advance(to: 103).isEmpty)                                    // not repeated
        #expect(s.advance(to: 105) == [.phaseStarted(index: 2)])               // baseline is 2 s: phase 2 starts at 105
        #expect(s.advance(to: 111) == [.phaseStarted(index: 3), .phaseStarted(index: 4)])   // rest starts at 108, second hold at 110: both caught up in order
    }

    @Test func advanceCatchesUpOnSkippedPhasesAndFinishesOnce() {
        var s = SelfTestSession(lighting: .dimRoom, startTime: 0)
        let events = s.advance(to: 1000)
        let starts = events.compactMap { e -> Int? in if case .phaseStarted(let i) = e { i } else { nil } }
        #expect(starts == Array(0..<17))
        #expect(events.last == .finished && s.isFinished)
        #expect(s.advance(to: 2000).isEmpty)
    }

    @Test func abortStopsEventsAndRecording() {
        var s = SelfTestSession(lighting: .normalLight, startTime: 0)
        _ = s.advance(to: 1)
        s.abort()
        #expect(s.advance(to: 500).isEmpty && s.wasAborted)
        s.record(frame(at: 1.5))
        #expect(s.framesByPhase.allSatisfy { $0.isEmpty })
    }

    @Test func framesAreFiledUnderTheirArrivalPhase() {
        var s = SelfTestSession(lighting: .normalLight, startTime: 10)
        for t in [10.0, 12.99, 13.0, 14.9, 15.0, 57.0, 60.0, 9.99] { s.record(frame(at: t)) }
        #expect(s.framesByPhase[0].map(\.arrival) == [10.0, 12.99])           // phase 0 = [10, 13)
        #expect(s.framesByPhase[1].map(\.arrival) == [13.0, 14.9])            // phase 1 = [13, 15)
        #expect(s.framesByPhase[2].map(\.arrival) == [15.0])
        #expect(s.framesByPhase.reduce(0) { $0 + $1.count } == 5)             // 57.0 (= end), 60.0 and 9.99 ignored
    }

    @Test func windowSelectionIsLowerInclusiveUpperExclusive() {
        var s = SelfTestSession(lighting: .normalLight, startTime: 0)
        for t in stride(from: 3.0, to: 5.0, by: 0.25) { s.record(frame(at: t)) }       // phase 1 = [3, 5)
        let w = s.frames(inPhase: 1, window: 0.5...1.5)                                 // arrivals 3.5 ..< 4.5
        #expect(w.map(\.arrival) == [3.5, 3.75, 4.0, 4.25])
        #expect(s.frames(inPhase: 99, window: 0...1).isEmpty)
    }

    @Test func statusReportsRemainingTimeAndProgress() throws {
        let s = SelfTestSession(lighting: .normalLight, startTime: 50)
        #expect(s.status(at: 49) == nil && s.status(at: 97) == nil)
        let st = try #require(s.status(at: 54))                                // 4 s in: phase 1 (baseline), 1 s elapsed
        #expect(st.phaseIndex == 1 && st.phase.kind == .baseline)
        #expect(abs(st.phaseElapsed - 1) < 1e-9 && abs(st.secondsRemainingInPhase - 1) < 1e-9)
        #expect(abs(st.phaseProgress - 0.5) < 1e-9 && abs(st.overallProgress - 4.0 / 47) < 1e-9)
    }

    @Test func absoluteBoundsOfAPhase() {
        let s = SelfTestSession(lighting: .normalLight, startTime: 100)
        #expect(s.absoluteStart(of: 1) == 103 && s.absoluteEnd(of: 1) == 105)
    }
}

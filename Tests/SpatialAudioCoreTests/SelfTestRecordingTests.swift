import Testing
import Foundation
@testable import SpatialAudioCore

private let d2r = Double.pi / 180

/// A hand-made frame. Angles in DEGREES (converted to the radians Vision gives); `box` is the face-box height.
private func frame(_ t: Double, state: TrackingState = .locked, quality: Double = 1, limiting: String = "none",
                   angles: (Double, Double, Double)? = (0, 0, 0), box: Double? = 0.45, tick: Bool = false) -> SelfTestFrame {
    SelfTestFrame(arrival: t, captureTime: t,
                  angles: angles.map { VisionFaceAngles(yaw: $0.0 * d2r, pitch: $0.1 * d2r, roll: $0.2 * d2r) },
                  frameMirrored: false, state: state, pose: .identity, qualityOverall: quality, isWatchdogTick: tick,
                  deliveryLatency: 0, visionDuration: 0, totalLatency: 0, limiting: limiting,
                  faceBox: box.map { NormalizedRect(x: 0.3, y: 0.25, width: 0.3, height: $0) })
}

/// Plays `make(elapsed, phaseIndex)` into a session at `fps`, stepping the session like the controller does.
private func run(script: SelfTestScript = SelfTestScript.standard.withoutLockGates, fps: Int = 10, start: Double = 100,
                 until: Double? = nil, _ make: (Double, Int) -> SelfTestFrame) -> SelfTestSession {
    var s = SelfTestSession(script: script, lighting: .normalLight, startTime: start)
    let last = until ?? script.totalDuration
    var k = 0
    while Double(k) / Double(fps) < last {
        let elapsed = Double(k) / Double(fps)
        _ = s.advance(to: start + elapsed)
        let phase = s.status(at: start + elapsed)?.phaseIndex ?? 0
        var f = make(elapsed, phase)
        f.arrival = start + elapsed; f.captureTime = f.arrival
        s.record(f)
        k += 1
    }
    return s
}

private let gate = QualityGateConfig()

/// 0-based frame index inside a phase that starts at `phaseStart` (10 fps), immune to floating-point error.
private func idx(_ elapsed: Double, _ phaseStart: Double) -> Int { Int(((elapsed - phaseStart) * 10).rounded()) }

@Suite struct MinMedianMaxTests {
    @Test func oddEvenAndOrder() throws {
        let odd = try #require(MinMedianMax([3, 1, 2]))
        #expect(odd.min == 1 && odd.median == 2 && odd.max == 3)
        let even = try #require(MinMedianMax([4, 1, 3, 2]))
        #expect(even.min == 1 && even.median == 2.5 && even.max == 4)
        let skewed = try #require(MinMedianMax([1, 1, 1, 1, 100]))
        #expect(skewed.median == 1)                                            // a median, not a mean
    }

    @Test func nonFiniteValuesAreIgnoredAndNothingIsNil() throws {
        #expect(MinMedianMax([]) == nil && MinMedianMax([.nan, .infinity]) == nil)
        let s = try #require(MinMedianMax([.nan, 5, .infinity, 7]))
        #expect(s.min == 5 && s.median == 6 && s.max == 7)
    }
}

@Suite struct StateSecondsTests {
    let frames = [frame(0, state: .locked), frame(1, state: .holding), frame(1.5, state: .decaying),
                  frame(3, state: .static), frame(4, state: .locked)]

    @Test func eachFrameOwnsTheTimeUntilTheNextOne() {
        let s = SelfTestRecorder.stateSeconds(frames: frames, from: 0.5, to: 3.5)
        #expect(abs(s.locked - 0.5) < 1e-12 && abs(s.holding - 0.5) < 1e-12 && abs(s.decaying - 1.5) < 1e-12 && abs(s.staticState - 0.5) < 1e-12)
        #expect(abs(s.total - 3.0) < 1e-12)
    }

    @Test func theLastFrameOwnsTheTimeUpToTheEndOfTheWindow() {
        let s = SelfTestRecorder.stateSeconds(frames: frames, from: 0, to: 4.5)
        #expect(abs(s.locked - 1.5) < 1e-12 && abs(s.holding - 0.5) < 1e-12 && abs(s.decaying - 1.5) < 1e-12 && abs(s.staticState - 1.0) < 1e-12)
    }

    @Test func beforeTheFirstFrameTheFirstFramesStateIsUsed() {
        let s = SelfTestRecorder.stateSeconds(frames: frames, from: -1, to: 0.5)
        #expect(abs(s.locked - 1.5) < 1e-12 && s.holding == 0 && s.decaying == 0 && s.staticState == 0)
    }

    @Test func aWindowInsideOneFramesIntervalGetsExactlyItsLength() {
        let s = SelfTestRecorder.stateSeconds(frames: frames, from: 1.1, to: 1.3)
        #expect(abs(s.holding - 0.2) < 1e-12 && s.total < 0.2 + 1e-12)
    }

    @Test func watchdogTicksAdvanceTheStateLikeAnyOtherFrame() {
        let f = [frame(0, state: .locked), frame(1, state: .holding, angles: nil, box: nil, tick: true), frame(2, state: .decaying, angles: nil, box: nil, tick: true)]
        let s = SelfTestRecorder.stateSeconds(frames: f, from: 0, to: 3)
        #expect(abs(s.locked - 1) < 1e-12 && abs(s.holding - 1) < 1e-12 && abs(s.decaying - 1) < 1e-12)
    }

    @Test func emptyInputOrAnEmptyWindowIsZero() {
        #expect(SelfTestRecorder.stateSeconds(frames: [], from: 0, to: 5).total == 0)
        #expect(SelfTestRecorder.stateSeconds(frames: frames, from: 2, to: 2).total == 0)
        #expect(SelfTestRecorder.stateSeconds(frames: frames, from: 3, to: 2).total == 0)
    }

    @Test func theSecondsAlwaysAddUpToTheWindow() {
        for (a, b) in [(0.0, 4.5), (0.25, 3.75), (1.2, 1.4), (-2.0, 9.0)] {
            #expect(abs(SelfTestRecorder.stateSeconds(frames: frames, from: a, to: b).total - (b - a)) < 1e-9, "[\(a), \(b)]")
        }
    }
}

@Suite struct PhaseRecordTests {
    let script = SelfTestScript.standard.withoutLockGates

    @Test func everyPhaseGetsARecordInRunOrderWithRunRelativeTimes() {
        let s = run { _, _ in frame(0) }
        let r = SelfTestRecorder.phaseRecords(s, gate: gate)
        #expect(r.count == script.phases.count && r.map(\.index) == Array(script.phases.indices))
        for (i, rec) in r.enumerated() {
            #expect(abs(rec.startSeconds - script.starts[i]) < 1e-9 && abs(rec.endSeconds - (script.starts[i] + script.phases[i].duration)) < 1e-9)
            #expect(rec.kind == script.phases[i].kind && rec.move == script.phases[i].move && rec.repetition == script.phases[i].repetition)
        }
        #expect(r[2].name == "hold: turn LEFT #1" && r[1].name == "baseline" && r[3].name == "rest" && r[15].name == "loss test: cover")
    }

    @Test func boxHeightIsMinMedianMaxPerPhaseAndNilWithoutAFace() throws {
        let heights = [0.10, 0.20, 0.30]
        let s = run { elapsed, phase in
            switch phase {
            case 1: frame(0, box: heights[idx(elapsed, 0) % 3])                 // baseline: 0.10 / 0.20 / 0.30 in turn
            case 15: frame(0, angles: nil, box: nil)                              // cover: no face
            default: frame(0, box: 0.45)
            }
        }
        let r = SelfTestRecorder.phaseRecords(s, gate: gate)
        let base = try #require(r[1].boxHeight)
        #expect(base.min == 0.10 && base.median == 0.20 && base.max == 0.30 && r[1].framesWithBox == 20)
        let hold = try #require(r[2].boxHeight)
        #expect(hold.min == 0.45 && hold.median == 0.45 && hold.max == 0.45 && r[2].framesWithBox == 30)
        #expect(r[15].boxHeight == nil && r[15].framesWithBox == 0)
    }

    @Test func boxHeightIsTheHeightNotTheWidth() throws {
        let s = run { _, _ in
            var f = frame(0, box: 0.20)
            f.faceBox = NormalizedRect(x: 0.2, y: 0.2, width: 0.33, height: 0.20)
            return f
        }
        let b = try #require(SelfTestRecorder.phaseRecords(s, gate: gate)[2].boxHeight)
        #expect(b.min == 0.20 && b.max == 0.20)
    }

    @Test func qualityMinMedianAndTheSharesBelowTheTwoThresholds() throws {
        // hold #1 (30 frames): ten each at 0.30 / 0.50 / 0.90.
        let s = run { elapsed, phase in
            guard phase == 2 else { return frame(0) }
            return frame(0, quality: [0.30, 0.50, 0.90][idx(elapsed, 5) / 10])
        }
        let q = try #require(SelfTestRecorder.phaseRecords(s, gate: gate)[2].quality)
        #expect(q.frames == 30 && q.minQuality == 0.30 && q.medianQuality == 0.50)
        #expect(abs(q.fractionBelowLossThreshold - 1.0 / 3) < 1e-12 && abs(q.fractionBelowRecoverThreshold - 2.0 / 3) < 1e-12)
    }

    @Test func aFrameExactlyOnAThresholdIsNotBelowIt() throws {
        // rest #1 (20 frames): ten at exactly 0.40 (the loss threshold), ten at exactly 0.60 (the recovery threshold).
        let s = run { elapsed, phase in
            guard phase == 3 else { return frame(0) }
            return frame(0, quality: idx(elapsed, 8) < 10 ? 0.40 : 0.60)
        }
        let q = try #require(SelfTestRecorder.phaseRecords(s, gate: gate)[3].quality)
        #expect(q.fractionBelowLossThreshold == 0)                 // 0.40 is not below 0.40
        #expect(q.fractionBelowRecoverThreshold == 0.5)            // 0.40 is below 0.60, 0.60 is not
    }

    @Test func theDominantLimitingComponentWinsAndTiesGoToTheFirstName() throws {
        let s = run { elapsed, phase in
            switch phase {
            case 2: frame(0, limiting: idx(elapsed, 5) < 18 ? "size" : "none")        // 18 size, 12 none
            case 4: frame(0, limiting: idx(elapsed, 10) < 15 ? "size" : "none")       // 15 / 15: a tie
            default: frame(0)
            }
        }
        let r = SelfTestRecorder.phaseRecords(s, gate: gate)
        #expect(r[2].dominantLimiting == "size" && r[4].dominantLimiting == "none")
        #expect(abs((r[2].quality?.limitingFractions["size"] ?? 0) - 0.6) < 1e-12)
    }

    @Test func trackerStateSecondsPerPhaseFollowTheFramesAndAddUpToThePhase() throws {
        // hold #1 is 5-8 s: locked until 6.0, holding until 6.5, decaying after that.
        let s = run { elapsed, phase in
            guard phase == 2 else { return frame(0) }
            return frame(0, state: elapsed < 6.0 ? .locked : (elapsed < 6.5 ? .holding : .decaying))
        }
        let r = SelfTestRecorder.phaseRecords(s, gate: gate)
        let st = r[2].stateSeconds
        #expect(abs(st.locked - 1.0) < 1e-9 && abs(st.holding - 0.5) < 1e-9 && abs(st.decaying - 1.5) < 1e-9 && st.staticState == 0)
        #expect(abs(st.total - 3.0) < 1e-9)
        // the neighbouring phases are untouched by it
        #expect(abs(r[1].stateSeconds.locked - 2.0) < 1e-9)
        #expect(abs(r[3].stateSeconds.locked - 2.0) < 1e-9)            // the rest after it: the hold's last frame ends exactly at the boundary
        for rec in r { #expect(abs(rec.stateSeconds.total - (rec.endSeconds - rec.startSeconds)) < 1e-9, "\(rec.name)") }
    }

    @Test func watchdogTicksCarryTheStateWhileTheCameraDeliversNothing() throws {
        // hold #1 (5-8 s): camera frames until 6.0 s, then ONLY watchdog ticks (no face, no box) while the tracker goes
        // holding (6.0-6.5 s) and decaying (6.5 s on). The state seconds must follow the ticks.
        let s = run { elapsed, phase in
            guard phase == 2, elapsed >= 6.0 else { return frame(0) }
            return frame(0, state: elapsed < 6.5 ? .holding : .decaying, quality: 0, limiting: "no frames", angles: nil, box: nil, tick: true)
        }
        let r = SelfTestRecorder.phaseRecords(s, gate: gate)
        let st = r[2].stateSeconds
        #expect(abs(st.locked - 1.0) < 1e-9 && abs(st.holding - 0.5) < 1e-9 && abs(st.decaying - 1.5) < 1e-9, "\(st)")
        let q = try #require(r[2].quality)
        #expect(q.frames == 10 && q.watchdogTicks == 20)                        // 1 s of camera frames, 2 s of ticks at 10 per second
        #expect(r[2].framesWithBox == 10)
    }

    @Test func aPhaseThatNeverStartedHasNoRecordAndTheLockGateShiftIsReflected() throws {
        let real = SelfTestScript.standard
        let gated = try #require(real.firstIndex(of: .cover))
        // Tracking never locks: the loss test gives up, the cover and uncover phases never start.
        let never = run(script: real, until: real.starts[gated] + 11) { _, _ in frame(0, state: .holding) }
        #expect(never.lossGateFailed)
        let r1 = SelfTestRecorder.phaseRecords(never, gate: gate)
        #expect(r1.count == gated && r1.last?.kind == .lossTurn)
        #expect(abs((r1.last?.endSeconds ?? 0) - real.starts[gated]) < 1e-9)

        // Tracking locks 2 s late: the gate opens 1 s after that, the cover phase starts 3 s late, the turn phase is extended.
        let late = run(script: real, until: real.totalDuration + 4) { elapsed, _ in frame(0, state: elapsed < real.starts[gated] + 2 ? .holding : .locked) }
        #expect(late.gateOpened)
        let shift = late.gateShift
        #expect(shift > 2.9 && shift < 3.1)
        let r2 = SelfTestRecorder.phaseRecords(late, gate: gate)
        #expect(r2.count == real.phases.count)
        #expect(abs(r2[gated].startSeconds - (real.starts[gated] + shift)) < 1e-9)
        #expect(abs(r2[gated - 1].endSeconds - (real.starts[gated] + shift)) < 1e-9)
        #expect(abs(r2[gated - 1].stateSeconds.total - (r2[gated - 1].endSeconds - r2[gated - 1].startSeconds)) < 1e-9)
    }
}

@Suite struct FrameSeriesTests {
    /// Row `k` of a run is made from known numbers so every column can be checked against its source.
    func sample() -> SelfTestSession {
        var s = SelfTestSession(script: SelfTestScript.standard.withoutLockGates, lighting: .normalLight, startTime: 100)
        let a = frame(103.0004, state: .holding, quality: 0.12345, limiting: "size", angles: (10.1234, 20.3456, 30.5678), box: 0.456789)   // phase 1 (3-5 s)
        let b = frame(103.5, state: .decaying, quality: 0, limiting: "no face", angles: nil, box: nil)                                     // no face
        let c = frame(104.0, state: .static, quality: 0, limiting: "no frames", angles: nil, box: nil, tick: true)                         // watchdog tick
        for f in [c, a, b] { s.record(f) }               // recorded out of order on purpose: the series is in arrival order
        return s
    }

    @Test func allColumnsHaveOneEntryPerFrameInArrivalOrder() {
        let s = sample()
        let f = SelfTestRecorder.frameSeries(s)
        #expect(f.count == 3)
        let n = f.count
        #expect(f.phase.count == n && f.rawYawDegrees.count == n && f.rawPitchDegrees.count == n && f.rawRollDegrees.count == n
                && f.boxHeight.count == n && f.quality.count == n && f.state.count == n && f.watchdogTick.count == n)
        #expect(f.secondsFromRunStart == f.secondsFromRunStart.sorted())
    }

    @Test func everyColumnCarriesItsOwnSourceValueAtTheStatedPrecision() throws {
        let s = sample()
        let f = SelfTestRecorder.frameSeries(s)
        try #require(f.count == 3)                                                 // fail, don't trap, if rows are missing
        // row 0 = the frame at 103.0004 s => 3.0004 s after the run start, stored to 1 ms
        #expect(f.secondsFromRunStart[0] == 3.0 && f.secondsFromRunStart[1] == 3.5 && f.secondsFromRunStart[2] == 4.0)
        #expect(f.phase == [1, 1, 1])
        #expect(f.rawYawDegrees[0] == 10.12 && f.rawPitchDegrees[0] == 20.35 && f.rawRollDegrees[0] == 30.57)     // 0.01 deg
        #expect(f.boxHeight[0] == 0.4568)                                                                          // 0.0001
        #expect(f.quality[0] == 0.123)                                                                             // 0.001
        #expect(f.state == [1, 2, 3] && f.stateLegend == ["locked", "holding", "decaying", "static"])
        #expect(f.watchdogTick == [false, false, true])
    }

    @Test func noFaceMeansNilAngleAndBoxEntriesButQualityAndStateAreStillThere() throws {
        let s = sample()
        let f = SelfTestRecorder.frameSeries(s)
        try #require(f.count == 3)
        for row in [1, 2] {
            #expect(f.rawYawDegrees[row] == nil && f.rawPitchDegrees[row] == nil && f.rawRollDegrees[row] == nil && f.boxHeight[row] == nil)
        }
        #expect(f.quality[1] == 0 && f.state[1] == 2)
    }

    @Test func columnsAreNotSwappedAndAnglesAreInDegrees() {
        var s = SelfTestSession(script: SelfTestScript.standard.withoutLockGates, lighting: .normalLight, startTime: 0)
        s.record(frame(3.5, angles: (1, 2, 3), box: 0.3))
        let f = SelfTestRecorder.frameSeries(s)
        #expect(f.rawYawDegrees == [1] && f.rawPitchDegrees == [2] && f.rawRollDegrees == [3] && f.boxHeight == [0.3])
    }

    @Test func aNonFiniteAngleOrBoxIsStoredAsNothingNotAsANumber() throws {
        var s = SelfTestSession(script: SelfTestScript.standard.withoutLockGates, lighting: .normalLight, startTime: 0)
        s.record(frame(3.5, angles: (.nan, .infinity, 3), box: .nan))
        let f = SelfTestRecorder.frameSeries(s)
        #expect(f.rawYawDegrees == [nil] && f.rawPitchDegrees == [nil] && f.rawRollDegrees == [3] && f.boxHeight == [nil])
        _ = try JSONEncoder().encode(f)                                            // must not throw on NaN
    }

    @Test func eachStateHasItsOwnCode() {
        var s = SelfTestSession(script: SelfTestScript.standard.withoutLockGates, lighting: .normalLight, startTime: 0)
        for (k, st) in [TrackingState.locked, .holding, .decaying, .static].enumerated() { s.record(frame(3.5 + Double(k) * 0.1, state: st)) }
        #expect(SelfTestRecorder.frameSeries(s).state == [0, 1, 2, 3])
    }

    @Test func theSeriesCoversEveryRecordedFrameOfARealisticRun() {
        let s = simulateSession()
        let total = s.framesByPhase.reduce(0) { $0 + $1.count }
        let f = SelfTestRecorder.frameSeries(s)
        #expect(f.count == total && total > 1000)
        #expect(f.secondsFromRunStart.first == 0 && (f.secondsFromRunStart.last ?? 0) > 46)
        #expect(Set(f.phase).count == 17)
    }
}

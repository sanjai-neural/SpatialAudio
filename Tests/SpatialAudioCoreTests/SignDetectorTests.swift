import Testing
import Foundation
@testable import SpatialAudioCore

private let d2r = Double.pi / 180
private func rad(_ t: AngleTriple) -> VisionFaceAngles { VisionFaceAngles(yaw: t.yaw * d2r, pitch: t.pitch * d2r, roll: t.roll * d2r) }

/// `noise` is the half-range of uniform noise per axis in degrees (robust σ ≈ 0.58 × noise).
private func samples(center: AngleTriple, noise: Double, n: Int, seed: UInt64) -> [VisionFaceAngles] {
    var rng = DeterministicNoise(seed: seed)
    return (0..<n).map { _ in
        rad(AngleTriple(yaw: center.yaw + noise * rng.next(), pitch: center.pitch + noise * rng.next(),
                        roll: center.roll + noise * rng.next()))
    }
}

private let rest = AngleTriple(yaw: 1.5, pitch: -11.7, roll: -3.5)

private func rep(ref: AngleTriple = rest, delta: AngleTriple, noise: Double = 1.5, n: Int = 40,
                 mirrored: Double? = 0, holdFrames: Int? = nil, seed: UInt64 = 1) -> RepetitionEvidence {
    let hold = AngleTriple(yaw: ref.yaw + delta.yaw, pitch: ref.pitch + delta.pitch, roll: ref.roll + delta.roll)
    return RepetitionEvidence(reference: samples(center: ref, noise: noise, n: n, seed: seed), referenceFrames: n,
                              hold: samples(center: hold, noise: noise, n: n, seed: seed &+ 99),
                              holdFrames: holdFrames ?? n, mirroredFraction: mirrored)
}

private func two(_ a: AngleTriple, _ b: AngleTriple? = nil, noise: Double = 1.5) -> [RepetitionEvidence] {
    [rep(delta: a, noise: noise, seed: 1), rep(delta: b ?? a, noise: noise, seed: 7)]
}

@Suite struct SignDetectorTests {
    // MARK: clean data, each axis and direction

    @Test func yawRawPositiveDuringLeftMeansNoInvert() throws {
        let r = SignDetector.analyze(axis: .yaw, evidence: two(AngleTriple(yaw: 40)))
        #expect(r.outcome == .determined && r.rawVisionSign == 1 && r.invertNeeded == false)
        #expect(r.framesMirrored == false && r.repetitions.count == 2 && r.repetitions.allSatisfy { $0.usable })
        let d = try #require(r.repetitions.first)
        #expect(abs(d.intendedDeltaDegrees - 40) < 1.5)                     // reference offsets cancel
    }

    @Test func yawRawNegativeDuringLeftMeansInvert() {
        let r = SignDetector.analyze(axis: .yaw, evidence: two(AngleTriple(yaw: -40)))
        #expect(r.outcome == .determined && r.rawVisionSign == -1 && r.invertNeeded == true)
    }

    @Test func pitchRawNegativeDuringUpMatchesTheDocumentedHeader() {
        // Vision: positive pitch = nodding DOWN, so looking UP should be raw-negative, i.e. no invert.
        let r = SignDetector.analyze(axis: .pitch, evidence: two(AngleTriple(pitch: -25)))
        #expect(r.outcome == .determined && r.rawVisionSign == -1 && r.invertNeeded == false)
        let flipped = SignDetector.analyze(axis: .pitch, evidence: two(AngleTriple(pitch: 25)))
        #expect(flipped.outcome == .determined && flipped.rawVisionSign == 1 && flipped.invertNeeded == true)
    }

    @Test func rollDirections() {
        #expect(SignDetector.analyze(axis: .roll, evidence: two(AngleTriple(roll: 25))).invertNeeded == false)
        #expect(SignDetector.analyze(axis: .roll, evidence: two(AngleTriple(roll: -25))).invertNeeded == true)
    }

    @Test func mirroredFramesAreCompensatedLikeTheMapping() {
        // Mirrored image: Vision yaw/roll flip sign, the mapping flips them back, so the invert answer matches the unmirrored case.
        let yaw = SignDetector.analyze(axis: .yaw, evidence: [rep(delta: AngleTriple(yaw: -40), mirrored: 1, seed: 1),
                                                              rep(delta: AngleTriple(yaw: -40), mirrored: 1, seed: 2)])
        #expect(yaw.invertNeeded == false && yaw.rawVisionSign == -1 && yaw.framesMirrored == true)
        let roll = SignDetector.analyze(axis: .roll, evidence: [rep(delta: AngleTriple(roll: -25), mirrored: 1, seed: 3),
                                                                rep(delta: AngleTriple(roll: -25), mirrored: 1, seed: 4)])
        #expect(roll.invertNeeded == false)
        // Pitch is unaffected by horizontal mirroring.
        let pitch = SignDetector.analyze(axis: .pitch, evidence: [rep(delta: AngleTriple(pitch: -25), mirrored: 1, seed: 5),
                                                                  rep(delta: AngleTriple(pitch: -25), mirrored: 1, seed: 6)])
        #expect(pitch.invertNeeded == false)
    }

    /// Property: whatever the raw direction and mirror state, applying the detected flag through the REAL
    /// mapping makes the instructed movement map to a POSITIVE value.
    @Test func detectedFlagsAlwaysMakeTheInstructedMovePositive() throws {
        for axis in RotationAxis.allCases {
            for sign in [1.0, -1.0] {
                for mirrored in [false, true] {
                    var delta = AngleTriple(); delta[axis] = sign * 30
                    let m: Double = mirrored ? 1 : 0
                    let r = SignDetector.analyze(axis: axis, evidence: [rep(delta: delta, mirrored: m, seed: 11),
                                                                        rep(delta: delta, mirrored: m, seed: 12)])
                    #expect(r.outcome == .determined, "\(axis) \(sign) \(mirrored)")
                    var map = HeadAngleMapping()
                    switch axis {
                    case .yaw: map.invertYaw = try #require(r.invertNeeded)
                    case .pitch: map.invertPitch = try #require(r.invertNeeded)
                    case .roll: map.invertRoll = try #require(r.invertNeeded)
                    }
                    let mapped = map.euler(from: rad(delta), frameMirrored: mirrored).value(for: axis)
                    #expect(mapped > 0, "axis \(axis), raw sign \(sign), mirrored \(mirrored)")
                }
            }
        }
    }

    // MARK: robustness

    @Test func restOffsetsAndNoiseDoNotChangeTheAnswer() {
        let offsetRest = AngleTriple(yaw: -8, pitch: 20, roll: 6)
        let ev = [rep(ref: offsetRest, delta: AngleTriple(yaw: 40), noise: 4, seed: 21),
                  rep(ref: offsetRest, delta: AngleTriple(yaw: 40), noise: 4, seed: 22)]
        let r = SignDetector.analyze(axis: .yaw, evidence: ev)
        #expect(r.outcome == .determined && r.invertNeeded == false)
    }

    @Test func outlierSpikesInTheHoldAreIgnoredByTheMedian() {
        var a = rep(delta: AngleTriple(yaw: 40), seed: 31)
        a.hold[0] = rad(AngleTriple(yaw: -90)); a.hold[1] = rad(AngleTriple(yaw: 90)); a.hold[2] = rad(AngleTriple(yaw: -80))
        let r = SignDetector.analyze(axis: .yaw, evidence: [a, rep(delta: AngleTriple(yaw: 40), seed: 32)])
        #expect(r.outcome == .determined && r.invertNeeded == false)
    }

    @Test func differentMagnitudesStillAgreeButAreNoted() {
        let r = SignDetector.analyze(axis: .yaw, evidence: [rep(delta: AngleTriple(yaw: 60), seed: 1), rep(delta: AngleTriple(yaw: 20), seed: 2)])
        #expect(r.outcome == .determined)
        #expect(r.reasons.contains { $0.contains("magnitudes differ") })
    }

    // MARK: weak data → INCONCLUSIVE, never a guess

    @Test func movementBelowTheFloorIsInconclusive() {
        let yaw = SignDetector.analyze(axis: .yaw, evidence: two(AngleTriple(yaw: 8)))
        #expect(yaw.outcome == .inconclusive && yaw.invertNeeded == nil && yaw.rawVisionSign == nil)
        #expect(yaw.reasons.contains { $0.contains("too small") })
    }

    @Test func thresholdBoundaries() {
        #expect(SignDetector.analyze(axis: .yaw, evidence: two(AngleTriple(yaw: 12))).outcome == .inconclusive)     // < 15°
        #expect(SignDetector.analyze(axis: .yaw, evidence: two(AngleTriple(yaw: 20))).outcome == .determined)       // > 15° (+ noise margin)
        #expect(SignDetector.analyze(axis: .pitch, evidence: two(AngleTriple(pitch: -6))).outcome == .inconclusive) // < 10°
        #expect(SignDetector.analyze(axis: .pitch, evidence: two(AngleTriple(pitch: -15))).outcome == .determined)
        #expect(SignDetector.analyze(axis: .roll, evidence: two(AngleTriple(roll: 6))).outcome == .inconclusive)
        #expect(SignDetector.analyze(axis: .roll, evidence: two(AngleTriple(roll: 15))).outcome == .determined)
    }

    @Test func noisyDataRaisesTheRequiredMovement() {
        // Reference noise σ ≈ 0.58×10 = 5.8° → required ≈ 29°; a 22° movement clears the 15° floor but not 5σ.
        let r = SignDetector.analyze(axis: .yaw, evidence: two(AngleTriple(yaw: 22), noise: 10))
        #expect(r.outcome == .inconclusive)
        #expect(r.repetitions.allSatisfy { $0.requiredMovementDegrees > 22 })
        // The same noise with a big movement is fine.
        #expect(SignDetector.analyze(axis: .yaw, evidence: two(AngleTriple(yaw: 70), noise: 10)).outcome == .determined)
    }

    @Test func pureNoiseNeverProducesASign() {
        for seed in UInt64(1)...20 {
            for axis in RotationAxis.allCases {
                let ev = [rep(delta: AngleTriple(), noise: 3, seed: seed), rep(delta: AngleTriple(), noise: 3, seed: seed &+ 500)]
                #expect(SignDetector.analyze(axis: axis, evidence: ev).outcome == .inconclusive, "seed \(seed) axis \(axis)")
            }
        }
    }

    // MARK: inconsistent data → INCONCLUSIVE

    @Test func conflictingRepetitionsAreInconclusive() {
        let r = SignDetector.analyze(axis: .yaw, evidence: two(AngleTriple(yaw: 40), AngleTriple(yaw: -40)))
        #expect(r.outcome == .inconclusive && r.invertNeeded == nil)
        #expect(r.reasons.contains { $0.contains("disagree") })
        #expect(r.repetitions.allSatisfy { $0.usable })            // each rep alone was fine; the conflict is the problem
    }

    @Test func oneStrongOneWeakRepetitionIsInconclusive() {
        let r = SignDetector.analyze(axis: .yaw, evidence: two(AngleTriple(yaw: 40), AngleTriple(yaw: 5)))
        #expect(r.outcome == .inconclusive)
        #expect(r.reasons.contains { $0.contains("only 1 of 2") })
    }

    @Test func aSingleRepetitionIsNotEnoughByDefault() {
        let r = SignDetector.analyze(axis: .yaw, evidence: [rep(delta: AngleTriple(yaw: 40))])
        #expect(r.outcome == .inconclusive)
        var cfg = SignDetectionConfig(); cfg.requiredValidRepetitions = 1
        #expect(SignDetector.analyze(axis: .yaw, evidence: [rep(delta: AngleTriple(yaw: 40))], config: cfg).outcome == .determined)
    }

    @Test func wrongAxisDominatingIsInconclusive() {
        // The "left" prompts produced mostly a pitch change (e.g. a nod, or a rotated camera): do not call it yaw.
        let r = SignDetector.analyze(axis: .yaw, evidence: two(AngleTriple(yaw: 20, pitch: 30)))
        #expect(r.outcome == .inconclusive)
        #expect(r.reasons.contains { $0.contains("wrong axis") })
        #expect(r.repetitions.allSatisfy { $0.leakageRatio > 1 })
    }

    @Test func moderateLeakageIsAccepted() {
        let r = SignDetector.analyze(axis: .yaw, evidence: two(AngleTriple(yaw: 40, pitch: 8, roll: -6)))
        #expect(r.outcome == .determined)
        #expect(r.repetitions.allSatisfy { $0.leakageRatio < 0.3 })
    }

    @Test func unsteadyHoldIsInconclusive() {
        // Hold samples sweep 0 → 60° (the person was still moving): the median says "30°" but means nothing.
        func sweep(_ seed: UInt64) -> RepetitionEvidence {
            var e = rep(delta: AngleTriple(), seed: seed)
            e.hold = (0..<40).map { rad(AngleTriple(yaw: rest.yaw + 60 * Double($0) / 39, pitch: rest.pitch, roll: rest.roll)) }
            return e
        }
        let r = SignDetector.analyze(axis: .yaw, evidence: [sweep(1), sweep(2)])
        #expect(r.outcome == .inconclusive)
        #expect(r.reasons.contains { $0.contains("not steady") })
    }

    // MARK: face missing

    @Test func tooFewHoldSamplesBecauseTheFaceWasLost() {
        var e = rep(delta: AngleTriple(yaw: 40), seed: 1)
        e.hold = Array(e.hold.prefix(5)); e.holdFrames = 60
        let r = SignDetector.analyze(axis: .yaw, evidence: [e, rep(delta: AngleTriple(yaw: 40), seed: 2)])
        #expect(r.outcome == .inconclusive)
        #expect(r.reasons.contains { $0.contains("too few hold samples") })
    }

    @Test func faceVisibleInOnlyHalfTheHoldFrames() {
        let half = rep(delta: AngleTriple(yaw: 40), n: 30, holdFrames: 60, seed: 3)
        let r = SignDetector.analyze(axis: .yaw, evidence: [half, rep(delta: AngleTriple(yaw: 40), seed: 4)])
        #expect(r.outcome == .inconclusive)
        #expect(r.reasons.contains { $0.contains("face found in only 50%") })
    }

    @Test func noDataAtAllIsInconclusiveNotACrash() {
        let empty = RepetitionEvidence(reference: [], referenceFrames: 0, hold: [], holdFrames: 0, mirroredFraction: nil)
        let r = SignDetector.analyze(axis: .roll, evidence: [empty, empty])
        #expect(r.outcome == .inconclusive)
        #expect(SignDetector.analyze(axis: .roll, evidence: []).outcome == .inconclusive)
    }

    // MARK: mirroring consistency

    @Test func mirroringDifferingBetweenRepetitionsIsInconclusive() {
        let r = SignDetector.analyze(axis: .yaw, evidence: [rep(delta: AngleTriple(yaw: 40), mirrored: 0, seed: 1),
                                                            rep(delta: AngleTriple(yaw: 40), mirrored: 1, seed: 2)])
        #expect(r.outcome == .inconclusive && r.reasons.contains { $0.contains("differs between") })
    }

    @Test func mirroringChangingInsideARepetitionIsInconclusive() {
        let r = SignDetector.analyze(axis: .yaw, evidence: [rep(delta: AngleTriple(yaw: 40), mirrored: 0.5, seed: 1),
                                                            rep(delta: AngleTriple(yaw: 40), mirrored: 0, seed: 2)])
        #expect(r.outcome == .inconclusive && r.reasons.contains { $0.contains("changed within") })
    }

    // MARK: report-level behaviour

    @Test func recommendedMappingTouchesOnlyDeterminedAxes() {
        let yaw = SignDetector.analyze(axis: .yaw, evidence: two(AngleTriple(yaw: -40)))               // determined → invert ON
        let pitch = SignDetector.analyze(axis: .pitch, evidence: two(AngleTriple(pitch: -3)))          // inconclusive
        let roll = SignDetector.analyze(axis: .roll, evidence: two(AngleTriple(roll: 25)))             // determined → invert off
        let report = SignDetectionReport(yaw: yaw, pitch: pitch, roll: roll)
        #expect(report.determinedAxes == [.yaw, .roll] && !report.allDetermined)
        let base = HeadAngleMapping(invertYaw: false, invertPitch: true, invertRoll: true)
        let rec = report.recommendedMapping(over: base)
        #expect(rec.invertYaw == true)          // set from the test
        #expect(rec.invertPitch == true)        // inconclusive: base value kept, NOT guessed
        #expect(rec.invertRoll == false)        // set from the test (overrides base's true)
    }

    @Test func resultsAreCodable() throws {
        let r = SignDetector.analyze(axis: .yaw, evidence: two(AngleTriple(yaw: 40)))
        let back = try JSONDecoder().decode(AxisSignResult.self, from: JSONEncoder().encode(r))
        #expect(back == r)
    }
}

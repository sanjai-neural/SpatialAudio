import Testing
import Foundation
@testable import SpatialAudioCore

private let d2r = Double.pi / 180
private func rad(_ t: AngleTriple) -> VisionFaceAngles { VisionFaceAngles(yaw: t.yaw * d2r, pitch: t.pitch * d2r, roll: t.roll * d2r) }
private let rest = AngleTriple(yaw: 1.5, pitch: -11.7, roll: -3.5)

private func cloud(center: AngleTriple, noise: Double, n: Int, seed: UInt64) -> [AngleTriple] {
    var rng = DeterministicNoise(seed: seed)
    return (0..<n).map { _ in AngleTriple(yaw: center.yaw + noise * rng.next(), pitch: center.pitch + noise * rng.next(), roll: center.roll + noise * rng.next()) }
}

private func evidence(reference: [AngleTriple], hold: [AngleTriple], mirrored: Double? = 0) -> RepetitionEvidence {
    RepetitionEvidence(reference: reference.map(rad), referenceFrames: reference.count, hold: hold.map(rad), holdFrames: hold.count, mirroredFraction: mirrored)
}

private func rep(delta: AngleTriple, noise: Double = 1.5, n: Int = 40, seed: UInt64 = 1) -> RepetitionEvidence {
    let hold = AngleTriple(yaw: rest.yaw + delta.yaw, pitch: rest.pitch + delta.pitch, roll: rest.roll + delta.roll)
    return evidence(reference: cloud(center: rest, noise: noise, n: n, seed: seed), hold: cloud(center: hold, noise: noise, n: n, seed: seed &+ 99))
}

@Suite struct SignDetectorNoiseTests {
    /// 36 steady samples and 4 wild ones. A range would be about 80°; the robust spread is about 1°.
    func referenceWithOutliers() -> [AngleTriple] {
        var ref = cloud(center: rest, noise: 1.5, n: 40, seed: 3)
        for (k, i) in [3, 11, 25, 33].enumerated() { ref[i].yaw += (k % 2 == 0 ? 40 : -40) }       // +40, -40, +40, -40
        return ref
    }

    @Test func theNoiseFigureIsARobustSpreadNotARange() throws {
        let ref = referenceWithOutliers()
        let hold = cloud(center: AngleTriple(yaw: rest.yaw + 30, pitch: rest.pitch, roll: rest.roll), noise: 1.5, n: 40, seed: 9)
        let r = SignDetector.analyze(axis: .yaw, evidence: [evidence(reference: ref, hold: hold), evidence(reference: ref, hold: hold)])
        let first = try #require(r.repetitions.first)
        #expect(first.referenceNoiseDegrees < 2.5, "robust spread \(first.referenceNoiseDegrees)")
        let stats = try #require(first.referenceStats?.yaw)
        #expect(stats.rangeDegrees > 70 && stats.sigmaDegrees < 2.5)          // the range WOULD have said ~80°; the figure used says ~1°
        // required = max(15, 5 × sigma): a range-based noise (5 × ~80 = 400°) would have made any move unusable
        #expect(first.requiredMovementDegrees == max(15, 5 * first.referenceNoiseDegrees))
        #expect(r.outcome == .determined && r.rawVisionSign == 1)
    }

    @Test func aReferenceWindowThatWasNotStillIsNamedAsSuchAndStaysUnusable() throws {
        // Half the reference at -15°, half at +15° yaw (the head swung during the phase that asked for stillness).
        let ref = (0..<40).map { AngleTriple(yaw: $0 < 20 ? -15 : 15, pitch: rest.pitch, roll: rest.roll) }
        let hold = cloud(center: AngleTriple(yaw: 40, pitch: rest.pitch, roll: rest.roll), noise: 1.5, n: 40, seed: 5)
        let r = SignDetector.analyze(axis: .yaw, evidence: [evidence(reference: ref, hold: hold), evidence(reference: ref, hold: hold)])
        #expect(r.outcome == .inconclusive)
        let first = try #require(r.repetitions.first)
        #expect(!first.usable && !first.enoughMovement)
        #expect(first.problems.contains { $0.contains("reference window not steady") }, "\(first.problems)")
        #expect(!first.problems.contains { $0.contains("movement too small") })
        // The requirement itself is unchanged by the better wording: still max(floor, 5 × robust spread).
        #expect(abs(first.requiredMovementDegrees - max(15, 5 * first.referenceNoiseDegrees)) < 1e-9)
        #expect(first.requiredMovementDegrees > 40)
    }

    @Test func aSmallMoveWithAQuietReferenceIsStillJustTooSmall() throws {
        let r = SignDetector.analyze(axis: .yaw, evidence: [rep(delta: AngleTriple(yaw: 8), noise: 0.5), rep(delta: AngleTriple(yaw: 8), noise: 0.5, seed: 2)])
        let first = try #require(r.repetitions.first)
        #expect(first.problems.contains { $0.contains("movement too small") } && !first.problems.contains { $0.contains("not steady") })
    }

    @Test func noThresholdWasLoosened() {
        let c = SignDetectionConfig()
        #expect(c.minMovementDegrees == AngleTriple(yaw: 15, pitch: 10, roll: 10) && c.noiseMultiple == 5 && c.maxLeakageRatio == 0.6)
        #expect(c.maxHoldSpreadRatio == 0.4 && c.requiredValidRepetitions == 2 && c.minFacePresentFraction == 0.6)
    }

    @Test func baselineStatsDescribeTheWindowAndMeasureDrift() throws {
        let flat = try #require(BaselineStats((0..<40).map { 5 + 0.5 * sin(Double($0)) }))
        #expect(flat.samples == 40 && abs(flat.medianDegrees - 5) < 0.5 && flat.driftDegrees < 1)
        let drifting = try #require(BaselineStats((0..<40).map { 5 + 0.5 * Double($0) }))     // 0° to 19.5° ramp
        #expect(drifting.driftDegrees > 12 && drifting.rangeDegrees == 19.5)
        #expect(BaselineStats([]) == nil)
        let short = try #require(BaselineStats([1, 2, 3]))
        #expect(short.driftDegrees == 0)                                                        // too few samples to measure drift
    }

    @Test func everyRepetitionCarriesBaselineStatsForAllThreeAxes() throws {
        let r = SignDetector.analyze(axis: .pitch, evidence: [rep(delta: AngleTriple(pitch: -25)), rep(delta: AngleTriple(pitch: -25), seed: 4)])
        for x in r.repetitions {
            let ref = try #require(x.referenceStats), hold = try #require(x.holdStats)
            #expect(ref.yaw != nil && ref.pitch != nil && ref.roll != nil && hold.pitch != nil)
            #expect(abs((ref.pitch?.medianDegrees ?? 0) - rest.pitch) < 1)
            #expect(abs((hold.pitch?.medianDegrees ?? 0) - (rest.pitch - 25)) < 1)
        }
    }
}

@Suite struct SignDetectorLikelyTests {
    let leaky = AngleTriple(yaw: 25, pitch: 20)            // enough yaw (25° > 15° floor) but pitch leaks at 0.8 (> 0.6)

    func report(yaw: AxisSignResult) -> SignDetectionReport {
        let none = AxisSignResult(axis: .pitch, outcome: .inconclusive, rawVisionSign: nil, invertNeeded: nil, framesMirrored: nil, repetitions: [], reasons: [])
        return SignDetectionReport(yaw: yaw, pitch: none, roll: none)
    }

    @Test func allRepetitionsWithEnoughMovementAgreeButLeakageFailsIsLikelyNotDetermined() throws {
        let r = SignDetector.analyze(axis: .yaw, evidence: [rep(delta: leaky), rep(delta: leaky, seed: 5)])
        #expect(r.outcome == .likely && r.rawVisionSign == 1 && r.invertNeeded == false)
        #expect(r.repetitions.allSatisfy { $0.enoughMovement && $0.leakageFailed && !$0.usable })
        #expect(r.reasons.first?.contains("LIKELY, not DETERMINED") == true && r.reasons.first?.contains("NEVER applied") == true)
    }

    @Test func aLikelyAxisIsNeverPartOfTheRecommendedMappingNorCountedAsDetermined() {
        let likely = SignDetector.analyze(axis: .yaw, evidence: [rep(delta: AngleTriple(yaw: -25, pitch: 20)), rep(delta: AngleTriple(yaw: -25, pitch: 20), seed: 5)])
        #expect(likely.outcome == .likely && likely.invertNeeded == true)       // raw sign negative would mean "invert" if it were determined
        let rep = report(yaw: likely)
        #expect(rep.determinedAxes.isEmpty && rep.likelyAxes == [.yaw])
        #expect(rep.recommendedMapping(over: HeadAngleMapping()) == HeadAngleMapping())
        #expect(rep.recommendedMapping(over: HeadAngleMapping(invertPitch: true)) == HeadAngleMapping(invertPitch: true))
    }

    @Test func oneRepetitionWithEnoughMovementIsNotEnoughForLikely() {
        let tooSmall = rep(delta: AngleTriple(yaw: 6, pitch: 1), noise: 0.5, seed: 8)
        let r = SignDetector.analyze(axis: .yaw, evidence: [rep(delta: leaky), tooSmall])
        #expect(r.outcome == .inconclusive)
    }

    @Test func aCleanRepetitionPlusALeakyOneIsLikely() {
        let r = SignDetector.analyze(axis: .yaw, evidence: [rep(delta: AngleTriple(yaw: 40, pitch: 2)), rep(delta: leaky, seed: 5)])
        #expect(r.outcome == .likely)
        #expect(r.repetitions[0].usable && r.repetitions[1].leakageFailed)
    }

    @Test func disagreeingDirectionsAreInconclusiveEvenWhenLeaky() {
        let r = SignDetector.analyze(axis: .yaw, evidence: [rep(delta: leaky), rep(delta: AngleTriple(yaw: -25, pitch: 20), seed: 5)])
        #expect(r.outcome == .inconclusive && r.reasons.contains { $0.contains("disagree") })
    }

    @Test func aLeakyRepetitionWithAnUnsteadyHoldDoesNotCountAsEnoughMovement() {
        // Hold alternating between 5° and 45°: big median move but the hold is nowhere near steady.
        let ref = cloud(center: rest, noise: 1.5, n: 40, seed: 1)
        let wobble = (0..<40).map { AngleTriple(yaw: rest.yaw + ($0 % 2 == 0 ? 5 : 55), pitch: rest.pitch + 20, roll: rest.roll) }
        let r = SignDetector.analyze(axis: .yaw, evidence: [evidence(reference: ref, hold: wobble), evidence(reference: ref, hold: wobble)])
        #expect(r.outcome == .inconclusive && !r.repetitions[0].enoughMovement)
    }

    @Test func cleanDataIsStillDeterminedAndHasNoLikelyAxes() {
        let r = SignDetector.analyze(axis: .roll, evidence: [rep(delta: AngleTriple(roll: 25)), rep(delta: AngleTriple(roll: 25), seed: 5)])
        #expect(r.outcome == .determined && report(yaw: r).likelyAxes.isEmpty)
    }

    @Test func likelyResultsSurviveAJSONRoundTrip() throws {
        let r = SignDetector.analyze(axis: .yaw, evidence: [rep(delta: leaky), rep(delta: leaky, seed: 5)])
        let back = try JSONDecoder().decode(AxisSignResult.self, from: JSONEncoder().encode(r))
        #expect(back == r && back.outcome == .likely)
    }
}

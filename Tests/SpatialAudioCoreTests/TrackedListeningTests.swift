import Testing
import Foundation
@testable import SpatialAudioCore

// Step 3b: the pure logic of head-tracked listening (roll forced to 0, mode exclusion, volume policy). No audio, no camera, no clock.

@Suite("RollRemoval") struct RollRemovalTests {
    private func q(_ y: Double, _ p: Double, _ r: Double) -> Quaternion { Quaternion(euler: EulerAngles(yawDegrees: y, pitchDegrees: p, rollDegrees: r)) }

    @Test func keepsYawAndPitchAndZeroesRollOverAGrid() {
        for y in stride(from: -150.0, through: 150, by: 30) {
            for p in stride(from: -60.0, through: 60, by: 20) {
                for r in stride(from: -170.0, through: 170, by: 34) {
                    let e = RollRemoval.removingRoll(from: q(y, p, r)).euler
                    #expect(abs(e.rollDegrees) < 1e-9, "yaw \(y) pitch \(p) roll \(r): roll \(e.rollDegrees)")
                    #expect(abs(e.yawDegrees - y) < 1e-9, "yaw \(y) pitch \(p) roll \(r): yaw \(e.yawDegrees)")
                    #expect(abs(e.pitchDegrees - p) < 1e-9, "yaw \(y) pitch \(p) roll \(r): pitch \(e.pitchDegrees)")
                }
            }
        }
    }

    @Test func aPureRollBecomesTheIdentityAndAnythingWithoutRollIsUntouched() {
        for r in [-75.0, -20, 5, 40, 120] {
            #expect(RollRemoval.removingRoll(from: q(0, 0, r)).angle(to: .identity) < 1e-9)
        }
        let noRoll = q(35, -12, 0)
        #expect(RollRemoval.removingRoll(from: noRoll).angle(to: noRoll) < 1e-9)
        #expect(RollRemoval.removingRoll(from: .identity).angle(to: .identity) < 1e-12)
    }

    @Test func theResultIsAUnitQuaternionAndNonFiniteInputBecomesTheIdentity() {
        #expect(abs(RollRemoval.removingRoll(from: q(20, 30, -75)).norm - 1) < 1e-12)
        #expect(RollRemoval.removingRoll(from: Quaternion(w: .nan, x: 0, y: 0, z: 0)).angle(to: .identity) < 1e-12)
    }

    @Test func theEulerOverloadChangesOnlyRoll() {
        let e = EulerAngles(yawDegrees: 33, pitchDegrees: -14, rollDegrees: 61)
        let r = RollRemoval.removingRoll(from: e)
        #expect(r.yaw == e.yaw && r.pitch == e.pitch && r.roll == 0)
    }
}

@Suite("ListeningMode exclusion") struct ListeningModeExclusionTests {
    @Test func aloneEachModeMayStart() {
        for m in ListeningMode.allCases { #expect(ListeningModeExclusion.conflict(requested: m, active: []) == nil) }
        for m in ListeningMode.allCases { #expect(ListeningModeExclusion.conflict(requested: m, active: [m]) == nil) }   // itself running is not another mode
    }

    @Test func everyOtherModeRunningBlocksEveryRequest() {
        for requested in ListeningMode.allCases {
            for other in ListeningMode.allCases where other != requested {
                let why = ListeningModeExclusion.conflict(requested: requested, active: [other])
                #expect(why != nil, "\(requested) while \(other)")
                #expect(why?.contains("Stop it first") == true)
            }
        }
    }

    @Test func theCameraModeNeedsAFreeCameraAndNothingElseDoes() {
        #expect(ListeningModeExclusion.conflict(requested: .cameraTracked, active: [], cameraBusy: true)?.contains("camera is already in use") == true)
        #expect(ListeningModeExclusion.conflict(requested: .scripted, active: [], cameraBusy: true) == nil)
        #expect(ListeningModeExclusion.conflict(requested: .blind, active: [], cameraBusy: true) == nil)
    }

    @Test func theMessageNamesTheModeThatIsRunning() {
        #expect(ListeningModeExclusion.conflict(requested: .cameraTracked, active: [.scripted])?.contains("scripted") == true)
        #expect(ListeningModeExclusion.conflict(requested: .cameraTracked, active: [.blind])?.contains("blind") == true)
        #expect(ListeningModeExclusion.conflict(requested: .blind, active: [.cameraTracked])?.contains("Head-tracked") == true)
    }
}

@Suite("Tracked listening policy") struct TrackedListeningPolicyTests {
    @Test func defaultIsLowAndBelowTheCap() {
        #expect(TrackedListeningPolicy.defaultVolume == 0.15)
        #expect(TrackedListeningPolicy.maximumVolume == 0.40)
        #expect(TrackedListeningPolicy.defaultVolume < TrackedListeningPolicy.maximumVolume)
    }

    @Test func theCapAppliesAndBadValuesAreSilence() {
        #expect(TrackedListeningPolicy.clampedVolume(1) == 0.40)
        #expect(TrackedListeningPolicy.clampedVolume(0.41) == 0.40)
        #expect(TrackedListeningPolicy.clampedVolume(0.25) == 0.25)
        #expect(TrackedListeningPolicy.clampedVolume(0) == 0)
        #expect(TrackedListeningPolicy.clampedVolume(-3) == 0)
        #expect(TrackedListeningPolicy.clampedVolume(.nan) == 0)
        #expect(TrackedListeningPolicy.clampedVolume(.infinity) == 0)
    }
}

@Suite("Tracked listening zeroRoll mapping") struct ZeroRollMappingTests {
    private func q(_ y: Double, _ p: Double, _ r: Double) -> Quaternion { Quaternion(euler: EulerAngles(yawDegrees: y, pitchDegrees: p, rollDegrees: r)) }

    @Test func zeroRollKeepsYawAndPitchAndRemovesRoll() {
        let m = ListenerMapping(zeroRoll: true)
        #expect(!m.isIdentity)
        for (y, p, r) in [(30.0, -10.0, 45.0), (-70, 25, -75), (0, 0, 60), (120, 0, 10)] {
            let e = m.apply(to: q(y, p, r)).euler
            #expect(abs(e.rollDegrees) < 1e-9 && abs(e.yawDegrees - y) < 1e-9 && abs(e.pitchDegrees - p) < 1e-9, "\(y) \(p) \(r)")
        }
    }

    @Test func theListenerOrientationIsLevelSoTheRightVectorHasNoVerticalPart() {
        // A listener without roll has its right-hand vector (forward x up) in the horizontal plane, for any yaw and pitch.
        let m = ListenerMapping(zeroRoll: true)
        for (y, p, r) in [(30.0, -10.0, 45.0), (-70, 25, -75), (0, 0, 60), (150, -40, 33)] {
            let o = ListenerFrame.orientation(for: q(y, p, r), mapping: m)
            #expect(abs(o.right.y) < 1e-12, "\(y) \(p) \(r): right.y \(o.right.y)")
        }
        let withRoll = ListenerFrame.orientation(for: q(0, 0, 45))
        #expect(abs(withRoll.right.y) > 0.5)                                    // the control: without the switch a roll tilts it
    }

    @Test func zeroRollWinsOverInvertRollAndTheDefaultIsUnchanged() {
        let m = ListenerMapping(invertRoll: true, zeroRoll: true)
        #expect(abs(m.apply(to: q(20, 5, 30)).euler.rollDegrees) < 1e-9)
        #expect(ListenerMapping().zeroRoll == false)
        #expect(ListenerMapping().isIdentity)
        let kept = ListenerMapping().apply(to: q(20, 5, 30)).euler
        #expect(abs(kept.rollDegrees - 30) < 1e-9)                               // off: roll passes through as before
    }
}

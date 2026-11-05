import Testing
import Foundation
@testable import SpatialAudioCore

/// Head pose -> AVAudioEnvironmentNode listener orientation, and the geometry the listening test compares against.
/// The engine side of the same claims (that AVAudioEnvironmentNode really applies the vectors this way) is tested
/// by offline rendering in SpatialAudioEngineTests.
@Suite struct ListenerFrameTests {
    // MARK: - exact vectors for one head motion at a time

    @Test func neutralPoseGivesTheHeaderDefaults() {
        let o = ListenerFrame.orientation(for: .identity)
        #expect(near(o.forward, Vector3(0, 0, -1)))
        #expect(near(o.up, Vector3(0, 1, 0)))
        #expect(o == .neutral)
    }

    @Test func turningLeftPointsTheNoseAtMinusX() {
        let o = ListenerFrame.orientation(for: yawQ(90))
        #expect(near(o.forward, Vector3(-1, 0, 0)))
        #expect(near(o.up, Vector3(0, 1, 0)))
    }

    @Test func turningRightPointsTheNoseAtPlusX() {
        let o = ListenerFrame.orientation(for: yawQ(-90))
        #expect(near(o.forward, Vector3(1, 0, 0)))
    }

    @Test func lookingUpRaisesTheNoseAndTipsTheTopOfTheHeadBackward() {
        let o = ListenerFrame.orientation(for: pitchQ(90))
        #expect(near(o.forward, Vector3(0, 1, 0)))
        #expect(near(o.up, Vector3(0, 0, 1)))          // +Z = behind the original facing direction
    }

    @Test func rightEarDownTipsTheTopOfTheHeadTowardTheRight() {
        let o = ListenerFrame.orientation(for: Quaternion(axis: .forward, angle: 90 * deg))
        #expect(near(o.forward, Vector3(0, 0, -1)))     // the roll axis does not move the nose
        #expect(near(o.up, Vector3(1, 0, 0)))
        #expect(near(o.right, Vector3(0, -1, 0)))       // the right ear now points down
    }

    // MARK: - properties over many poses

    @Test func vectorsStayUnitOrthogonalAndRightHanded() {
        for y in stride(from: -170.0, through: 170, by: 40) {
            for p in stride(from: -80.0, through: 80, by: 32) {
                for r in stride(from: -170.0, through: 170, by: 55) {
                    let q = eulerQ(y, p, r)
                    let o = ListenerFrame.orientation(for: q)
                    #expect(abs(o.forward.length - 1) < 1e-9, "forward length \(y),\(p),\(r)")
                    #expect(abs(o.up.length - 1) < 1e-9, "up length \(y),\(p),\(r)")
                    #expect(abs(o.forward.dot(o.up)) < 1e-9, "orthogonal \(y),\(p),\(r)")
                    #expect(near(o.right, q.rotate(.right)), "right-handed \(y),\(p),\(r)")
                }
            }
        }
    }

    @Test func aBadPoseBecomesNeutralInsteadOfPoisoningTheEngine() {
        #expect(ListenerFrame.orientation(for: Quaternion(w: .nan, x: 0, y: 0, z: 0)) == .neutral)
        #expect(ListenerFrame.orientation(for: Quaternion(w: 0, x: 0, y: 0, z: 0)) == .neutral)
        #expect(ListenerFrame.orientation(for: Quaternion(w: .infinity, x: 0, y: 0, z: 0)) == .neutral)
    }

    @Test func anUnnormalizedPoseGivesTheSameAnswerAsItsNormalizedForm() {
        let q = eulerQ(35, -10, 12)
        let scaled = Quaternion(w: q.w * 3, x: q.x * 3, y: q.y * 3, z: q.z * 3)
        let a = ListenerFrame.orientation(for: q), b = ListenerFrame.orientation(for: scaled)
        #expect(near(a.forward, b.forward) && near(a.up, b.up))
    }

    // MARK: - mapping (listening-test flip switches)

    @Test func identityMappingChangesNothing() {
        let q = eulerQ(40, 15, -20)
        #expect(ListenerMapping().isIdentity)
        #expect(ListenerFrame.orientation(for: q, mapping: ListenerMapping()) == ListenerFrame.orientation(for: q))
    }

    @Test func eachFlipNegatesExactlyItsOwnAxis() {
        let q = eulerQ(30, 20, 10)
        #expect(angleDeg(ListenerMapping(invertYaw: true).apply(to: q), eulerQ(-30, 20, 10)) < 1e-6)
        #expect(angleDeg(ListenerMapping(invertPitch: true).apply(to: q), eulerQ(30, -20, 10)) < 1e-6)
        #expect(angleDeg(ListenerMapping(invertRoll: true).apply(to: q), eulerQ(30, 20, -10)) < 1e-6)
        #expect(angleDeg(ListenerMapping(invertYaw: true, invertPitch: true, invertRoll: true).apply(to: q), eulerQ(-30, -20, -10)) < 1e-6)
    }

    @Test func flippingYawMirrorsLeftAndRightOfTheListenerNose() {
        let normal = ListenerFrame.orientation(for: yawQ(40))
        let flipped = ListenerFrame.orientation(for: yawQ(40), mapping: ListenerMapping(invertYaw: true))
        #expect(near(flipped.forward, Vector3(-normal.forward.x, normal.forward.y, normal.forward.z)))
    }

    @Test func mappingIsCodableForSavingTheListeningTestChoice() throws {
        let m = ListenerMapping(invertYaw: true, invertPitch: false, invertRoll: true)
        let back = try JSONDecoder().decode(ListenerMapping.self, from: JSONEncoder().encode(m))
        #expect(back == m)
    }

    @Test func differsHonoursTheTolerance() {
        let a = ListenerOrientation.neutral
        var b = a
        b.forward = Vector3(0, 1e-9, -1)
        #expect(!a.differs(from: b))
        b.forward = Vector3(0, 1e-3, -1)
        #expect(a.differs(from: b))
        var c = a
        c.up = Vector3(0.1, 1, 0)
        #expect(a.differs(from: c))
    }

    // MARK: - geometry: where does a fixed source seem to be?

    @Test func aFrontSourceMovesToTheRightWhenTheHeadTurnsLeft() {
        let ahead = Vector3.direction(azimuthDegrees: 0, elevationDegrees: 0, distance: 2)
        let left = ListenerGeometry.relativeDirection(of: ahead, listenerPose: yawQ(60))
        #expect(abs(left.azimuthDegrees - 60) < 1e-9)     // positive azimuth = to the RIGHT
        #expect(abs(left.elevationDegrees) < 1e-9 && abs(left.distance - 2) < 1e-9)
        let right = ListenerGeometry.relativeDirection(of: ahead, listenerPose: yawQ(-60))
        #expect(abs(right.azimuthDegrees + 60) < 1e-9)
    }

    @Test func aFrontSourceSeemsBelowWhenTheHeadLooksUp() {
        let ahead = Vector3.direction(azimuthDegrees: 0, elevationDegrees: 0, distance: 2)
        #expect(abs(ListenerGeometry.relativeDirection(of: ahead, listenerPose: pitchQ(30)).elevationDegrees + 30) < 1e-9)
        #expect(abs(ListenerGeometry.relativeDirection(of: ahead, listenerPose: pitchQ(-30)).elevationDegrees - 30) < 1e-9)
    }

    @Test func aSourceOnTheRightRisesWhenTheRightEarGoesDown() {
        let rightSide = Vector3.direction(azimuthDegrees: 60, elevationDegrees: 0, distance: 2)
        let rightEarDown = Quaternion(axis: .forward, angle: 30 * deg)
        #expect(ListenerGeometry.relativeDirection(of: rightSide, listenerPose: rightEarDown).elevationDegrees > 20)
        let leftEarDown = Quaternion(axis: .forward, angle: -30 * deg)
        #expect(ListenerGeometry.relativeDirection(of: rightSide, listenerPose: leftEarDown).elevationDegrees < -20)
    }

    @Test func theGeometryAgreesWithTheSpeakerConventionAndTheListenerFrame() {
        // The front-right speaker (azimuth +30) is straight ahead once the head has turned RIGHT by 30 degrees,
        // and 60 degrees off to the right once the head has turned LEFT by 30 degrees (the head moved away from it).
        let r = SpeakerLayout.dolby714.speaker(.R)!.position(distance: 2)!
        #expect(abs(ListenerGeometry.relativeDirection(of: r, listenerPose: yawQ(-30)).azimuthDegrees) < 1e-9)
        #expect(abs(ListenerGeometry.relativeDirection(of: r, listenerPose: yawQ(30)).azimuthDegrees - 60) < 1e-9)
        // And the listener frame agrees: after a 30 degree left turn the nose points at the (30 degrees left) front-left speaker.
        let l = SpeakerLayout.dolby714.speaker(.L)!.position(distance: 1)!
        #expect(near(ListenerFrame.orientation(for: yawQ(30)).forward, l))
    }

    @Test func directionHelperMatchesTheAxes() {
        #expect(near(.direction(azimuthDegrees: 0, elevationDegrees: 0), Vector3(0, 0, -1)))
        #expect(near(.direction(azimuthDegrees: 90, elevationDegrees: 0), Vector3(1, 0, 0)))
        #expect(near(.direction(azimuthDegrees: -90, elevationDegrees: 0), Vector3(-1, 0, 0)))
        #expect(near(.direction(azimuthDegrees: 180, elevationDegrees: 0), Vector3(0, 0, 1)))
        #expect(near(.direction(azimuthDegrees: 0, elevationDegrees: 90), Vector3(0, 1, 0)))
        #expect(near(.direction(azimuthDegrees: 90, elevationDegrees: 0, distance: 3), Vector3(3, 0, 0)))
    }

    @Test func aSourceAtTheCentreOfTheHeadHasNoDirection() {
        let d = ListenerGeometry.relativeDirection(of: .zero, listenerPose: yawQ(33))
        #expect(d.distance == 0 && d.azimuthDegrees == 0 && d.elevationDegrees == 0)
        #expect(d.plainEnglish == "at the centre of your head")
    }

    // MARK: - wording

    @Test func plainEnglishNamesTheSideAndTheHeight() {
        func words(_ az: Double, _ el: Double = 0) -> String {
            RelativeDirection(azimuthDegrees: az, elevationDegrees: el, distance: 2).plainEnglish
        }
        #expect(words(0) == "straight ahead")
        #expect(words(5) == "straight ahead")
        #expect(words(45) == "to your RIGHT, 45° from straight ahead")
        #expect(words(-45) == "to your LEFT, 45° from straight ahead")
        #expect(words(-120) == "to your LEFT, 120° from straight ahead (behind you)")
        #expect(words(180) == "directly behind you")
        #expect(words(0, 30) == "straight ahead, ABOVE (30°)")
        #expect(words(90, -20) == "to your RIGHT, 90° from straight ahead, BELOW (20°)")
        #expect(words(90, 5) == "to your RIGHT, 90° from straight ahead")      // below the 8 degree height threshold
    }
}

import Testing
import Foundation
@testable import SpatialAudioCore

@Suite struct SpeakerLayoutTests {
    let layout = SpeakerLayout.dolby714

    @Test func hasTwelveUniqueSpeakers() {
        #expect(layout.speakers.count == 12)
        #expect(Set(layout.speakers.map(\.id)).count == 12)
        #expect(Set(layout.speakers.map(\.id)) == Set(SpeakerID.allCases))
    }

    @Test func groupCounts() {
        #expect(layout.speakers.filter { $0.group == .earLevel }.count == 7)
        #expect(layout.speakers.filter { $0.group == .height }.count == 4)
        #expect(layout.speakers.filter { $0.group == .lfe }.count == 1)
        #expect(layout.spatialized.count == 11)
    }

    @Test func lfeIsNotSpatialized() {
        let lfe = layout.lfe!
        #expect(lfe.id == .LFE)
        #expect(!lfe.isSpatialized)
        #expect(lfe.position() == nil)
        #expect(!layout.spatialized.contains { $0.id == .LFE })
    }

    @Test func earLevelSpeakersAreAtZeroElevation() {
        for s in layout.speakers where s.group == .earLevel { #expect(s.elevationDegrees == 0) }
    }

    @Test func heightSpeakersAre45DegreesUp() {
        for s in layout.speakers where s.group == .height { #expect(s.elevationDegrees == 45) }
    }

    @Test func referenceAnglesMatchDolbyGuidelines() {
        #expect(layout.speaker(.L)?.azimuthDegrees == -30)
        #expect(layout.speaker(.R)?.azimuthDegrees == 30)
        #expect(layout.speaker(.C)?.azimuthDegrees == 0)
        #expect(layout.speaker(.Rrs)?.azimuthDegrees == 135)
        #expect(layout.speaker(.Rtf)?.azimuthDegrees == 30)
        #expect(layout.speaker(.Rtr)?.azimuthDegrees == 135)
    }

    @Test func leftRightAreMirrorImages() {
        let pairs: [(SpeakerID, SpeakerID)] = [(.L, .R), (.Lss, .Rss), (.Lrs, .Rrs), (.Ltf, .Rtf), (.Ltr, .Rtr)]
        for (l, r) in pairs {
            let pl = layout.speaker(l)!.position()!, pr = layout.speaker(r)!.position()!
            #expect(near(Vector3(-pl.x, pl.y, pl.z), pr), "\(l)/\(r)")
        }
    }

    @Test func positionsAreOnUnitSphereAndScaleWithDistance() {
        for s in layout.spatialized {
            #expect(abs(s.position()!.length - 1) < 1e-12)
            #expect(abs(s.position(distance: 3)!.length - 3) < 1e-12)
        }
    }

    @Test func positionsUseProjectCoordinateFrame() {
        #expect(near(layout.speaker(.C)!.position()!, Vector3(0, 0, -1)))        // front = -Z
        #expect(near(layout.speaker(.Rss)!.position()!, Vector3(1, 0, 0)))       // right = +X
        #expect(near(layout.speaker(.Lss)!.position()!, Vector3(-1, 0, 0)))
        #expect(layout.speaker(.Lrs)!.position()!.z > 0)                         // rear = +Z
        #expect(layout.speaker(.Ltf)!.position()!.y > 0.7)                       // up = +Y
        #expect(layout.speaker(.R)!.position()!.x > 0)
    }

    @Test func listenerTurningTowardASpeakerMovesItToFront() {
        // Positive yaw = turn left. Turning 30° left should bring L (az -30) to straight ahead
        // in the head frame: head-frame direction = inverse(head) rotated world direction.
        let head = yawQ(30)
        let inHead = head.inverse().rotate(layout.speaker(.L)!.position()!)
        #expect(near(inHead, .forward, 1e-9))
    }
}

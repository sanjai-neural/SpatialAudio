import Testing
import Foundation
@testable import SpatialAudioCore

// Step 6b-3c-0: the arithmetic of the offline calibration and of the gain-cap PROPOSAL. Pure numbers; nothing here measures a device.

@Suite struct LevelMathTests {
    @Test func amplitudeRatiosAreTwentyLogTen() {
        #expect(abs(LevelMath.amplitudeDecibels(0.5) - (-6.0206)) < 1e-3 && abs(LevelMath.amplitudeDecibels(1)) < 1e-12 && abs(LevelMath.amplitudeDecibels(0.1) - (-20)) < 1e-9)
        #expect(abs(LevelMath.amplitudeDecibels(1 / 2.0.squareRoot()) - (-3.0103)) < 1e-3 && LevelMath.amplitudeDecibels(0) == -.infinity)
    }

    @Test func rmsAndPeakAreWhatTheirNamesSay() {
        #expect(abs(LevelMath.rms([3, 4][...]) - 12.5.squareRoot()) < 1e-6 && LevelMath.rms([][...]) == 0 && LevelMath.rms([0.5, 0.5, 0.5][...]) == 0.5)
        #expect(LevelMath.peak([0.5, -1.0, 0.25][...]) == 1.0 && LevelMath.peak([][...]) == 0 && LevelMath.peak([-0.75, 0.5][...]) == 0.75)
        #expect(LevelMath.peak([0.6, -0.8][...]) != LevelMath.rms([0.6, -0.8][...]))
    }
}

@Suite struct GainCapProposalTests {
    @Test func theTargetIsMinus16DB() {
        #expect(GainCapProposal.targetPeakDecibels == -16)
    }

    @Test func theCapKeepsTheWorstPeakAtOrBelowTheTargetAndIsRoundedDown() throws {
        // worst peak gain 1.4012: 10^(-16/20) / 1.4012 = 0.11313 -> 0.11
        #expect(GainCapProposal.propose(worstFullScalePeakGain: 1.4012) == 0.11)
        // worst peak gain 1.0: 0.158489 -> 0.15 (a round-to-nearest would give 0.16, whose peak would be above the target)
        let one = try #require(GainCapProposal.propose(worstFullScalePeakGain: 1.0))
        #expect(one == 0.15 && one * 1.0 <= pow(10, -16.0 / 20))
        // raw 0.119 -> 0.11, not 0.12
        let g = 0.11885 / 1.0
        #expect(GainCapProposal.propose(worstFullScalePeakGain: pow(10, -16.0 / 20) / g) == 0.11)
        for worst in [0.5, 0.9, 1.2, 1.4012, 2.0, 3.7] {
            let cap = try #require(GainCapProposal.propose(worstFullScalePeakGain: worst))
            #expect(cap * worst <= pow(10, -16.0 / 20) + 1e-12, "worst \(worst): cap \(cap)")
        }
    }

    @Test func aQuietGraphIsCappedAtOneAndNeverAbove() {
        #expect(GainCapProposal.propose(worstFullScalePeakGain: 0.05) == 1 && GainCapProposal.propose(worstFullScalePeakGain: 0.001) == 1)
    }

    @Test func theTargetIsAParameterNotAConstantBakedIn() {
        #expect(GainCapProposal.propose(worstFullScalePeakGain: 1.0, targetDecibels: -6) == 0.5)
        #expect(GainCapProposal.propose(worstFullScalePeakGain: 1.0, targetDecibels: -20) == 0.1)
    }

    @Test func aPeakGainThatIsNotAPositiveFiniteNumberGivesNoProposal() {
        for bad in [0.0, -1.0, .nan, .infinity, -.infinity] { #expect(GainCapProposal.propose(worstFullScalePeakGain: bad) == nil, "\(bad)") }
    }
}

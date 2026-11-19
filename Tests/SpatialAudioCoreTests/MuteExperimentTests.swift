import Testing
import Foundation
@testable import SpatialAudioCore

// Step 6b-3c-0: the pre-registered mute-experiment criteria, the process-tap plan, the mute option and the scenario parser. The criteria are "pre-registered GUESS, fixed before the run"; these tests pin them. Nothing here
// says what a muted process-specific tap does on a real Mac: the observations the evaluator is given in these tests are INVENTED inputs for the rule, not results.

private func allReturned(after seconds: Double = 2) -> [MuteObservation] { MuteExperimentCriteria.requiredScenarios.map { MuteObservation(kind: $0, value: .returned(seconds: seconds)) } }
private func replacing(_ kind: MuteScenarioKind, with value: MuteObservationValue, in list: [MuteObservation]) -> [MuteObservation] {
    list.map { $0.kind == kind ? MuteObservation(kind: kind, value: value) : $0 }
}

@Suite struct MuteExperimentCriteriaTests {
    @Test func theRegisteredNumbersAndLabelsAreTheApprovedOnes() {
        #expect(MuteExperimentCriteria.version == "6b-3c0-prereg-1" && MuteExperimentCriteria.registration == "pre-registered GUESS, fixed before the run")
        #expect(MuteExperimentCriteria.returnWithinSeconds == 5)
        #expect(MuteExperimentCriteria.requiredScenarios == [.normalExit, .sigint, .sigkill, .tapDestroyedWhileIORuns, .ioStoppedWhileTapLives])
        #expect(MuteScenarioKind.allCases.map(\.rawValue) == ["normal-exit", "sigint", "sigkill", "destroy-tap", "stop-io"])
    }

    @Test func allFiveBackWithinTheWindowIsAGo() {
        let v = MuteExperimentEvaluator.evaluate(allReturned())
        #expect(v.kind == .go && v.text.hasPrefix("GO"))
        #expect(v.text.contains("6b-3c0-prereg-1") && v.text.contains("pre-registered GUESS, fixed before the run"))
    }

    @Test func exactlyFiveSecondsStillCountsAndJustOverFiveDoesNot() {
        #expect(MuteExperimentEvaluator.evaluate(replacing(.sigint, with: .returned(seconds: 5.0), in: allReturned())).kind == .go)
        #expect(MuteExperimentEvaluator.evaluate(replacing(.sigint, with: .returned(seconds: 5.01), in: allReturned())).kind == .noGo)
        #expect(MuteExperimentEvaluator.evaluate(replacing(.sigint, with: .returned(seconds: 0), in: allReturned())).kind == .go)
        #expect(MuteExperimentEvaluator.evaluate(replacing(.sigint, with: .returned(seconds: 50), in: allReturned())).kind == .noGo, "50 s is far outside the window")
    }

    @Test func aScenarioThatNeverCameBackIsANoGoAndTheVerdictNamesIt() {
        let v = MuteExperimentEvaluator.evaluate(replacing(.sigkill, with: .neverReturned, in: allReturned()))
        #expect(v.kind == .noGo && v.text.contains("sigkill") && v.text.contains("never back") && v.text.contains("Muting is not shipped"))
        let late = MuteExperimentEvaluator.evaluate(replacing(.tapDestroyedWhileIORuns, with: .returned(seconds: 9), in: allReturned()))
        #expect(late.kind == .noGo && late.text.contains("destroy-tap") && late.text.contains("9.0"))
    }

    @Test func aScenarioThatNeverWentSilentIsInconclusiveNotASuccess() {
        let v = MuteExperimentEvaluator.evaluate(replacing(.normalExit, with: .neverMuted, in: allReturned()))
        #expect(v.kind == .inconclusive && v.text.contains("normal-exit") && v.text.contains("never went silent"))
    }

    @Test func aMissingDuplicatedOrInvalidScenarioIsIncompleteNotAGo() {
        let missing = Array(allReturned().dropLast())
        #expect(MuteExperimentEvaluator.evaluate(missing).kind == .incomplete && MuteExperimentEvaluator.evaluate(missing).text.contains("stop-io"))
        #expect(MuteExperimentEvaluator.evaluate(Array(allReturned().filter { $0.kind != .sigkill })).kind == .incomplete, "sigkill is required")
        let dup = allReturned() + [MuteObservation(kind: .sigint, value: .returned(seconds: 1))]
        let d = MuteExperimentEvaluator.evaluate(dup)
        #expect(d.kind == .incomplete && d.text.contains("more than once") && d.text.contains("sigint"))
        #expect(MuteExperimentEvaluator.evaluate(replacing(.sigint, with: .returned(seconds: -1), in: allReturned())).kind == .incomplete)
        #expect(MuteExperimentEvaluator.evaluate(replacing(.sigint, with: .returned(seconds: .nan), in: allReturned())).kind == .incomplete)
        #expect(MuteExperimentEvaluator.evaluate(replacing(.sigint, with: .returned(seconds: .infinity), in: allReturned())).kind == .incomplete)
        #expect(MuteExperimentEvaluator.evaluate([]).kind == .incomplete, "no observations is never a go")
    }

    @Test func aFailureIsDecisiveWhateverElseIsMissingOrUnmuted() {
        var list = Array(allReturned().dropFirst(2))                                   // three scenarios missing
        list.append(MuteObservation(kind: .normalExit, value: .neverReturned))
        #expect(MuteExperimentEvaluator.evaluate(list).kind == .noGo, "a failure decides, even with scenarios missing (precedence: noGo over incomplete)")
        let mixed = replacing(.sigint, with: .neverMuted, in: replacing(.sigkill, with: .neverReturned, in: allReturned()))
        #expect(MuteExperimentEvaluator.evaluate(mixed).kind == .noGo, "noGo over inconclusive")
    }

    @Test func incompleteComesBeforeInconclusive() {
        let list = replacing(.sigint, with: .neverMuted, in: Array(allReturned().dropLast()))
        #expect(MuteExperimentEvaluator.evaluate(list).kind == .incomplete)
    }
}

@Suite struct MuteExperimentArgumentsTests {
    private func parse(_ s: String...) -> MuteExperimentArguments.Parsed { MuteExperimentArguments.parse(["app"] + s) }

    @Test func notRequestedWithoutTheSwitch() {
        #expect(parse() == .notRequested && parse("--ring-probe", "5") == .notRequested)
    }

    @Test func numbersNoneAndUnmutedParseToTheThreeObservationKinds() {
        guard case .request(let list) = parse("--mute-experiment-verdict=normal-exit=2.5,sigint=none,sigkill=unmuted,destroy-tap=0,stop-io=5") else { Issue.record("not a request"); return }
        #expect(list == [MuteObservation(kind: .normalExit, value: .returned(seconds: 2.5)), MuteObservation(kind: .sigint, value: .neverReturned), MuteObservation(kind: .sigkill, value: .neverMuted),
                         MuteObservation(kind: .tapDestroyedWhileIORuns, value: .returned(seconds: 0)), MuteObservation(kind: .ioStoppedWhileTapLives, value: .returned(seconds: 5))])
        #expect(parse("--mute-experiment-verdict", "sigint=1") == .request([MuteObservation(kind: .sigint, value: .returned(seconds: 1))]))
    }

    @Test func nameMappingIsExact() {
        guard case .request(let a) = parse("--mute-experiment-verdict=normal-exit=1"), case .request(let b) = parse("--mute-experiment-verdict=sigint=1") else { Issue.record("not requests"); return }
        #expect(a.first?.kind == .normalExit && b.first?.kind == .sigint)
    }

    @Test func unknownNamesBadValuesAndMissingEqualsAreRefused() {
        for arg in ["--mute-experiment-verdict=reboot=1", "--mute-experiment-verdict=sigint", "--mute-experiment-verdict=sigint=soon", "--mute-experiment-verdict=sigint=1,=2", "--mute-experiment-verdict=Sigint=1"] {
            guard case .invalid(let why) = parse(arg) else { Issue.record("accepted \(arg)"); continue }
            #expect(!why.isEmpty, "\(arg)")
        }
        guard case .invalid = parse("--mute-experiment-verdict") else { Issue.record("accepted a switch with no list"); return }
    }

    @Test func anEmptyListIsARequestWithNoObservationsAndThatIsIncompleteNotAGo() {
        guard case .request(let list) = parse("--mute-experiment-verdict=") else { Issue.record("not a request"); return }
        #expect(list.isEmpty && MuteExperimentEvaluator.evaluate(list).kind == .incomplete)
    }
}

@Suite struct ProcessTapPlanTests {
    @Test func theIncludeListHoldsOnlyTheTarget() {
        #expect(ProcessTapPlan.make(targetObject: 30, ownObject: 7, targetPID: 500, ownPID: 100) == .success([30]))
        #expect(ProcessTapPlan.make(targetObject: 30, ownObject: nil, targetPID: 500, ownPID: 100) == .success([30]))
    }

    @Test func thisProcessIsNeverTheTargetByPIDOrByObject() {
        #expect(ProcessTapPlan.make(targetObject: 30, ownObject: 7, targetPID: 100, ownPID: 100) == .failure(.targetIsThisProcess))
        #expect(ProcessTapPlan.make(targetObject: 7, ownObject: 7, targetPID: 500, ownPID: 100) == .failure(.targetIsThisProcess))
    }

    @Test func anUnknownTargetObjectIsRefused() {
        #expect(ProcessTapPlan.make(targetObject: 0, ownObject: 7, targetPID: 500, ownPID: 100) == .failure(.targetNotAnAudioProcess))
        #expect(ProcessTapPlan.message(.targetNotAnAudioProcess).contains("is the player running"))
        #expect(ProcessTapPlan.message(.targetIsThisProcess).contains("never taps itself"))
    }
}

@Suite struct MuteBehaviorAndScenarioParsingTests {
    @Test func theDefaultIsUnmutedAndTheWordsParseExactly() {
        #expect(RingProbeMuteBehavior.defaultBehavior == .unmuted && ProcessTapSpec(targetPID: 5).mute == .unmuted)
        #expect(RingProbeMuteBehavior.parse("unmuted") == .unmuted && RingProbeMuteBehavior.parse("muted") == .muted && RingProbeMuteBehavior.parse("mutedwhentapped") == .mutedWhenTapped)
    }

    @Test func unknownWordsAreRefusedNotTakenAsUnmuted() {
        for w in ["", "mute", "Muted", "MUTED", "mutedWhenTapped", "always", "1"] { #expect(RingProbeMuteBehavior.parse(w) == nil, "\(w)") }
    }

    @Test func scenariosParseWithTheirKindAndTime() {
        #expect(MuteScenario.parse("destroy-tap@20") == .destroyTap(atSeconds: 20) && MuteScenario.parse("stop-io@20.5") == .stopIO(atSeconds: 20.5))
        #expect(MuteScenario.destroyTap(atSeconds: 3).kind == .tapDestroyedWhileIORuns && MuteScenario.stopIO(atSeconds: 3).kind == .ioStoppedWhileTapLives)
        #expect(MuteScenario.destroyTap(atSeconds: 3).atSeconds == 3 && MuteScenario.stopIO(atSeconds: 4).atSeconds == 4)
    }

    @Test func badScenariosAreRefused() {
        for bad in ["destroy-tap@0", "destroy-tap@-1", "stop-io@0", "stop-io@nan", "stop-io@inf", "destroy-tap@", "destroy-tap", "@5", "DESTROY-TAP@5", "kill@5", "destroy-tap@five", "stop-io@5@6"] {
            #expect(MuteScenario.parse(bad) == nil, "\(bad)")
        }
    }
}

import Testing
import Foundation
@testable import SpatialAudioCore

// Step 6b-3c-0: the new switches of the ring probe. There is still NO gain or volume option; a mute option exists only for the process-specific tap and defaults to unmuted.

@Suite struct ProcessTapArgumentsTests {
    private func request(_ a: [String]) -> RingProbeRequest? {
        if case .request(let r) = RingProbeArguments.parse(["app"] + a) { return r } else { return nil }
    }
    private func invalid(_ a: [String]) -> String? {
        if case .invalid(let why) = RingProbeArguments.parse(["app"] + a) { return why } else { return nil }
    }

    @Test func aProcessPIDIsParsedAndTheMuteDefaultsToUnmuted() {
        let r = request(["--ring-probe", "60", "--ring-probe-process-pid=1234"])
        #expect(r?.processPID == 1234 && r?.tapMute == .unmuted && r?.muteScenario == nil && r?.deviceTap == false && r?.seconds == 60)
        #expect(request(["--ring-probe-process-pid=77", "--ring-probe", "5"])?.processPID == 77, "either order")
    }

    @Test func withoutTheSwitchThereIsNoProcessTap() {
        let r = request(["--ring-probe", "60"])
        #expect(r?.processPID == nil && r?.tapMute == .unmuted && r?.muteScenario == nil)
    }

    @Test func theMuteOptionIsExplicitAndParsedExactly() {
        for (word, expected) in [("unmuted", RingProbeMuteBehavior.unmuted), ("muted", .muted), ("mutedwhentapped", .mutedWhenTapped)] {
            #expect(request(["--ring-probe", "30", "--ring-probe-process-pid=9", "--ring-probe-tap-mute=\(word)"])?.tapMute == expected, "\(word)")
        }
        for word in ["", "mute", "Muted", "mutedWhenTapped", "yes"] {
            #expect(invalid(["--ring-probe", "30", "--ring-probe-process-pid=9", "--ring-probe-tap-mute=\(word)"]) != nil, "a mute word that is not exact is refused: \(word)")
        }
        #expect(invalid(["--ring-probe", "30", "--ring-probe-process-pid=9", "--ring-probe-tap-mute"]) != nil)
    }

    @Test func aMuteOptionOrAScenarioWithoutAProcessPIDIsRefused() {
        #expect((invalid(["--ring-probe", "30", "--ring-probe-tap-mute=muted"]) ?? "").contains("exist only with --ring-probe-process-pid"))
        #expect((invalid(["--ring-probe", "30", "--ring-probe-mute-scenario=destroy-tap@5"]) ?? "").contains("exist only with --ring-probe-process-pid"))
        #expect(invalid(["--ring-probe", "30", "--ring-probe-device-tap", "--ring-probe-tap-mute=muted"]) != nil, "a mute is never applied to the all-but-us tap")
        #expect(invalid(["--ring-probe-simulate", "30", "--ring-probe-tap-mute=muted"]) != nil)
    }

    @Test func theTwoTapsAreMutuallyExclusive() {
        #expect((invalid(["--ring-probe", "30", "--ring-probe-device-tap", "--ring-probe-process-pid=9"]) ?? "").contains("two different taps"))
        #expect(invalid(["--ring-probe", "30", "--ring-probe-process-pid=9", "--ring-probe-device-tap"]) != nil)
    }

    @Test func badPIDsAreRefusedNotIgnored() {
        for pid in ["0", "-1", "-5000", "abc", "12.5", "", "99999999999", " 5"] {
            #expect(invalid(["--ring-probe", "30", "--ring-probe-process-pid=\(pid)"]) != nil, "pid \(pid)")
        }
        #expect(invalid(["--ring-probe", "30", "--ring-probe-process-pid"]) != nil)
    }

    @Test func aRepeatedProcessPIDIsRefused() {
        #expect((invalid(["--ring-probe", "30", "--ring-probe-process-pid=5", "--ring-probe-process-pid=6"]) ?? "").contains("once"))
    }

    @Test func aScenarioIsParsedWithItsTime() {
        #expect(request(["--ring-probe", "30", "--ring-probe-process-pid=9", "--ring-probe-mute-scenario=destroy-tap@12"])?.muteScenario == .destroyTap(atSeconds: 12))
        #expect(request(["--ring-probe", "30", "--ring-probe-process-pid=9", "--ring-probe-mute-scenario=stop-io@7.5"])?.muteScenario == .stopIO(atSeconds: 7.5))
        for bad in ["", "destroy-tap", "destroy-tap@0", "stop-io@-2", "reboot@5", "destroy-tap@x"] {
            #expect(invalid(["--ring-probe", "30", "--ring-probe-process-pid=9", "--ring-probe-mute-scenario=\(bad)"]) != nil, "\(bad)")
        }
    }

    @Test func theProcessSwitchesNeedAProbeFlagAndAreRefusedAlone() {
        for args in [["--ring-probe-process-pid=5"], ["--ring-probe-process-pid=5", "--ring-probe-tap-mute=muted"], ["--ring-probe-process-pid=5", "--ring-sim-ppm=3"]] {
            #expect(invalid(args) != nil, "\(args)")
        }
        #expect((invalid(["--ring-probe-process-pid=5"]) ?? "").contains("need one of --ring-probe"))
        #expect((invalid(["--ring-probe-device-tap"]) ?? "").contains("--ring-probe-device-tap needs one of"), "the device-tap message is unchanged")
    }

    @Test func theSwitchesWorkWithTheRecoveryAndSimulatedFlagsToo() {
        #expect(request(["--ring-probe-recovery", "600", "--ring-probe-process-pid=9"])?.recovery == true)
        #expect(request(["--ring-probe-simulate", "5", "--ring-probe-process-pid=9", "--ring-probe-tap-mute=muted"])?.simulate == true)
    }

    @Test func thereIsStillNoGainOptionAndNamingOneIsRefusedWithTheProcessSwitches() {
        for g in ["--gain=1", "--output-volume=1", "--mixer-gain"] {
            #expect((invalid(["--ring-probe", "30", "--ring-probe-process-pid=9", g]) ?? "").contains("no gain or volume option"), "\(g)")
        }
        let names = Mirror(reflecting: RingProbeRequest(seconds: 1, simulate: false, simulatedProducerPPM: 0, simulatedUnderrunAtSeconds: nil, simulatedUnderrunStallSeconds: 0)).children.compactMap(\.label)
        #expect(!names.contains { $0.lowercased().contains("gain") || $0.lowercased().contains("volume") })
    }

    @Test func theProcessTapFileStemHasItsOwnPrefixAndKeepsTheSimulatedSuffix() {
        let d = Date(timeIntervalSince1970: 0), utc = TimeZone(identifier: "UTC")!
        #expect(RingProbeReport.fileStem(date: d, timeZone: utc, simulated: false, recovery: false, deviceTap: false, processTap: true) == "ringprocesstap-19700101-000000")
        #expect(RingProbeReport.fileStem(date: d, timeZone: utc, simulated: true, recovery: true, deviceTap: false, processTap: true) == "ringprocesstap-19700101-000000-SIMULATED")
        #expect(RingProbeReport.fileStem(date: d, timeZone: utc, simulated: false, recovery: false, deviceTap: true) == "ringdevicetap-19700101-000000")
        #expect(RingProbeReport.fileStem(date: d, timeZone: utc, simulated: false) == "ringprobe-19700101-000000")
    }
}

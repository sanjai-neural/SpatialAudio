import Testing
import Foundation
@testable import SpatialAudioCore

/// Step 2e additions to the report: per-phase records and the per-frame series (schema 3), and compatibility with older files.
/// The simulated user makes the data here; these tests check the PLUMBING (that what the pipeline did reaches the report), never
/// what a real person or camera does.
@Suite struct SelfTestReportStep2eTests {
    func session() -> SelfTestSession { simulateSession() }
    func report(_ s: SelfTestSession? = nil) -> SelfTestReport {
        SelfTestAnalyzer.analyze(s ?? session(), context: testContext())
    }

    @Test func schemaThreeCarriesOneRecordPerPhaseAndOneSeriesRowPerFrame() throws {
        let s = session()
        let r = report(s)
        #expect(r.schemaVersion == 3)
        let phases = try #require(r.phases)
        #expect(phases.count == s.script.phases.count && phases.map(\.index) == Array(0..<s.script.phases.count))
        let series = try #require(r.frameSeries)
        #expect(series.count == s.framesByPhase.reduce(0) { $0 + $1.count })
        // the phases cover the whole run: their state seconds add up to the run length
        #expect(abs(phases.reduce(0) { $0 + $1.stateSeconds.total } - s.script.totalDuration) < 1e-6)
        #expect(Set(phases.map(\.kind)) == [.getReady, .baseline, .hold, .rest, .lossTurn, .cover, .uncover])
    }

    @Test func theTrackerStatesOfTheLossTestReachThePerPhaseRecords() throws {
        let phases = try #require(report().phases)
        let cover = try #require(phases.first { $0.kind == .cover })
        // The state machine's configured hold (0.5 s) and decay (1.5 s) show up as seconds; frames arrive every 33 ms.
        #expect(abs(cover.stateSeconds.holding - 0.5) < 0.07 && abs(cover.stateSeconds.decaying - 1.5) < 0.07)
        #expect(cover.stateSeconds.staticState > 1.5 && cover.stateSeconds.locked < 1.0)
        let hold = try #require(phases.first { $0.kind == .hold })
        #expect(hold.stateSeconds.locked > 2.9 && hold.stateSeconds.holding == 0 && hold.stateSeconds.decaying == 0)
    }

    @Test func faceBoxHeightAndQualityComeFromTheFramesOfEachPhase() throws {
        let phases = try #require(report().phases)
        let base = try #require(phases.first { $0.kind == .baseline })
        let box = try #require(base.boxHeight)
        #expect(box.min == goodFaceBox.height && box.median == goodFaceBox.height && box.max == goodFaceBox.height)
        let q = try #require(base.quality)
        #expect(q.minQuality == 1 && q.medianQuality == 1 && q.fractionBelowLossThreshold == 0 && q.fractionBelowRecoverThreshold == 0)
        #expect(base.dominantLimiting == "none")
        let cover = try #require(phases.first { $0.kind == .cover })
        #expect(cover.dominantLimiting == "no face" && (cover.quality?.fractionBelowLossThreshold ?? 0) > 0.5)
        #expect(cover.framesWithBox < (cover.quality?.frames ?? 0))               // the covered lens: most frames have no face, so no box
    }

    @Test func groupSummariesNowAlsoCarryTheMedianQuality() throws {
        let groups = try #require(report().qualityByPhase)
        #expect(groups.allSatisfy { $0.medianQuality != nil })
    }

    @Test func theSeriesColumnsAgreeWithTheFramesOfThePhaseTheyBelongTo() throws {
        let s = session()
        let r = report(s)
        let f = try #require(r.frameSeries)
        for p in [2, 8, 12, 15] {                                                // a hold of each move, and the cover phase
            let rows = f.phase.indices.filter { f.phase[$0] == p }
            #expect(rows.count == s.framesByPhase[p].count, "phase \(p)")
        }
        // first row of hold #1 against its source frame
        let src = s.framesByPhase[2][0]
        let row = try #require(f.phase.firstIndex(of: 2))
        let a = try #require(src.angles)
        #expect(abs((f.rawYawDegrees[row] ?? .nan) - a.yaw * 180 / .pi) < 0.0051)
        #expect(abs((f.rawPitchDegrees[row] ?? .nan) - a.pitch * 180 / .pi) < 0.0051)
        #expect(abs((f.rawRollDegrees[row] ?? .nan) - a.roll * 180 / .pi) < 0.0051)
        #expect(f.state[row] == FrameSeries.stateCode(src.state) && f.watchdogTick[row] == src.isWatchdogTick)
    }

    @Test func markdownShowsOneRowPerPhaseAndNeverTheFrameSeries() throws {
        let r = report()
        let md = r.markdown()
        #expect(md.contains("### Per phase, whole phase, in run order") && md.contains("box h min / med / max")
                && md.contains("locked / holding / decaying / static (s)"))
        let rows = md.split(separator: "\n").filter { $0.range(of: #"^\| \d+ \| "#, options: .regularExpression) != nil }
        #expect(rows.count == (r.phases?.count ?? -1))
        #expect(md.contains("| 2 | hold: turn LEFT #1 |") && md.contains("| 15 | loss test: cover |"))
        #expect(md.contains("Per-frame series: \(r.frameSeries?.count ?? -1) frames"))
        #expect(md.split(separator: "\n").count < 200 && md.utf8.count < 40_000)    // the series is not dumped into the text
        #expect(!md.contains("NaN") && md.range(of: #"(?i)\binf\b"#, options: .regularExpression) == nil)
    }

    @Test func theJSONRoundTripsWithTheSeriesAndHasAllTheColumns() throws {
        let r = report()
        let back = try SelfTestReport.decode(r.jsonData())
        #expect(back == r)
        let object = try #require(JSONSerialization.jsonObject(with: r.jsonData()) as? [String: Any])
        let series = try #require(object["frameSeries"] as? [String: Any])
        #expect(Set(series.keys) == ["stateLegend", "secondsFromRunStart", "phase", "rawYawDegrees", "rawPitchDegrees", "rawRollDegrees",
                                     "boxHeight", "quality", "state", "watchdogTick"])
        let lengths = Set(series.filter { $0.key != "stateLegend" }.map { ($0.value as? [Any])?.count ?? -1 })
        #expect(lengths.count == 1 && lengths.first == r.frameSeries?.count)
    }

    @Test func aSchemaTwoFileWithoutTheNewFieldsStillDecodesAndRenders() throws {
        let r = report()
        var object = try #require(JSONSerialization.jsonObject(with: r.jsonData()) as? [String: Any])
        object["schemaVersion"] = 2
        object.removeValue(forKey: "phases"); object.removeValue(forKey: "frameSeries")
        object["qualityByPhase"] = (object["qualityByPhase"] as? [[String: Any]])?.map { var g = $0; g.removeValue(forKey: "medianQuality"); return g }
        let old = try SelfTestReport.decode(JSONSerialization.data(withJSONObject: object))
        #expect(old.schemaVersion == 2 && old.phases == nil && old.frameSeries == nil)
        #expect(old.qualityByPhase?.allSatisfy { $0.medianQuality == nil } == true)
        let md = old.markdown()
        #expect(!md.contains("### Per phase") && !md.contains("Per-frame series") && md.contains("## 4. Tracking quality"))
    }

    @Test func theRealSchemaTwoReportOf1458StillDecodes() throws {
        // The real 14:58 run (schema 2). Skipped silently where the file is absent (it is not committed until Sanjai says so).
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        url.appendPathComponent("docs/test-results/selftest-20261105-145801-normal-light.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let old = try SelfTestReport.decode(Data(contentsOf: url))
        #expect(old.schemaVersion == 2 && old.phases == nil && old.frameSeries == nil && !old.isSimulated)
        #expect(old.qualityByPhase?.count == 10 && old.signs.roll.outcome == .inconclusive)
        _ = old.markdown()
    }
}

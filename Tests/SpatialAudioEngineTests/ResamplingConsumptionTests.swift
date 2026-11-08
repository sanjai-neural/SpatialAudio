import AVFoundation
import CoreAudio
import CSystemAudioRing
import Foundation
import SpatialAudioCore
import Testing

// Step 6b-2b: the offline resampling-consumption experiment (docs/STATUS.md "Step 6b-2b offline experiment"). OFFLINE, one Mac, UNVERIFIED for the device path.
//
// A test-local harness (NOT RingProbeEngine, which builds its stereo format at the SOURCE rate and cannot make a rate mismatch): a producer writes a ramp into the real
// ring, an AVAudioEngine in OFFLINE manual-rendering mode at the OUTPUT rate pulls it through two real source nodes into the main mixer, and the output is analyzed by
// ResamplingConsumptionAnalyzer. Single-threaded and deterministic: produce, render, snapshot, repeat. No sleeps, no timers, no threads, no wall-clock verdicts.
// The mixer's output volume stays at its default (1.0) and is only ever set by `ManualOnlyGain.raise`, which refuses on any engine that is not in manual-rendering mode.
// Only the CONTROL (case 1) is asserted; cases 2 to 5 are printed by the opt-in table (SA_RESAMPLING_TABLE=1). The plan, tolerances and predictions were written
// before the first run (docs/STATUS.md quotes them).

enum ManualOnlyGainError: Error, Equatable { case notManualRendering }

enum ManualOnlyGain {
    /// Sets the main mixer's output volume, but only on an engine that is in manual-rendering mode (offline, no device). On any other engine it throws and touches nothing.
    static func raise(_ engine: AVAudioEngine, to volume: Float = 1) throws {
        guard engine.isInManualRenderingMode else { throw ManualOnlyGainError.notManualRendering }
        engine.mainMixerNode.outputVolume = volume
    }
}

/// Writes the ramp Float(j) * 2^-20 (j = global source frame) on both channels of the real ring through the real producer function, 512 frames per commit.
final class RampProducer {
    static let blockFrames = 512
    let ring: OpaquePointer
    private let abl: UnsafeMutableAudioBufferListPointer
    private let storage: UnsafeMutableRawPointer
    private(set) var committed: Int64 = 0
    /// nil: write the ramp. Otherwise write this constant (the per-case gain probe).
    let constant: Float?

    init(ring: OpaquePointer, constant: Float? = nil) {
        self.ring = ring
        self.constant = constant
        storage = UnsafeMutableRawPointer.allocate(byteCount: Self.blockFrames * 2 * 4, alignment: 16)
        abl = AudioBufferList.allocate(maximumBuffers: 1)
        abl[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(Self.blockFrames * 2 * 4), mData: storage)
    }

    deinit { free(abl.unsafeMutablePointer); storage.deallocate() }

    func commitBlock() {
        let p = storage.assumingMemoryBound(to: Float.self)
        for i in 0..<Self.blockFrames {
            let v = constant ?? Float(committed + Int64(i)) * Float(1.0 / ResamplingConsumptionConfig.rampUnit)
            p[2 * i] = v; p[2 * i + 1] = v
        }
        var now = AudioTimeStamp(), inputTime = AudioTimeStamp(), outputTime = AudioTimeStamp()
        var output = AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer())
        _ = SARingIOProc(0, &now, abl.unsafePointer, &inputTime, &output, &outputTime, UnsafeMutableRawPointer(ring))
        committed += Int64(Self.blockFrames)
    }
}

struct CaseSpec: Equatable {
    var number: Int
    var sourceRate: Double
    var outputRate: Double
    var renderFrames: Int
}

struct CaseRun {
    var spec: CaseSpec
    var renders: [ResamplingRender]
    var underrunBlocks: [UInt64]            // left, right (final)
    var countersStableAfterEveryRender: Bool
    var committedFrames: Int64
    var threads: (beforeEngine: Int, afterStart: Int, afterRenders: Int)
}

enum HarnessError: Error { case engine(String), rampWouldLeaveExactRange(Int64), renderFailed(Int) }

private let renderCount = 2000
private let fillTarget: Int64 = 4096

/// Threads in this process (libproc), or -1. Reported, not asserted.
private func processThreadCount() -> Int {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    return proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size) == size ? Int(info.pti_threadnum) : -1
}

private func snapshot(_ ring: OpaquePointer) -> SARingSnapshot { var s = SARingSnapshot(); _ = SARingTakeSnapshot(ring, &s); return s }

private func connect(_ engine: AVAudioEngine, _ a: AVAudioNode, _ b: AVAudioNode, format: AVAudioFormat) throws {
    if #available(macOS 27.0, *) { try engine.connectNode(a, to: b, format: format) } else { engine.connect(a, to: b, format: format) }
}

/// One case: K renders of `spec.renderFrames` frames at `spec.outputRate`, two mono source nodes at `spec.sourceRate`, node 1 muted.
private func runCase(_ spec: CaseSpec, renders K: Int = renderCount, constant: Float? = nil) throws -> CaseRun {
    let threadsBefore = processThreadCount()
    let ring = SARingCreate(32768)!
    let producer = RampProducer(ring: ring, constant: constant)
    let engine = AVAudioEngine()
    guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: spec.outputRate, channels: 2),
          let mono = AVAudioFormat(standardFormatWithSampleRate: spec.sourceRate, channels: 1) else { throw HarnessError.engine("formats") }
    // AVAudioEngine.h: enable manual rendering BEFORE touching the mixer or output node.
    try engine.enableManualRenderingMode(.offline, format: outFormat, maximumFrameCount: 4096)
    var nodes: [AVAudioNode] = []
    for channel in 0..<2 {
        guard let reader = SARingGetReader(ring, UInt32(channel)), let node = SACreateSourceNode(reader, mono) else { throw HarnessError.engine("source node \(channel)") }
        engine.attach(node)
        try connect(engine, node, engine.mainMixerNode, format: mono)
        nodes.append(node)
    }
    (nodes[1] as? AVAudioMixing)?.volume = 0                      // only node 0 (the left reader) reaches the output
    try ManualOnlyGain.raise(engine)
    try engine.start()
    let threadsAfterStart = processThreadCount()
    guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else { throw HarnessError.engine("buffer") }

    var out: [ResamplingRender] = []
    var stable = true
    for k in 0..<K {
        while snapshot(ring).reader.0.fill < fillTarget {
            producer.commitBlock()
            if producer.committed >= (1 << 24) { throw HarnessError.rampWouldLeaveExactRange(producer.committed) }
        }
        let pre = snapshot(ring)
        let status = try engine.renderOffline(AVAudioFrameCount(spec.renderFrames), to: buffer)
        guard status == .success else { throw HarnessError.renderFailed(k) }
        let post = snapshot(ring)
        let again = snapshot(ring)                                 // nothing may still be happening once renderOffline has returned
        if again.reader.0.calls != post.reader.0.calls || again.reader.0.cursor != post.reader.0.cursor || again.reader.1.calls != post.reader.1.calls { stable = false }
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        out.append(ResamplingRender(pulledFrames: Int64(post.reader.0.framesRequested &- pre.reader.0.framesRequested), calls: Int64(post.reader.0.calls &- pre.reader.0.calls),
                                    cursorAfter: post.reader.0.cursor, samples: samples))
    }
    let threadsAfterRenders = processThreadCount()
    let final = snapshot(ring)
    engine.stop()
    for n in nodes { engine.detach(n) }
    nodes.removeAll()
    SARingFree(ring)                                              // single-threaded: nothing can call the ring any more
    return CaseRun(spec: spec, renders: out, underrunBlocks: [final.reader.0.underrunBlocks, final.reader.1.underrunBlocks], countersStableAfterEveryRender: stable,
                   committedFrames: producer.committed, threads: (threadsBefore, threadsAfterStart, threadsAfterRenders))
}

private func analyze(_ run: CaseRun, gain: Double) -> ResamplingConsumptionResult? {
    ResamplingConsumptionAnalyzer.analyze(renders: run.renders, config: ResamplingConsumptionConfig(sourceRate: run.spec.sourceRate, outputRate: run.spec.outputRate,
                                                                                                     renderFrames: run.spec.renderFrames, gain: gain))
}

/// G from the control's RAMP: the slope of the case where the ratio is exactly 1 (the plan's original method).
private func measuredGain(_ control: CaseRun) -> Double? { analyze(control, gain: 1)?.slopeTimesGain }

private let probeConstant: Float = 0.25
private let probeRenders = 400

/// G per case from a CONSTANT source (added after the first table run; see docs): the mixer's output over the constant.
private func probeGain(_ spec: CaseSpec) throws -> ResamplingConstantGain? {
    ResamplingConsumptionAnalyzer.constantGain(renders: try runCase(spec, renders: probeRenders, constant: probeConstant).renders, constant: probeConstant)
}

@Suite(.serialized) struct ResamplingConsumptionControlTests {
    @Test func theGainGuardRefusesAnyEngineThatIsNotInManualRenderingMode() {
        let live = AVAudioEngine()                                // a device-mode engine: never started, never given a node
        #expect(!live.isInManualRenderingMode)
        #expect(throws: ManualOnlyGainError.notManualRendering) { try ManualOnlyGain.raise(live) }
        #expect(live.mainMixerNode.outputVolume == 1, "the refused call must not have touched the volume (its own default is 1.0)")
        let manual = AVAudioEngine()
        #expect((try? manual.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, maximumFrameCount: 512)) != nil)
        manual.mainMixerNode.outputVolume = 0.25
        #expect((try? ManualOnlyGain.raise(manual, to: 1)) != nil && manual.mainMixerNode.outputVolume == 1, "an engine in manual-rendering mode is allowed")
    }

    @Test func theRampProducerWritesTheExactRampOnBothChannelsThroughTheRealRing() {
        let ring = SARingCreate(32768)!
        defer { SARingFree(ring) }
        let p = RampProducer(ring: ring)
        for _ in 0..<3 { p.commitBlock() }
        #expect(p.committed == 1536 && snapshot(ring).w == 1536 && snapshot(ring).commits == 3 && snapshot(ring).rejectedCommits == 0)
        // read the ring back through a reader: frames 0..<512 must be j * 2^-20 on the left reader
        var buf = [Float](repeating: -1, count: 512)
        var silent = false
        var ts = AudioTimeStamp()
        let status: OSStatus = buf.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 2048, mData: raw.baseAddress))
            return SARingRender(SARingGetReader(ring, 0)!, &silent, &ts, 512, &list)
        }
        #expect(status == 0 && !silent)
        #expect((0..<512).allSatisfy { buf[$0] == Float($0) * Float(1.0 / ResamplingConsumptionConfig.rampUnit) }, "the ramp must restart nowhere: frame j carries j * 2^-20")
        var buf2 = [Float](repeating: -1, count: 512)
        _ = buf2.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 2048, mData: raw.baseAddress))
            return SARingRender(SARingGetReader(ring, 0)!, &silent, &ts, 512, &list)
        }
        #expect(buf2[0] == 512 * Float(1.0 / ResamplingConsumptionConfig.rampUnit) && buf2[511] == 1023 * Float(1.0 / ResamplingConsumptionConfig.rampUnit), "the second block continues the ramp")
    }

    /// THE CONTROL (case 1: 48000 -> 48000, render 512). Everything it asserts is a control of the harness, not a result about resampling.
    @Test func theControlCaseKeepsEveryAssumptionOfTheHarness() throws {
        let spec = CaseSpec(number: 1, sourceRate: 48_000, outputRate: 48_000, renderFrames: 512)
        let run = try runCase(spec)
        // (a) all K renders completed
        #expect(run.renders.count == renderCount)
        // (b) every render pulls exactly 512 frames, in exactly one call
        #expect(run.renders.allSatisfy { $0.pulledFrames == 512 && $0.calls == 1 }, "pulls: \(Set(run.renders.map(\.pulledFrames))), calls: \(Set(run.renders.map(\.calls)))")
        // precondition, not a verdict: the gain must be a usable number
        let g = try #require(measuredGain(run).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }, "G (the control's slope) must be finite and positive")
        let r = try #require(analyze(run, gain: g))
        // (c) the gap series is constant within the tolerance written in the plan: four quantization steps (0.25 source frames at G = 1 while the ramp stays below 2^20 frames)
        #expect(r.gapPeakToPeak <= r.gapTolerance, "gap peak-to-peak \(r.gapPeakToPeak) > tolerance \(r.gapTolerance)")
        // (d) no underrun on either reader
        #expect(run.underrunBlocks == [0, 0], "underruns \(run.underrunBlocks)")
        // (f) nothing was still happening after renderOffline returned
        #expect(run.countersStableAfterEveryRender, "a reader counter moved after renderOffline had returned: the block may run asynchronously")
        // precondition, not a verdict: the ramp stayed exactly representable
        #expect(run.committedFrames < (1 << 24))
        // (g) added after run 1 (tolerance written in the plan addendum before run 2): the DC-derived G and the ramp-derived G of the control agree within 1e-6 relative
        let dc = try #require(try probeGain(spec))
        #expect(abs(dc.gain - g) / g < 1e-6, "DC gain \(dc.gain) vs ramp gain \(g)")
        // (e) determinism: a second identical run gives identical pulls, calls, cursors and output samples
        let again = try runCase(spec)
        #expect(again.renders == run.renders, "two identical runs differ: the harness is not deterministic")
    }
}

// MARK: - the opt-in table (cases 1 to 5, printed, not asserted)

private struct Prediction {
    var pull: Int64
    var h1PPM: Double
    var surplus: Double
    init(_ s: CaseSpec) {
        let num = Int64(s.renderFrames) * Int64(s.sourceRate), den = Int64(s.outputRate)
        pull = (num + den - 1) / den                                          // ceil, exact integer arithmetic
        let ideal = Double(num) / Double(den)
        h1PPM = ((Double(pull) / Double(s.renderFrames)) / (s.sourceRate / s.outputRate) - 1) * 1e6
        surplus = Double(pull) - ideal
    }
}

/// Labels from the plan written before the first run: "near" = within +/- 50 ppm of the hypothesis' ratio deviation AND +/- 0.05 frames per render of its gap slope.
private func label(_ r: ResamplingConsumptionResult, _ p: Prediction) -> String {
    let h1 = abs(r.ratioDeviationPPM - p.h1PPM) <= 50 && abs(r.gapSlopePerRender) <= 0.05
    let h2 = abs(r.ratioDeviationPPM) <= 50 && abs(r.gapSlopePerRender - p.surplus) <= 0.05
    return h1 && h2 ? "H1 = H2 (surplus 0: no discriminating power)" : h1 ? "H1 (consumes all pulled)" : h2 ? "H2 (consumes the ideal ratio, keeps the surplus)" : "H3 (neither)"
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SA_RESAMPLING_TABLE"] == "1", "set SA_RESAMPLING_TABLE=1 to print the Step 6b-2b table"))
struct ResamplingConsumptionTable {
    private func block(_ title: String, _ r: ResamplingConsumptionResult, gain: Double, _ p: Prediction) -> String {
        let distinct = r.distinctPulls.map { "\($0.value) x \($0.count)" }.joined(separator: ", ")
        return """
          [\(title)] G \(String(format: "%.9f", gain)); slope x G \(String(format: "%.9f", r.slopeTimesGain)); measured ratio \(String(format: "%.9f", r.measuredRatio)) vs ideal \(String(format: "%.9f", r.idealRatio)); deviation \(String(format: "%+.2f", r.ratioDeviationPPM)) ppm (H1 would give \(String(format: "%+.1f", p.h1PPM))); R^2 \(String(format: "%.12f", r.rSquared))
            gap: mean \(String(format: "%.3f", r.gapMean)) peak-to-peak \(String(format: "%.3f", r.gapPeakToPeak)) (quantization step \(r.quantizationStep), tolerance \(r.gapTolerance)); slope \(String(format: "%+.5f", r.gapSlopePerRender)) frames/render = \(String(format: "%+.1f", r.gapSlopePPMOfPulled)) ppm of the frames pulled (H2 would give \(String(format: "%+.4f", p.surplus)))
            label: \(label(r, p))   [pull distinct: \(distinct)]
        """
    }

    @Test func printTheFiveCaseTable() throws {
        let specs = [CaseSpec(number: 1, sourceRate: 48_000, outputRate: 48_000, renderFrames: 512), CaseSpec(number: 2, sourceRate: 48_000, outputRate: 44_100, renderFrames: 512),
                     CaseSpec(number: 3, sourceRate: 48_000, outputRate: 44_100, renderFrames: 441), CaseSpec(number: 4, sourceRate: 48_000, outputRate: 44_100, renderFrames: 1024),
                     CaseSpec(number: 5, sourceRate: 48_000, outputRate: 16_000, renderFrames: 512)]
        let control = try runCase(specs[0])
        let gRamp = try #require(measuredGain(control))
        print("STEP 6b-2b TABLE (OFFLINE manual rendering, one Mac, K = \(renderCount) renders, 20 warm-up excluded, node 1 muted); [A] = G measured in case 1 and reused (the plan); [B] = G per case from a constant source (\(probeRenders) renders, constant \(probeConstant))")
        for s in specs {
            let run = s.number == 1 ? control : try runCase(s)
            let p = Prediction(s)
            guard let a = analyze(run, gain: gRamp) else { print("case \(s.number): not analyzable"); continue }
            let dc = try probeGain(s)
            print("""
            case \(s.number): \(Int(s.sourceRate)) -> \(Int(s.outputRate)) Hz, render \(s.renderFrames)
              pull per render: min \(a.pullMin) max \(a.pullMax) mean \(String(format: "%.4f", a.pullMean)) (ideal \(String(format: "%.4f", Double(s.renderFrames) * s.sourceRate / s.outputRate)), predicted pull \(p.pull): \(a.distinctPulls.count == 1 && a.pullMin == p.pull ? "MATCHES" : "DIFFERS")); calls per render min \(a.callsPerRenderMin) max \(a.callsPerRenderMax) mean \(String(format: "%.4f", a.callsPerRenderMean))
              constant-source probe: gain \(dc.map { String(format: "%.9f", $0.gain) } ?? "n/a") (output min \(dc.map { String(format: "%.9f", $0.min) } ?? "-") max \(dc.map { String(format: "%.9f", $0.max) } ?? "-"))
            """)
            print(block("A: G from case 1", a, gain: gRamp, p))
            if let dc, let b = analyze(run, gain: dc.gain) { print(block("B: G per case", b, gain: dc.gain, p)) }
            print("  underruns L/R \(run.underrunBlocks); counters stable after each render: \(run.countersStableAfterEveryRender); frames committed \(run.committedFrames); process threads before engine / after start / after renders: \(run.threads.beforeEngine) / \(run.threads.afterStart) / \(run.threads.afterRenders)")
        }
    }
}

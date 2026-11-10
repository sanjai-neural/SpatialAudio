import CoreAudio
import Foundation
import SpatialAudioCore

/// What the blind listening session needs from a renderer: place the single tone, move the listener, set the master volume, start and stop.
/// `EnvironmentRenderer` is the real one; the tests use a recording fake.
public protocol BlindListeningOutput: SpatialSceneSink {
    var outputVolume: Float { get set }
    var isRunning: Bool { get }
    var notice: String? { get }
    func start() throws
    func stop()
}

extension EnvironmentRenderer: BlindListeningOutput {}

/// Step 3a-2: the blind listening test, live. `BlindRunner` (Core, pure) decides what happens when; this class applies it:
/// scripted head -> `PoseMailbox` -> `ListenerPosePump` -> renderer, the tone's position set only while it is silent, the volume = base x the runner's fade gain.
/// No camera, no tracker, no ring. IMPLEMENTED-UNVERIFIED: the logic is unit-tested with a fake output and virtual time; the real timers and the real
/// `EnvironmentRenderer` have not been listened to.
///
/// Threading: every renderer call here is a CONTROL-thread call (a timer queue, never an audio callback), as the Real-time rule requires. The runner is
/// guarded by one lock; the answer buttons (main thread) and the control timer (its own queue) both go through it.
public final class BlindListeningSession: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var running: Bool
        public var frame: BlindFrame
        public var notice: String?
        /// True once the run is over, the last fade has reached zero and the volume was set to zero: safe to stop the engine without a click.
        public var silentAndFinished: Bool
    }

    public let seed: UInt64
    public let baseVolume: Double
    public let plan: [BlindCondition]
    public let config: BlindRunnerConfig

    private let output: BlindListeningOutput
    private let mailbox = PoseMailbox()
    private let pump: ListenerPosePump
    private let timer = PeriodicTimer(label: "spatialaudio.blind-control")
    private let clock: @Sendable () -> Double
    private let controlPeriod: Double
    private let blockPeriod: Double

    private let lock = NSLock()
    private var runner: BlindRunner
    private var running = false
    private var startTime = 0.0
    private var lastFrame: BlindFrame
    private var lastSource: Vector3?
    private var lastVolume: Float = -1
    private var silentFinished = false
    private var thermalStart = "unknown", lowPowerStart = false
    private var thermalEnd: String?, lowPowerEnd: Bool?
    private var endTime: Double?

    /// `controlRateHz` 100: the fade (0.08 s) is then about eight volume steps, and the head turn is smooth.
    public init(output: BlindListeningOutput, sampleRate: Double, seed: UInt64, baseVolume: Double, config: BlindRunnerConfig = BlindRunnerConfig(),
                controlRateHz: Double = 100, blockFrames: Int = 512, clock: (@Sendable () -> Double)? = nil) {
        self.output = output
        self.seed = seed
        self.baseVolume = min(max(baseVolume, 0), 1)
        self.config = config
        self.plan = BlindTrialPlan.make(seed: seed)
        self.runner = BlindRunner(plan: plan, config: config)
        self.lastFrame = runner.frame
        self.clock = clock ?? MonotonicClock.seconds
        self.controlPeriod = 1 / max(1, controlRateHz)
        self.blockPeriod = Double(max(1, blockFrames)) / max(1, sampleRate)
        // Identity mapping: this test never uses the camera's sign mapping or any flip switch.
        self.pump = ListenerPosePump(mailbox: mailbox, sink: output, mapping: ListenerMapping())
    }

    deinit { stop() }

    // MARK: control

    /// Silent set-up first (volume 0, tone and head in the first trial's scene), then the engine, then the timers.
    public func start() throws {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        begin()
        do { try output.start() } catch {
            lock.lock(); running = false; lock.unlock()
            throw error
        }
        timer.start(period: controlPeriod) { [weak self] in
            guard let self else { return }
            self.controlTick(at: self.clock() - self.startTimeValue())
        }
        pump.start(period: blockPeriod)
    }

    /// Stops the timers and the engine at once (an abrupt cut: use `abort()` and wait for `silentAndFinished` for a clean ending).
    public func stop() {
        lock.lock(); let was = running; running = false; lock.unlock()
        guard was else { return }
        pump.stop()
        timer.stop()
        output.outputVolume = 0
        output.stop()
    }

    /// A button press, timestamped now.
    @discardableResult
    public func answer(_ a: BlindAnswer) -> Bool { answer(a, at: clock() - startTimeValue()) }

    /// Ends the run early (the running trial is not recorded). The tone fades out; wait for `silentAndFinished` before `stop()`.
    public func abort() {
        lock.lock(); runner.abort(at: clock() - startTime); lock.unlock()
    }

    public var snapshot: Snapshot {
        lock.lock(); let f = lastFrame, r = running, s = silentFinished; lock.unlock()
        return Snapshot(running: r && output.isRunning, frame: f, notice: output.notice, silentAndFinished: s)
    }

    /// nil until the run is over.
    public var results: BlindRunResults? { lock.lock(); defer { lock.unlock() }; return runner.results }

    /// The automatically collected run facts (pump timing, thermal state, Low Power Mode). Valid once the run is over; the end values are captured at the
    /// first control tick that sees the run finished.
    public func runFacts() -> BlindRunFacts {
        lock.lock()
        let tEnd = endTime ?? (clock() - startTime)
        let thermal = thermalEnd ?? Self.thermalStateName(), lp = lowPowerEnd ?? ProcessInfo.processInfo.isLowPowerModeEnabled
        let tStart = thermalStart, lpStart = lowPowerStart
        lock.unlock()
        let t = pump.timing
        return BlindRunFacts(pumpTicks: t.ticks, pumpMeanPeriodMilliseconds: t.meanPeriodMilliseconds, pumpMaxPeriodMilliseconds: t.maxPeriodMilliseconds,
                             thermalStateStart: tStart, thermalStateEnd: thermal, lowPowerModeStart: lpStart, lowPowerModeEnd: lp, durationSeconds: tEnd)
    }

    // MARK: the work (internal so the tests can drive it on virtual time)

    func startTimeValue() -> Double { lock.lock(); defer { lock.unlock() }; return startTime }

    /// Sets the first scene while silent. The tests call this instead of `start()`.
    func begin() {
        lock.lock()
        startTime = clock()
        thermalStart = Self.thermalStateName(); lowPowerStart = ProcessInfo.processInfo.isLowPowerModeEnabled
        runner.advance(to: 0)
        let f = runner.frame
        lastFrame = f
        lock.unlock()
        output.outputVolume = 0
        lastVolume = 0
        apply(f)
        pump.step(dt: 0)
    }

    func answer(_ a: BlindAnswer, at t: Double) -> Bool {
        lock.lock(); let ok = runner.answer(a, at: t); lastFrame = runner.frame; lock.unlock()
        return ok
    }

    /// One control tick at script time `t` (seconds since the run began): advance the runner, publish the head pose, move the tone only if it moved
    /// (the runner only moves it while silent), and set the volume to base x gain.
    func controlTick(at t: Double) {
        lock.lock()
        runner.advance(to: t)
        let f = runner.frame
        lastFrame = f
        if f.finished, endTime == nil {
            endTime = t; thermalEnd = Self.thermalStateName(); lowPowerEnd = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        lock.unlock()

        // Order matters for a clean scene change: volume DOWN before anything moves, volume UP after everything moved.
        let target = Float(baseVolume * f.gain)
        if target < lastVolume { output.outputVolume = target; lastVolume = target }
        apply(f, at: t)
        if target > lastVolume { output.outputVolume = target; lastVolume = target }

        if f.finished, f.gain == 0, lastVolume == 0 {
            lock.lock(); silentFinished = true; lock.unlock()
        }
    }

    private func apply(_ f: BlindFrame, at t: Double = 0) {
        mailbox.publish(f.headPose, timestamp: t)
        if lastSource.map({ ($0 - f.sourcePosition).length > 1e-9 }) ?? true {
            output.setSourcePosition(f.sourcePosition)
            lastSource = f.sourcePosition
        }
    }

    // MARK: facts

    static func thermalStateName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// Numbers about the default output device: transport category, nominal rate, buffer size, output channels. No name and no UID are copied from the read.
    public static func readDefaultOutputFacts() -> ListeningDeviceFacts? {
        guard let id = AudioDeviceFactsReader.defaultOutputDevice().id else { return nil }
        let f = AudioDeviceFactsReader.read(device: id, role: "default output device", scope: kAudioObjectPropertyScopeOutput)
        return ListeningDeviceFacts(transportType: f.transportType, transportName: f.transportName, nominalSampleRate: f.nominalSampleRate,
                                    bufferFrameSize: f.bufferFrameSize, outputChannels: f.outputChannels)
    }
}

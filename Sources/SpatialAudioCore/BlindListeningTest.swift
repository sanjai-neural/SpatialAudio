import Foundation

// Step 3a-2: the BLIND listening test. Pure Swift, no audio, no camera, no hardware. IMPLEMENTED-UNVERIFIED until Sanjai has run it.
//
// What "blind" means here: while a trial runs, the only things that leave `BlindRunner` are a head pose, a source position, a gain and "may answer
// now" (`BlindFrame`). The truth of the trial (which ear the tone should be in) is kept inside the runner and comes out only with the finished
// records. Nothing on screen can therefore tell the listener the expected answer, and nothing in the report is typed by hand: the answers are the
// buttons that were pressed.
//
// The truth is NOT typed in either: it is derived from the same geometry the renderer is checked against (`ListenerGeometry`), and pinned by tests
// against hand-derived values (turn the head LEFT with the tone ahead: the tone is at your RIGHT).

// MARK: - Conditions, answers, truth

/// The five trial conditions. Head conditions: the tone stays fixed in the room straight ahead while the scripted head turns 45 degrees and holds.
public enum BlindCondition: String, CaseIterable, Codable, Sendable {
    case staticLeft, staticRight, staticAhead, headLeft45, headRight45

    public var isStatic: Bool { self == .staticLeft || self == .staticRight || self == .staticAhead }
    public var isHeadHold: Bool { !isStatic }
}

/// What a correct renderer puts the tone at, as an ear. Derived from geometry, never typed.
public enum BlindTruth: String, CaseIterable, Codable, Sendable {
    case leftEar, rightEar, middle
}

/// The four buttons plus the recorded absence of an answer.
public enum BlindAnswer: String, CaseIterable, Codable, Sendable {
    case leftEar, rightEar, middle, cantTell, notAnswered

    /// The buttons the card offers (`notAnswered` is only ever recorded, by a timeout).
    public static let buttons: [BlindAnswer] = [.leftEar, .rightEar, .middle, .cantTell]

    /// A position answer ("definite"): left ear, right ear or middle. "Can't tell" and "not answered" are abstentions.
    public var isDefinite: Bool { self == .leftEar || self == .rightEar || self == .middle }

    public func matches(_ truth: BlindTruth) -> Bool {
        switch (self, truth) {
        case (.leftEar, .leftEar), (.rightEar, .rightEar), (.middle, .middle): true
        default: false
        }
    }

    /// Position of this answer in a confusion row.
    public var columnIndex: Int { Self.allCases.firstIndex(of: self)! }
}

// MARK: - Scenes (the geometry)

public struct BlindScene: Equatable, Sendable {
    public var headPose: Quaternion
    public var sourcePosition: Vector3
}

public enum BlindScenes {
    public static let sourceDistance = ListeningTest.sourceDistance
    /// The static LEFT / RIGHT tone sits hard to one side (audio-standard azimuth, positive = right).
    public static let staticSideAzimuthDegrees = 90.0
    public static let headTurnDegrees = ListeningTest.yawHoldDegrees
    /// Relative azimuths within +-this count as "middle". UNTUNED (a choice, not a measurement); only the static-ahead (0 degrees) and +-45 / +-90
    /// degree scenes are used, so any value between 1 and 44 gives the same truths.
    public static let middleThresholdDegrees = 15.0

    /// `headProgress` 0...1: how far the head has turned toward its final pose (smoothstep). Static conditions ignore it.
    public static func scene(for condition: BlindCondition, headProgress: Double) -> BlindScene {
        let p = min(max(headProgress.isFinite ? headProgress : 0, 0), 1)
        let eased = p * p * (3 - 2 * p)
        var yaw = 0.0, azimuth = 0.0
        switch condition {
        case .staticLeft: azimuth = -staticSideAzimuthDegrees
        case .staticRight: azimuth = staticSideAzimuthDegrees
        case .staticAhead: break
        case .headLeft45: yaw = headTurnDegrees * eased       // yaw + = turn LEFT (project convention)
        case .headRight45: yaw = -headTurnDegrees * eased
        }
        return BlindScene(headPose: Quaternion(euler: EulerAngles(yawDegrees: yaw, pitchDegrees: 0, rollDegrees: 0)),
                          sourcePosition: Vector3.direction(azimuthDegrees: azimuth, elevationDegrees: 0, distance: sourceDistance))
    }

    /// Which ear the tone is in once the head has finished turning, from geometry.
    public static func truth(for condition: BlindCondition) -> BlindTruth {
        let s = scene(for: condition, headProgress: 1)
        let az = ListenerGeometry.relativeDirection(of: s.sourcePosition, listenerPose: s.headPose).azimuthDegrees
        if az < -middleThresholdDegrees { return .leftEar }
        if az > middleThresholdDegrees { return .rightEar }
        return .middle
    }
}

// MARK: - Seeded plan

/// SplitMix64 (Steele, Lea, Flood 2014). Fixed algorithm so that a recorded seed reproduces the trial order on any machine; Swift's
/// SystemRandomNumberGenerator is deliberately not used. Known outputs are pinned in the tests, computed independently in Python.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    public var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public enum BlindTrialPlan {
    public static let repetitions = 4
    /// No condition may appear this many times in a row (3 = no run of three).
    public static let maxRunLength = 2

    /// Seeded Fisher-Yates over every condition x `repetitions`, redrawn from the same generator until no condition appears three times in a row.
    /// `next() % (i + 1)` has a bias of at most 2^-59: irrelevant here, and the Python oracle in the tests uses the same formula.
    public static func make(seed: UInt64, repetitions: Int = BlindTrialPlan.repetitions) -> [BlindCondition] {
        var base: [BlindCondition] = []
        for c in BlindCondition.allCases { base += Array(repeating: c, count: repetitions) }
        guard base.count > 1 else { return base }
        var rng = SplitMix64(seed: seed)
        for _ in 0..<10_000 {
            var order = base
            for i in stride(from: order.count - 1, to: 0, by: -1) {
                let j = Int(rng.next() % UInt64(i + 1))
                order.swapAt(i, j)
            }
            if longestRun(order) <= maxRunLength { return order }
        }
        // Practically unreachable (the chance of 10 000 consecutive rejections is nil); kept so the function always returns a valid plan.
        var fallback: [BlindCondition] = []
        for _ in 0..<repetitions { fallback += BlindCondition.allCases }
        return fallback
    }

    public static func longestRun(_ order: [BlindCondition]) -> Int {
        var best = 0, run = 0
        var previous: BlindCondition?
        for c in order {
            run = (c == previous) ? run + 1 : 1
            previous = c
            best = max(best, run)
        }
        return best
    }
}

// MARK: - Records

public struct BlindTrialRecord: Codable, Equatable, Sendable {
    /// 1-based position in the played order.
    public var number: Int
    public var condition: BlindCondition
    public var truth: BlindTruth
    public var answer: BlindAnswer
    /// Seconds from the tone's onset to the button press; nil when not answered.
    public var reactionSeconds: Double?

    public init(number: Int, condition: BlindCondition, truth: BlindTruth, answer: BlindAnswer, reactionSeconds: Double?) {
        self.number = number; self.condition = condition; self.truth = truth; self.answer = answer; self.reactionSeconds = reactionSeconds
    }
}

// MARK: - Runner (pure state machine on a caller-supplied clock)

public struct BlindRunnerConfig: Codable, Equatable, Sendable {
    /// Silence before the first tone (the first scene is set up while silent).
    public var firstGapSeconds = 2.0
    /// Silence between trials, from the answer (or timeout) to the next onset.
    public var gapSeconds = 1.5
    /// Linear fade in at the onset and out at the answer. The tone is faded out before the scene changes, so a position jump is never audible.
    public var fadeSeconds = 0.08
    /// The scene (source and head) changes this long after the gap began: after the fade-out, while silent.
    public var sceneSwitchSeconds = 0.4
    /// Head conditions: the head turns over this long from the onset (smoothstep) and then holds.
    public var headEaseSeconds = 1.0
    /// The buttons only work from this long after the onset (after the head has settled), the same for every condition so that timing leaks nothing.
    public var answerEnableSeconds = 1.2
    /// A trial with no answer after this long is recorded as "not answered".
    public var timeoutSeconds = 12.0

    public init() {}
}

/// Everything the outside may see while a trial runs. There is deliberately no truth / expected / condition field: `Mirror`-checked in the tests.
public struct BlindFrame: Equatable, Sendable {
    public var headPose: Quaternion
    public var sourcePosition: Vector3
    /// 0...1, multiplies the output volume (the fades).
    public var gain: Double
    public var answerEnabled: Bool
    public var completedTrials: Int
    public var totalTrials: Int
    /// A tone is meant to be playing (a trial is open).
    public var inTrial: Bool
    public var finished: Bool
}

public struct BlindRunResults: Equatable, Sendable {
    public var records: [BlindTrialRecord]
    /// False when stopped early; `records` then holds only the finished trials.
    public var completed: Bool
    public var plannedTrials: Int
}

public struct BlindRunner: Sendable {
    public let plan: [BlindCondition]
    public let config: BlindRunnerConfig

    private enum Phase: Sendable {
        case gap(start: Double, end: Double, audibleBefore: Bool)
        case stimulus(onset: Double)
        case finished(at: Double, lastScene: BlindScene, audible: Bool)
    }

    private var phase: Phase
    private var index = 0
    private var now = 0.0
    private var records: [BlindTrialRecord] = []
    private var aborted = false

    public init(plan: [BlindCondition], config: BlindRunnerConfig = BlindRunnerConfig()) {
        self.plan = plan; self.config = config
        if plan.isEmpty {
            phase = .finished(at: 0, lastScene: BlindScenes.scene(for: .staticAhead, headProgress: 0), audible: false)
        } else {
            phase = .gap(start: 0, end: config.firstGapSeconds, audibleBefore: false)
        }
    }

    public var isFinished: Bool { if case .finished = phase { true } else { false } }

    /// nil until the run is over (finished or aborted): nothing about the truth or the answers can be read out earlier.
    public var results: BlindRunResults? {
        guard isFinished else { return nil }
        return BlindRunResults(records: records, completed: !aborted, plannedTrials: plan.count)
    }

    /// Moves the clock forward (never back) and processes every boundary passed.
    public mutating func advance(to t: Double) {
        guard t.isFinite else { return }
        now = max(now, t)
        while true {
            switch phase {
            case .gap(_, let end, _):
                guard now >= end else { return }
                phase = .stimulus(onset: end)
            case .stimulus(let onset):
                let deadline = onset + config.timeoutSeconds
                guard now >= deadline else { return }
                closeTrial(answer: .notAnswered, reaction: nil, at: deadline)
            case .finished:
                return
            }
        }
    }

    /// Records a button press. False (nothing recorded) unless a trial is open, its answer window is open, and the answer is one of the four buttons.
    @discardableResult
    public mutating func answer(_ answer: BlindAnswer, at t: Double) -> Bool {
        advance(to: t)
        guard answer != .notAnswered, case .stimulus(let onset) = phase, now >= onset + config.answerEnableSeconds else { return false }
        closeTrial(answer: answer, reaction: now - onset, at: now)
        return true
    }

    /// Ends the run early. The running trial is not recorded.
    public mutating func abort(at t: Double) {
        advance(to: t)
        guard !isFinished else { return }
        let f = frame
        phase = .finished(at: now, lastScene: BlindScene(headPose: f.headPose, sourcePosition: f.sourcePosition), audible: f.inTrial || f.gain > 0)
        aborted = true
    }

    private mutating func closeTrial(answer: BlindAnswer, reaction: Double?, at time: Double) {
        let c = plan[index]
        records.append(BlindTrialRecord(number: index + 1, condition: c, truth: BlindScenes.truth(for: c), answer: answer, reactionSeconds: reaction))
        index += 1
        if index >= plan.count {
            phase = .finished(at: time, lastScene: BlindScenes.scene(for: c, headProgress: 1), audible: true)
        } else {
            phase = .gap(start: time, end: time + config.gapSeconds, audibleBefore: true)
        }
    }

    /// The state at the last time given to `advance` / `answer`.
    public var frame: BlindFrame {
        var scene: BlindScene
        var gain = 0.0
        var enabled = false
        var inTrial = false
        let fade = max(config.fadeSeconds, 1e-9)
        switch phase {
        case .gap(let start, _, let audible):
            let since = now - start
            if audible, since < config.sceneSwitchSeconds, index > 0 {
                scene = BlindScenes.scene(for: plan[index - 1], headProgress: 1)
                gain = max(0, 1 - since / fade)
            } else {
                scene = BlindScenes.scene(for: plan[index], headProgress: 0)
            }
        case .stimulus(let onset):
            let since = now - onset
            scene = BlindScenes.scene(for: plan[index], headProgress: since / max(config.headEaseSeconds, 1e-9))
            gain = min(1, since / fade)
            enabled = since >= config.answerEnableSeconds
            inTrial = true
        case .finished(let at, let last, let audible):
            scene = last
            gain = audible ? max(0, 1 - (now - at) / fade) : 0
        }
        return BlindFrame(headPose: scene.headPose, sourcePosition: scene.sourcePosition, gain: gain, answerEnabled: enabled,
                          completedTrials: records.count, totalTrials: plan.count, inTrial: inTrial, finished: isFinished)
    }
}

// MARK: - Scoring

public enum BlindFlagStatus: String, Codable, Sendable {
    case suspected, notSuspected, notAssessable
}

/// "Definite" answers counted for a flag, and how many of them put the tone in the ear OPPOSITE to the truth.
public struct BlindFlag: Codable, Equatable, Sendable {
    public var status: BlindFlagStatus
    public var definiteAnswers: Int
    public var oppositeEarAnswers: Int
}

public struct BlindConditionScore: Codable, Equatable, Sendable {
    public var condition: BlindCondition
    public var trials: Int
    public var definite: Int
    public var correct: Int
}

public struct BlindScore: Codable, Equatable, Sendable {
    public var trials: Int
    public var answeredDefinite: Int
    public var correct: Int
    /// correct / definite answers; nil when there were none. "Can't tell" and "not answered" are neither right nor wrong here.
    public var accuracyOfDefinite: Double?
    /// P(at least `correct` right out of `answeredDefinite`) under uniform guessing among the three position buttons (chance 1/3 each). nil with no definite answers.
    public var chanceUpperTail: Double?
    public var perCondition: [BlindConditionScore]
    /// confusion[row][column]: rows are the conditions in `BlindCondition.allCases` order, columns the answers in `BlindAnswer.allCases` order
    /// (left ear, right ear, middle, can't tell, not answered).
    public var confusion: [[Int]]
    /// Static LEFT / RIGHT trials only: are the two ears swapped (or is a channel dead / mirrored)?
    public var channelSwap: BlindFlag
    /// Head-hold trials, assessed only if the static trials were mostly right: does the tone move the wrong way when the head turns?
    public var headTurnReversed: BlindFlag
}

public enum BlindScoring {
    /// Both flags need at least this many definite answers ...
    public static let flagMinimumDefinite = 6
    /// ... and at least this fraction of them in the wrong (opposite) ear. UNTUNED: chosen before any data exists. With 8 static LEFT / RIGHT trials
    /// a listener guessing among the three buttons reaches 6 of 6 opposite only by luck, but the flag is a hint for a human, not a verdict.
    public static let flagMinimumOppositeFraction = 0.75
    /// For the head-turn flag the static trials must show the ears are the right way round: this fraction of their definite answers correct.
    public static let staticMostlyRightFraction = 0.75
    public static let chanceProbability = 1.0 / 3.0

    public static func score(_ records: [BlindTrialRecord]) -> BlindScore {
        let conditions = BlindCondition.allCases
        var confusion = Array(repeating: Array(repeating: 0, count: BlindAnswer.allCases.count), count: conditions.count)
        var perCondition = conditions.map { BlindConditionScore(condition: $0, trials: 0, definite: 0, correct: 0) }
        for r in records {
            let row = conditions.firstIndex(of: r.condition)!
            confusion[row][r.answer.columnIndex] += 1
            perCondition[row].trials += 1
            if r.answer.isDefinite {
                perCondition[row].definite += 1
                if r.answer.matches(r.truth) { perCondition[row].correct += 1 }
            }
        }
        let definite = perCondition.reduce(0) { $0 + $1.definite }
        let correct = perCondition.reduce(0) { $0 + $1.correct }

        let staticSides = records.filter { $0.condition == .staticLeft || $0.condition == .staticRight }
        let heads = records.filter { $0.condition.isHeadHold }
        let swap = flag(for: staticSides, requiringStaticMostlyRight: nil)
        let staticOK = mostlyRight(staticSides)
        let head = flag(for: heads, requiringStaticMostlyRight: staticOK)

        return BlindScore(trials: records.count, answeredDefinite: definite, correct: correct,
                          accuracyOfDefinite: definite > 0 ? Double(correct) / Double(definite) : nil,
                          chanceUpperTail: definite > 0 ? binomialUpperTail(n: definite, k: correct, p: chanceProbability) : nil,
                          perCondition: perCondition, confusion: confusion, channelSwap: swap, headTurnReversed: head)
    }

    /// The tone is in the ear opposite to the truth: the answer is an ear, the truth is an ear, and they differ.
    static func isOppositeEar(_ r: BlindTrialRecord) -> Bool {
        (r.answer == .leftEar && r.truth == .rightEar) || (r.answer == .rightEar && r.truth == .leftEar)
    }

    private static func mostlyRight(_ rs: [BlindTrialRecord]) -> Bool? {
        let d = rs.filter { $0.answer.isDefinite }
        guard d.count >= flagMinimumDefinite else { return nil }
        let right = d.filter { $0.answer.matches($0.truth) }.count
        return Double(right) / Double(d.count) >= staticMostlyRightFraction
    }

    /// `requiringStaticMostlyRight`: nil = no precondition (the channel-swap flag); true / false / (no verdict) for the head-turn flag.
    private static func flag(for rs: [BlindTrialRecord], requiringStaticMostlyRight pre: Bool?) -> BlindFlag {
        let d = rs.filter { $0.answer.isDefinite }
        let opposite = d.filter(isOppositeEar).count
        let isHead = rs.contains { $0.condition.isHeadHold }
        var status: BlindFlagStatus
        if d.count < flagMinimumDefinite {
            status = .notAssessable
        } else if isHead && !(pre ?? false) {
            // Head-turn flag: unassessable unless the static trials were definite enough AND mostly right (otherwise the ears may simply be swapped).
            status = .notAssessable
        } else {
            status = Double(opposite) / Double(d.count) >= flagMinimumOppositeFraction ? .suspected : .notSuspected
        }
        return BlindFlag(status: status, definiteAnswers: d.count, oppositeEarAnswers: opposite)
    }

    /// Exact binomial upper tail P(X >= k), X ~ Binomial(n, p).
    public static func binomialUpperTail(n: Int, k: Int, p: Double) -> Double {
        guard n >= 0 else { return 1 }
        if k <= 0 { return 1 }
        if k > n { return 0 }
        var total = 0.0
        for i in k...n {
            // C(n, i) p^i (1-p)^(n-i), by lgamma to stay finite for any n
            let logC = lgamma(Double(n + 1)) - lgamma(Double(i + 1)) - lgamma(Double(n - i + 1))
            total += exp(logC + Double(i) * log(p) + Double(n - i) * log(1 - p))
        }
        return min(1, total)
    }
}

// MARK: - End-of-test answers

public enum BlindYesNo: String, CaseIterable, Codable, Sendable { case yes, no, notAnswered }
public enum BlindHeadLocation: String, CaseIterable, Codable, Sendable { case inside, outside, notAnswered }
public enum BlindAirPodsState: String, CaseIterable, Codable, Sendable { case off, on, notUsed, notAnswered }

public struct BlindEndAnswers: Codable, Equatable, Sendable {
    /// Clicks or crackling heard during the test.
    public var clicksOrCrackling: BlindYesNo
    /// Where the tone seemed to be: inside the head or outside it.
    public var soundLocation: BlindHeadLocation
    /// Were AirPods' own Spatial Audio / head tracking on during the test? (They should be off or unused: the app must not depend on them.)
    public var airPodsSpatialAudio: BlindAirPodsState

    public init(clicksOrCrackling: BlindYesNo = .notAnswered, soundLocation: BlindHeadLocation = .notAnswered, airPodsSpatialAudio: BlindAirPodsState = .notAnswered) {
        self.clicksOrCrackling = clicksOrCrackling; self.soundLocation = soundLocation; self.airPodsSpatialAudio = airPodsSpatialAudio
    }
}

// MARK: - Facts collected automatically

/// Numbers about the default output device: no name, no UID. The transport name is a category from a fixed table ("...Bluetooth"), not a product name.
public struct ListeningDeviceFacts: Codable, Equatable, Sendable {
    public var transportType: String?
    public var transportName: String?
    public var nominalSampleRate: Double?
    public var bufferFrameSize: UInt32?
    public var outputChannels: Int?

    public init(transportType: String? = nil, transportName: String? = nil, nominalSampleRate: Double? = nil, bufferFrameSize: UInt32? = nil, outputChannels: Int? = nil) {
        self.transportType = transportType; self.transportName = transportName; self.nominalSampleRate = nominalSampleRate
        self.bufferFrameSize = bufferFrameSize; self.outputChannels = outputChannels
    }
}

public struct BlindRunFacts: Codable, Equatable, Sendable {
    public var pumpTicks: Int
    public var pumpMeanPeriodMilliseconds: Double
    public var pumpMaxPeriodMilliseconds: Double
    /// `ProcessInfo.thermalState` at the start and at the end: "nominal", "fair", "serious", "critical" (or "unknown").
    public var thermalStateStart: String
    public var thermalStateEnd: String
    /// `ProcessInfo.isLowPowerModeEnabled` at the start and at the end.
    public var lowPowerModeStart: Bool
    public var lowPowerModeEnd: Bool
    /// Seconds from the start of the run to its end, on the monotonic clock (which does not count sleep).
    public var durationSeconds: Double

    public init(pumpTicks: Int, pumpMeanPeriodMilliseconds: Double, pumpMaxPeriodMilliseconds: Double, thermalStateStart: String, thermalStateEnd: String,
                lowPowerModeStart: Bool, lowPowerModeEnd: Bool, durationSeconds: Double) {
        self.pumpTicks = pumpTicks; self.pumpMeanPeriodMilliseconds = pumpMeanPeriodMilliseconds; self.pumpMaxPeriodMilliseconds = pumpMaxPeriodMilliseconds
        self.thermalStateStart = thermalStateStart; self.thermalStateEnd = thermalStateEnd
        self.lowPowerModeStart = lowPowerModeStart; self.lowPowerModeEnd = lowPowerModeEnd; self.durationSeconds = durationSeconds
    }
}

/// The settings the report states about itself, so that a reader knows what was untuned.
public struct BlindParameters: Codable, Equatable, Sendable {
    public var repetitionsPerCondition: Int
    public var runner: BlindRunnerConfig
    public var sourceDistanceMeters: Double
    public var staticSideAzimuthDegrees: Double
    public var headTurnDegrees: Double
    public var middleThresholdDegrees: Double
    public var flagMinimumDefinite: Int
    public var flagMinimumOppositeFraction: Double
    public var staticMostlyRightFraction: Double
    /// Output volume the listener used (0...1, before the fades).
    public var outputVolume: Double

    public static func current(runner: BlindRunnerConfig, outputVolume: Double) -> BlindParameters {
        BlindParameters(repetitionsPerCondition: BlindTrialPlan.repetitions, runner: runner, sourceDistanceMeters: BlindScenes.sourceDistance,
                        staticSideAzimuthDegrees: BlindScenes.staticSideAzimuthDegrees, headTurnDegrees: BlindScenes.headTurnDegrees,
                        middleThresholdDegrees: BlindScenes.middleThresholdDegrees, flagMinimumDefinite: BlindScoring.flagMinimumDefinite,
                        flagMinimumOppositeFraction: BlindScoring.flagMinimumOppositeFraction, staticMostlyRightFraction: BlindScoring.staticMostlyRightFraction,
                        outputVolume: outputVolume)
    }
}

// MARK: - Report

public struct BlindListeningReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var kind: String
    /// True: the answers came from `SimulatedBlindListener`. FABRICATED data; never decides anything.
    public var simulated: Bool
    public var simulatedListener: String?
    public var startedAt: String
    public var endedAt: String
    public var seed: UInt64
    public var completed: Bool
    public var plannedTrials: Int
    public var parameters: BlindParameters
    public var trials: [BlindTrialRecord]
    public var score: BlindScore
    public var endAnswers: BlindEndAnswers
    public var device: ListeningDeviceFacts?
    public var run: BlindRunFacts?

    /// Builds a report; the score is always computed from `results.records`, never passed in.
    public static func make(seed: UInt64, results: BlindRunResults, parameters: BlindParameters, endAnswers: BlindEndAnswers, device: ListeningDeviceFacts?,
                            run: BlindRunFacts?, startedAt: String, endedAt: String, simulatedListener: String? = nil) -> BlindListeningReport {
        BlindListeningReport(schemaVersion: currentSchemaVersion, kind: "blind-listening-test", simulated: simulatedListener != nil, simulatedListener: simulatedListener,
                             startedAt: startedAt, endedAt: endedAt, seed: seed, completed: results.completed, plannedTrials: results.plannedTrials,
                             parameters: parameters, trials: results.records, score: BlindScoring.score(results.records), endAnswers: endAnswers,
                             device: device, run: run)
    }

    public func jsonData() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(json: Data) throws -> BlindListeningReport { try JSONDecoder().decode(BlindListeningReport.self, from: json) }

    /// listening-20261110-093000 (SIMULATED runs get a -SIMULATED suffix, which .gitignore keeps out of the repository).
    public static func fileStem(date: Date, timeZone: TimeZone = .current, simulated: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "listening-" + f.string(from: date) + (simulated ? "-SIMULATED" : "")
    }

    // MARK: Markdown

    private static func answerLabel(_ a: BlindAnswer) -> String {
        switch a { case .leftEar: "left ear"; case .rightEar: "right ear"; case .middle: "middle"; case .cantTell: "can't tell"; case .notAnswered: "not answered" }
    }
    private static func truthLabel(_ t: BlindTruth) -> String {
        switch t { case .leftEar: "left ear"; case .rightEar: "right ear"; case .middle: "middle" }
    }
    private static func conditionLabel(_ c: BlindCondition) -> String {
        switch c {
        case .staticLeft: "static LEFT"; case .staticRight: "static RIGHT"; case .staticAhead: "static AHEAD"
        case .headLeft45: "head 45° LEFT, tone fixed ahead"; case .headRight45: "head 45° RIGHT, tone fixed ahead"
        }
    }
    private static func flagLine(_ f: BlindFlag, assessable: String) -> String {
        switch f.status {
        case .suspected: "SUSPECTED (\(f.oppositeEarAnswers) of \(f.definiteAnswers) definite answers in the opposite ear)"
        case .notSuspected: "not suspected (\(f.oppositeEarAnswers) of \(f.definiteAnswers) definite answers in the opposite ear)"
        case .notAssessable: "not assessable (\(f.definiteAnswers) definite answers; \(assessable))"
        }
    }
    private static func pct(_ x: Double?) -> String { x.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a" }

    public func markdown() -> String {
        var s: [String] = []
        s.append("# Blind listening test (Step 3a-2)")
        s.append("")
        if simulated {
            s.append("**SIMULATED LISTENER (\(simulatedListener ?? "unknown")). FABRICATED answers: rehearsal of the flow only. Nothing here says anything about this Mac, these headphones or any ears.**")
            s.append("")
        }
        s.append("Status: IMPLEMENTED-UNVERIFIED (the test has not been run by a person until a real report exists). Numbers only: no device name, no UID, no path.")
        s.append("")
        s.append("- Schema version \(schemaVersion); started \(startedAt); ended \(endedAt)")
        s.append("- Seed \(seed) (reproduces the trial order); output volume \(String(format: "%.2f", parameters.outputVolume))")
        s.append("- Completed: \(completed ? "yes" : "NO, stopped early") — \(trials.count) of \(plannedTrials) trials recorded")
        s.append("")
        s.append("## Result")
        s.append("")
        s.append("- Definite answers (left ear / right ear / middle): \(score.answeredDefinite) of \(score.trials) trials; correct: \(score.correct); accuracy of the definite answers: \(Self.pct(score.accuracyOfDefinite))")
        if let p = score.chanceUpperTail { s.append("- Chance: 1 in 3 per definite answer, assuming uniform guessing among the three position buttons (\"can't tell\" is an abstention, not a guess). Probability of at least this many correct by guessing alone: \(String(format: "%.4f", p)). The trial mix is not uniform (see the table), so this is a rough guide, not a test.") }
        else { s.append("- Chance: 1 in 3 per definite answer; no definite answers were given.") }
        s.append("- Channel-swap flag (static LEFT / RIGHT trials only): \(Self.flagLine(score.channelSwap, assessable: "needs at least \(parameters.flagMinimumDefinite)"))")
        s.append("- Head-turn-reversed flag (head-hold trials, only if the static answers are mostly right): \(Self.flagLine(score.headTurnReversed, assessable: "needs at least \(parameters.flagMinimumDefinite) definite head-hold answers and static answers at least \(Int(parameters.staticMostlyRightFraction * 100))% right"))")
        s.append("- Both flags are UNTUNED hints: at least \(parameters.flagMinimumDefinite) definite answers and at least \(Int(parameters.flagMinimumOppositeFraction * 100))% of them in the opposite ear. The numbers were chosen before any data existed.")
        s.append("")
        s.append("### Per condition, with the expected position (shown here only, after the test)")
        s.append("")
        s.append("| Condition | Truth | Trials | Left ear | Right ear | Middle | Can't tell | Not answered | Correct of definite |")
        s.append("|---|---|---|---|---|---|---|---|---|")
        for (i, c) in BlindCondition.allCases.enumerated() {
            let row = score.confusion[i]
            let pc = score.perCondition[i]
            s.append("| \(Self.conditionLabel(c)) | \(Self.truthLabel(BlindScenes.truth(for: c))) | \(pc.trials) | \(row[0]) | \(row[1]) | \(row[2]) | \(row[3]) | \(row[4]) | \(pc.correct) of \(pc.definite) |")
        }
        s.append("")
        s.append("## End-of-test answers")
        s.append("")
        s.append("- Clicks or crackling heard: \(endAnswers.clicksOrCrackling.rawValue == "notAnswered" ? "not answered" : endAnswers.clicksOrCrackling.rawValue). (The tone is faded in and out in steps of the control timer; any such fade noise is part of this answer.)")
        s.append("- Sound location: \(endAnswers.soundLocation == .notAnswered ? "not answered" : endAnswers.soundLocation.rawValue + " the head")")
        s.append("- AirPods Spatial Audio: \(endAnswers.airPodsSpatialAudio == .notAnswered ? "not answered" : endAnswers.airPodsSpatialAudio == .notUsed ? "AirPods not used" : endAnswers.airPodsSpatialAudio.rawValue)")
        s.append("")
        s.append("## Automatically collected")
        s.append("")
        if let d = device {
            s.append("- Output device: transport \(d.transportType ?? "unreadable") (\(d.transportName ?? "unreadable")), nominal rate \(d.nominalSampleRate.map { String(format: "%.1f Hz", $0) } ?? "unreadable"), buffer \(d.bufferFrameSize.map(String.init) ?? "unreadable") frames, \(d.outputChannels.map(String.init) ?? "unreadable") output channels")
        } else { s.append("- Output device: not read") }
        if let r = run {
            s.append("- Pose pump: \(r.pumpTicks) ticks, mean period \(String(format: "%.2f", r.pumpMeanPeriodMilliseconds)) ms, longest \(String(format: "%.2f", r.pumpMaxPeriodMilliseconds)) ms (diagnostic only)")
            s.append("- Thermal state: \(r.thermalStateStart) at the start, \(r.thermalStateEnd) at the end; Low Power Mode: \(r.lowPowerModeStart ? "on" : "off") at the start, \(r.lowPowerModeEnd ? "on" : "off") at the end")
            s.append("- Run length (monotonic clock, sleep not counted): \(String(format: "%.1f", r.durationSeconds)) s")
        } else { s.append("- Run facts: none") }
        s.append("")
        s.append("## Trials, in the order played (truth shown here only, after the test)")
        s.append("")
        s.append("| # | Condition | Truth | Answer | Reaction (s) |")
        s.append("|---|---|---|---|---|")
        for t in trials {
            s.append("| \(t.number) | \(Self.conditionLabel(t.condition)) | \(Self.truthLabel(t.truth)) | \(Self.answerLabel(t.answer)) | \(t.reactionSeconds.map { String(format: "%.2f", $0) } ?? "–") |")
        }
        s.append("")
        s.append("## Settings this report was produced with")
        s.append("")
        s.append("- \(parameters.repetitionsPerCondition) trials per condition, no condition three times in a row; tone \(String(format: "%.1f", parameters.sourceDistanceMeters)) m away, static sides at ±\(Int(parameters.staticSideAzimuthDegrees))°, head turns ±\(Int(parameters.headTurnDegrees))° (turn over \(parameters.runner.headEaseSeconds) s, then hold)")
        s.append("- Answer buttons enabled \(parameters.runner.answerEnableSeconds) s after the tone starts; a trial with no answer after \(parameters.runner.timeoutSeconds) s is \"not answered\"; silence \(parameters.runner.gapSeconds) s between trials; fades \(parameters.runner.fadeSeconds) s")
        s.append("- \"Middle\" truth = relative azimuth within ±\(Int(parameters.middleThresholdDegrees))° (untuned; the scenes used give the same truths for any value from 1° to 44°)")
        s.append("- Not recorded by design: headphone make or model (write it next to the file yourself if you want it), camera data (none is used), device names or UIDs.")
        s.append("")
        return s.joined(separator: "\n")
    }
}

// MARK: - Simulated listener (FABRICATED answers)

/// A made-up listener for rehearsing the flow and feeding unit tests. Its reports are marked SIMULATED, never committed, and never decide anything.
public struct SimulatedBlindListener: Sendable {
    public enum Behavior: Equatable, Sendable {
        case perfect
        /// Every ear answer is mirrored (left <-> right), middle stays.
        case swappedChannels
        /// Ears are right for the static trials; the head-hold trials are mirrored.
        case reversedHeadTurn
        /// Uniform among left ear / right ear / middle, from a seeded generator.
        case guessing(seed: UInt64)
        /// Always "can't tell".
        case abstain
        /// Never answers (every trial times out).
        case silent
    }

    public var behavior: Behavior
    /// Seconds after the answer window opens.
    public var reactionSeconds = 1.0
    private var rng: SplitMix64

    public init(_ behavior: Behavior) {
        self.behavior = behavior
        if case .guessing(let seed) = behavior { rng = SplitMix64(seed: seed) } else { rng = SplitMix64(seed: 0) }
    }

    public var name: String {
        switch behavior {
        case .perfect: "perfect"; case .swappedChannels: "swapped-channels"; case .reversedHeadTurn: "reversed-head-turn"
        case .guessing(let s): "guessing(seed \(s))"; case .abstain: "abstain"; case .silent: "silent"
        }
    }

    private static func mirrored(_ t: BlindTruth) -> BlindAnswer {
        switch t { case .leftEar: .rightEar; case .rightEar: .leftEar; case .middle: .middle }
    }
    private static func exact(_ t: BlindTruth) -> BlindAnswer {
        switch t { case .leftEar: .leftEar; case .rightEar: .rightEar; case .middle: .middle }
    }

    /// nil = never answers.
    public mutating func answer(for condition: BlindCondition) -> BlindAnswer? {
        let truth = BlindScenes.truth(for: condition)
        switch behavior {
        case .perfect: return Self.exact(truth)
        case .swappedChannels: return Self.mirrored(truth)
        case .reversedHeadTurn: return condition.isHeadHold ? Self.mirrored(truth) : Self.exact(truth)
        case .guessing: return [BlindAnswer.leftEar, .rightEar, .middle][Int(rng.next() % 3)]
        case .abstain: return .cantTell
        case .silent: return nil
        }
    }
}

public enum BlindSimulation {
    /// Plays a whole run on virtual time (no sleeping, no audio): the listener answers `reactionSeconds` after the answer window opens.
    public static func run(seed: UInt64, listener: SimulatedBlindListener, config: BlindRunnerConfig = BlindRunnerConfig(), step: Double = 1.0 / 30) -> BlindRunResults {
        var l = listener
        var runner = BlindRunner(plan: BlindTrialPlan.make(seed: seed), config: config)
        var t = 0.0
        var enabledSince: Double?
        var pendingAnswer: BlindAnswer?    // what the listener will press for the open trial (nil = never)
        var decidedFor = -1
        let limit = Double(runner.plan.count) * (config.timeoutSeconds + config.gapSeconds + 2) + config.firstGapSeconds + 10
        while !runner.isFinished, t < limit {
            runner.advance(to: t)
            let f = runner.frame
            if f.inTrial, f.completedTrials != decidedFor {
                decidedFor = f.completedTrials
                pendingAnswer = l.answer(for: runner.plan[f.completedTrials])
                enabledSince = nil
            }
            if f.inTrial, f.answerEnabled {
                if enabledSince == nil { enabledSince = t }
                if let a = pendingAnswer, let since = enabledSince, t - since >= l.reactionSeconds { runner.answer(a, at: t) }
            }
            t += step
        }
        return runner.results ?? BlindRunResults(records: [], completed: false, plannedTrials: runner.plan.count)
    }
}

import Foundation

/// Rectangle in normalized image coordinates (0...1 of frame width/height). Only symmetric
/// quantities (size, centre distance, margin to the frame edge) are used, so the y-axis origin
/// convention does not matter.
public struct NormalizedRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var area: Double { width * height }
    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
    /// Larger side; the length unit used to normalize bounding-box movement.
    public var size: Double { max(width, height) }
    /// Smallest distance from the rectangle to any frame edge (negative if it sticks out).
    public var edgeMargin: Double { min(x, y, 1 - (x + width), 1 - (y + height)) }
}

/// One face as reported by the detector for a single frame.
public struct FaceMeasurement: Equatable, Sendable {
    public var angles: VisionFaceAngles
    /// `VNObservation.confidence`. Apple documents it may always be 1.0 when unsupported; seen
    /// at 0.87–0.89 in one manual session. Treated as one weak input, not as pose quality.
    public var confidence: Double
    public var boundingBox: NormalizedRect
    public var boundingBoxArea: Double { boundingBox.area }

    public init(angles: VisionFaceAngles, confidence: Double, boundingBox: NormalizedRect) {
        self.angles = angles; self.confidence = confidence; self.boundingBox = boundingBox
    }
}

/// ALL THRESHOLDS ARE UNTUNED PLACEHOLDERS. They encode "obviously fine" vs "obviously bad" guesses
/// and must be tuned on real recordings. Each pair is (value giving 0, value giving 1) and the
/// score ramps linearly in between; the order of the pair decides whether higher or lower is better.
public struct TrackingQualityConfig: Equatable, Sendable {
    /// Face box height as a fraction of frame height: tiny faces give noisy angles.
    public var sizeZero = 0.10, sizeFull = 0.20
    /// Distance from the face box to the frame edge: a cropped face gives unreliable angles.
    public var edgeMarginZero = 0.0, edgeMarginFull = 0.03
    /// Per-frame movement of the box centre, in units of face size: implausible jumps are glitches.
    public var centerJumpZero = 1.0, centerJumpFull = 0.4
    /// Per-frame relative change of face size.
    public var scaleChangeZero = 0.5, scaleChangeFull = 0.2
    /// Angular speed of the raw face angles, degrees per second.
    public var angularSpeedZero = 1800.0, angularSpeedFull = 900.0
    /// Smoothed frame rate: a slow or stuttering camera gives stale poses.
    public var fpsZero = 8.0, fpsFull = 20.0
    /// Vision's own confidence (weak signal).
    public var visionConfidenceZero = 0.3, visionConfidenceFull = 0.6
    /// Gap (seconds) after which continuity checks and the fps estimate restart.
    public var continuityResetGap = 0.5
    /// EMA factor for the frame-rate estimate.
    public var fpsSmoothing = 0.1

    public init() {}
}

/// Per-frame quality in 0...1 with every component exposed so tuning is visible in the HUD.
/// `overall` is the weakest component (weakest link): easy to explain and to debug.
public struct QualityBreakdown: Equatable, Sendable {
    public var overall: Double
    /// Name of the component that set `overall` ("none" when all are 1).
    public var limiting: String
    public var facePresent: Bool
    public var size: Double
    public var edge: Double
    public var centerStability: Double
    public var scaleStability: Double
    public var angularStability: Double
    public var frameRate: Double
    public var visionConfidence: Double
    public var framesPerSecond: Double

    /// Used when there is no face (or no frames at all).
    public static func absent(reason: String, fps: Double = 0) -> QualityBreakdown {
        QualityBreakdown(overall: 0, limiting: reason, facePresent: false, size: 0, edge: 0,
                         centerStability: 0, scaleStability: 0, angularStability: 0, frameRate: 0,
                         visionConfidence: 0, framesPerSecond: fps)
    }
}

/// Our own tracking-quality signal from face presence, face size, edge cropping, bounding-box and
/// pose-angle continuity, and frame rate. Deliberately NOT included: landmark stability, because it
/// needs a second Vision request (`VNDetectFaceLandmarksRequest`) per frame whose cost on this
/// fanless hardware is unmeasured. Revisit after Step 5 measurements.
public struct TrackingQualityEstimator: Sendable {
    public var config: TrackingQualityConfig
    public private(set) var framesPerSecond = 0.0

    private var lastFrameTime: Double?
    private var previous: (time: Double, box: NormalizedRect, orientation: Quaternion)?

    public init(config: TrackingQualityConfig = TrackingQualityConfig()) {
        self.config = config
    }

    public mutating func reset() {
        framesPerSecond = 0; lastFrameTime = nil; previous = nil
    }

    /// Call when frames stopped arriving (watchdog): restarts continuity and the fps estimate.
    public mutating func noteGap() {
        framesPerSecond = 0; lastFrameTime = nil; previous = nil
    }

    /// `time` is the frame's capture time in seconds; `face` is nil when no usable face was found.
    public mutating func update(time: Double, face: FaceMeasurement?) -> QualityBreakdown {
        // Frame-rate estimate from capture timestamps (independent of whether a face was found).
        if let last = lastFrameTime {
            let dt = time - last
            if dt > config.continuityResetGap {
                framesPerSecond = 0; previous = nil
            } else if dt > 0 {
                let instant = 1 / dt
                framesPerSecond = framesPerSecond == 0 ? instant
                    : framesPerSecond + config.fpsSmoothing * (instant - framesPerSecond)
            }
        }
        if lastFrameTime == nil || time > lastFrameTime! { lastFrameTime = time }

        guard let face, face.angles.isFinite else {
            previous = nil
            return .absent(reason: "no face", fps: framesPerSecond)
        }

        let box = face.boundingBox
        let orientation = Quaternion(euler: EulerAngles(yaw: face.angles.yaw, pitch: face.angles.pitch, roll: face.angles.roll))

        var center = 1.0, scale = 1.0, angular = 1.0
        if let prev = previous, time > prev.time, time - prev.time <= config.continuityResetGap {
            let dt = time - prev.time
            let faceSize = max(box.size, 1e-6)
            let dist = ((box.centerX - prev.box.centerX) * (box.centerX - prev.box.centerX)
                        + (box.centerY - prev.box.centerY) * (box.centerY - prev.box.centerY)).squareRoot()
            center = Self.ramp(dist / faceSize, zero: config.centerJumpZero, full: config.centerJumpFull)
            let rel = abs(box.height - prev.box.height) / max(prev.box.height, 1e-6)
            scale = Self.ramp(rel, zero: config.scaleChangeZero, full: config.scaleChangeFull)
            let degPerSec = prev.orientation.angle(to: orientation) * 180 / .pi / dt
            angular = Self.ramp(degPerSec, zero: config.angularSpeedZero, full: config.angularSpeedFull)
        }
        // Always remember this frame, even if it scored badly: a real fast movement is then
        // accepted from the next frame on instead of being rejected forever.
        previous = (time, box, orientation)

        let parts: [(String, Double)] = [
            ("size", Self.ramp(box.height, zero: config.sizeZero, full: config.sizeFull)),
            ("edge", Self.ramp(box.edgeMargin, zero: config.edgeMarginZero, full: config.edgeMarginFull)),
            ("center jump", center),
            ("scale jump", scale),
            ("angular speed", angular),
            ("frame rate", framesPerSecond > 0
                ? Self.ramp(framesPerSecond, zero: config.fpsZero, full: config.fpsFull) : 1),
            ("vision confidence", Self.ramp(face.confidence, zero: config.visionConfidenceZero,
                                            full: config.visionConfidenceFull)),
        ]
        let weakest = parts.min { $0.1 < $1.1 }!
        return QualityBreakdown(
            overall: weakest.1, limiting: weakest.1 >= 1 ? "none" : weakest.0, facePresent: true,
            size: parts[0].1, edge: parts[1].1, centerStability: parts[2].1, scaleStability: parts[3].1,
            angularStability: parts[4].1, frameRate: parts[5].1, visionConfidence: parts[6].1,
            framesPerSecond: framesPerSecond)
    }

    /// Linear 0...1 between `zero` and `full`; works for either ordering of the two.
    static func ramp(_ x: Double, zero: Double, full: Double) -> Double {
        guard x.isFinite, zero != full else { return x.isFinite && x == full ? 1 : 0 }
        return min(max((x - zero) / (full - zero), 0), 1)
    }
}

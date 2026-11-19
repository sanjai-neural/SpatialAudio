import Foundation
import SpatialAudioCore

/// Step 6b-3c-0: writes the synthetic channel-check file (`ChannelCheckPattern`) to a path of the caller's choosing. IMPLEMENTED-UNVERIFIED.
///
/// The question it serves: the mute experiments need ONE long-lived player process (one `afplay` of a file of 15 minutes or more) so that its PID does not change. The file is generated, not recorded: no copyrighted
/// and no captured audio. It never overwrites an existing file unless asked, and it writes in one-second chunks (a 15-minute file is about 159 MB and is never held in memory).
public enum ChannelCheckFileTool {
    public struct Summary: Equatable, Sendable {
        public var seconds: Double
        public var frames: Int64
        public var bytes: Int64
        public var peakDecibelsFullScale: Double
        public var leftChannelRMSDecibels: Double
        public var rightChannelRMSDecibels: Double
    }

    public enum ToolError: Error, Equatable, CustomStringConvertible {
        case invalidDuration(String)
        case fileExists
        case cannotWrite(String)
        public var description: String {
            switch self {
            case .invalidDuration(let why): return why
            case .fileExists: return "the file exists; this tool never overwrites it unless told to"
            case .cannotWrite(let why): return "could not write the file: \(why)"
            }
        }
    }

    public static func write(to url: URL, seconds: Int, overwrite: Bool = false) throws -> Summary {
        if let problem = ChannelCheckPattern.validate(seconds: seconds) { throw ToolError.invalidDuration(problem) }
        return try writeFrames(to: url, frames: Int64(seconds) * Int64(ChannelCheckPattern.sampleRate), overwrite: overwrite)
    }

    /// The writer itself (no duration limits: the tests use short files).
    static func writeFrames(to url: URL, frames: Int64, overwrite: Bool) throws -> Summary {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            if !overwrite { throw ToolError.fileExists }
            try? manager.removeItem(at: url)
        }
        guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ToolError.cannotWrite("create") }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data(ChannelCheckPattern.wavHeader(frames: frames)))
            var start: Int64 = 0
            let chunk = ChannelCheckPattern.sampleRate
            while start < frames {
                let n = Int(min(Int64(chunk), frames - start))
                try handle.write(contentsOf: Data(ChannelCheckPattern.pcm16(startFrame: start, count: n)))
                start += Int64(n)
            }
        } catch {
            throw ToolError.cannotWrite(error.localizedDescription)
        }
        let stats = ChannelCheckPattern.statistics(frames: min(frames, Int64(ChannelCheckPattern.cycleFrames)))
        return Summary(seconds: Double(frames) / Double(ChannelCheckPattern.sampleRate), frames: frames, bytes: 44 + frames * 4,
                       peakDecibelsFullScale: LevelMath.amplitudeDecibels(Double(stats.peakAmplitude)),
                       leftChannelRMSDecibels: LevelMath.amplitudeDecibels(stats.leftRMS), rightChannelRMSDecibels: LevelMath.amplitudeDecibels(stats.rightRMS))
    }
}

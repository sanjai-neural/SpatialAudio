import Foundation
import SpatialAudioCore

/// Writes self-test reports (numbers only; no images exist in the report type) and stores the applied
/// sign mapping.
enum ReportStore {
    /// Dev bundles made by scripts/make-app.sh carry the repository path in Info.plist (key `SADevRepoRoot`),
    /// so reports land in <repo>/docs/test-results. Without it (e.g. a release build) they go to
    /// ~/Library/Application Support/SpatialAudio/test-results.
    static func resultsDirectory(override: URL?) -> URL {
        if let override { return override }
        if let root = Bundle.main.object(forInfoDictionaryKey: "SADevRepoRoot") as? String, !root.isEmpty {
            return URL(fileURLWithPath: root).appendingPathComponent("docs/test-results", isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("SpatialAudio/test-results", isDirectory: true)
    }

    /// Writes `<stem>.json` and `<stem>.md` (overwriting a previous write of the same run). Returns both URLs.
    @discardableResult
    static func write(_ report: SelfTestReport, stem: String, to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = directory.appendingPathComponent(stem + ".json")
        let markdown = directory.appendingPathComponent(stem + ".md")
        try report.jsonData().write(to: json, options: .atomic)
        try Data(report.markdown().utf8).write(to: markdown, options: .atomic)
        return [json, markdown]
    }
}

extension ReportStore {
    /// Writes `<stem>.json` and `<stem>.md` for a system-audio tap probe (Step 6a). Numbers only.
    @discardableResult
    static func writeTapProbe(_ report: TapProbeReport, stem: String, to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = directory.appendingPathComponent(stem + ".json")
        let markdown = directory.appendingPathComponent(stem + ".md")
        try report.jsonData().write(to: json, options: .atomic)
        try Data(report.markdown().utf8).write(to: markdown, options: .atomic)
        return [json, markdown]
    }
}

/// Sign mapping the user confirmed after a self-test. Just three booleans and a label; no camera data.
struct SavedMapping: Codable, Equatable {
    var mapping: HeadAngleMapping
    var cameraName: String
    var framesMirrored: Bool
    var savedAt: String
}

enum MappingStore {
    private static let key = "SpatialAudio.savedMapping.v1"

    static func load() -> SavedMapping? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SavedMapping.self, from: data)
    }

    static func save(_ saved: SavedMapping) {
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

enum HardwareInfo {
    /// Machine identifier such as "Mac16,12" (no serial number or user information).
    static let model: String = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }()
}

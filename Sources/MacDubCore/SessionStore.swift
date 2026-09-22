import Foundation

/// A finished dubbing session, persisted as JSON so it can be reopened, exported or read by the
/// MCP server after the fact.
public struct SessionRecord: Codable, Identifiable, Equatable {
    public var id: String
    public var startedAt: Date
    public var endedAt: Date
    public var appName: String?
    public var appBundleIdentifier: String?
    public var sourceLocale: String
    public var targetLanguage: String
    public var segments: [LiveState.SegmentDTO]

    public init(id: String = UUID().uuidString, startedAt: Date, endedAt: Date = Date(), appName: String?,
                appBundleIdentifier: String?, sourceLocale: String, targetLanguage: String, segments: [Segment]) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.appName = appName
        self.appBundleIdentifier = appBundleIdentifier
        self.sourceLocale = sourceLocale
        self.targetLanguage = targetLanguage
        self.segments = segments.map(LiveState.SegmentDTO.init)
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    public var sentenceCount: Int { segments.count }

    public var metadata: TranscriptExporter.Metadata {
        TranscriptExporter.Metadata(appName: appName, sourceLanguage: sourceLocale, targetLanguage: targetLanguage)
    }

    public func render(_ format: TranscriptExporter.Format, content: TranscriptExporter.Content = .both) -> String {
        TranscriptExporter.render(segments.map(\.segment), format: format, content: content,
                                  sessionStart: startedAt, metadata: metadata)
    }

    /// Short human title: "Google Chrome · 22 Sep 2026 13:05 · 48 sentences".
    public var title: String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return [appName ?? "—", df.string(from: startedAt), "\(sentenceCount)"].joined(separator: " · ")
    }
}

/// Session files live next to `live.json`: `~/Library/Application Support/MacDub/sessions/<id>.json`.
public enum SessionStore {
    public static var directory: URL { LiveStateStore.directory.appendingPathComponent("sessions", isDirectory: true) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func url(for id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension("json")
    }

    public static func save(_ record: SessionRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(record).write(to: url(for: record.id), options: .atomic)
    }

    public static func load(id: String) throws -> SessionRecord {
        try decoder.decode(SessionRecord.self, from: Data(contentsOf: url(for: id)))
    }

    public static func delete(id: String) throws {
        try FileManager.default.removeItem(at: url(for: id))
    }

    /// Newest first.
    public static func list() -> [SessionRecord] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(SessionRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }
}

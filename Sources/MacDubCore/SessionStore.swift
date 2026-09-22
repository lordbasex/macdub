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
    /// File name of the recorded original audio inside `MacDubPaths.audioDirectory`, when the
    /// session was recorded. Absent for sessions saved before recording existed or with it off.
    public var audioFile: String?

    public init(id: String = UUID().uuidString, startedAt: Date, endedAt: Date = Date(), appName: String?,
                appBundleIdentifier: String?, sourceLocale: String, targetLanguage: String, segments: [Segment],
                audioFile: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.appName = appName
        self.appBundleIdentifier = appBundleIdentifier
        self.sourceLocale = sourceLocale
        self.targetLanguage = targetLanguage
        self.segments = segments.map(LiveState.SegmentDTO.init)
        self.audioFile = audioFile
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    public var sentenceCount: Int { segments.count }

    /// Where the recorded audio is, or nil when there is none on disk.
    public var audioURL: URL? {
        guard let audioFile else { return nil }
        let url = MacDubPaths.audioDirectory.appendingPathComponent(audioFile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

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

    /// Base name for exported files: `macdub-audio-2026-09-22-191105`. No spaces, so the pair
    /// `<base>.m4a` + `<base>.srt` is picked up by players (VLC loads a subtitle file that has the
    /// same name as the media next to it).
    public func exportBaseName(kind: String = "audio") -> String {
        "macdub-\(kind)-\(Self.exportStamp(startedAt))"
    }

    public static func exportStamp(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        return df.string(from: date)
    }
}

/// Where MacDub keeps what can grow: `~/.macdub/` (recorded audio of each session). The app is
/// not sandboxed, so this really is the user's home. Transcripts stay small and live in
/// Application Support (see `LiveStateStore.directory`) because the MCP server reads them there.
public enum MacDubPaths {
    public static let dataDirectoryName = ".macdub"

    public static var dataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(dataDirectoryName, isDirectory: true)
    }

    /// Early builds used `~/.macdub`. On the usual case-insensitive APFS both names reach the
    /// same folder, but the name on disk should be the lower-case one; on a case-sensitive
    /// volume they are different folders and the old one must be moved. Called once at launch.
    public static func migrateLegacyDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: home.path),
              names.contains(".MacDub"), !names.contains(dataDirectoryName) else { return }
        try? FileManager.default.moveItem(at: home.appendingPathComponent(".MacDub", isDirectory: true), to: dataDirectory)
    }

    public static var audioDirectory: URL { dataDirectory.appendingPathComponent("audio", isDirectory: true) }

    /// Extension of recorded session audio. AAC in an MPEG-4 container: native to macOS (no
    /// transcoding to play or export), small, and every player including VLC opens it.
    public static let audioExtension = "m4a"

    /// Bytes used under `url` (files only, following no symlinks). 0 when it does not exist.
    public static func directorySize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                              options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    /// Deletes `*.part.m4a` left behind by a crash while a resumed session was being re-encoded.
    public static func removeStrayPartFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasSuffix(".part.\(audioExtension)") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Everything MacDub wrote outside its preferences: recorded audio, saved sessions, live state.
    public static var allDataDirectories: [URL] { [dataDirectory, LiveStateStore.directory] }
}

/// Session files live next to `live.json`: `~/Library/Application Support/MacDub/sessions/<id>.json`.
/// Their audio lives in `~/.macdub/audio/<id>.m4a` and is removed together with the session.
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

    /// Where the audio of session `id` is recorded to.
    public static func audioURL(for id: String) -> URL {
        MacDubPaths.audioDirectory.appendingPathComponent(id).appendingPathExtension(MacDubPaths.audioExtension)
    }

    public static func save(_ record: SessionRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(record).write(to: url(for: record.id), options: .atomic)
    }

    public static func exists(id: String) -> Bool { FileManager.default.fileExists(atPath: url(for: id).path) }

    public static func load(id: String) throws -> SessionRecord {
        try decoder.decode(SessionRecord.self, from: Data(contentsOf: url(for: id)))
    }

    /// Removes the transcript and its recorded audio (if any).
    public static func delete(id: String) throws {
        let audio = (try? load(id: id))?.audioURL ?? audioURL(for: id)
        try? FileManager.default.removeItem(at: audio)
        try FileManager.default.removeItem(at: url(for: id))
    }

    /// Removes every saved session and every recorded audio file.
    public static func deleteAll() throws {
        for record in list() { try? FileManager.default.removeItem(at: url(for: record.id)) }
        if FileManager.default.fileExists(atPath: MacDubPaths.audioDirectory.path) {
            try FileManager.default.removeItem(at: MacDubPaths.audioDirectory)
        }
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

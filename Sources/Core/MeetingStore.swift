import Foundation

/// A metadata library with separate, dated content files. All disk access stays
/// behind this seam; inMemory() never creates artifacts or assigns disk paths.
public final class MeetingStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSRecursiveLock()
    private var cache: [Meeting]?
    private var memoryOnly = false
    private var unreadableLibrary = false
    public private(set) var lastError: String?

    private struct Payload<T: Codable & Equatable>: Codable {
        var meetingID: UUID
        var revision: UUID
        var content: T
    }
    private enum StorageError: Error { case invalidLocation, missingContent }
    private var root: URL { url.deletingLastPathComponent() }

    public init(url: URL) { self.url = url }
    public static func inMemory(initial: [Meeting] = []) -> MeetingStore {
        let store = MeetingStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriber-meetings-\(UUID().uuidString).json"))
        store.cache = initial
        store.memoryOnly = true
        return store
    }
    public var fileURL: URL { url }

    private func location(_ folder: String, _ stem: String, _ ext: String) -> URL {
        root.appendingPathComponent(folder).appendingPathComponent(stem).appendingPathExtension(ext)
    }
    private func validStem(_ stem: String, for meeting: Meeting) -> Bool {
        RecordingsDirectory.meetingID(inDirectoryName: stem) == meeting.id &&
        !stem.contains("/") && !stem.contains("\\") && stem != meeting.id.uuidString
    }
    private func stem(for meeting: Meeting) -> String {
        if let saved = meeting.contentFiles?.stem, validStem(saved, for: meeting) { return saved }
        for audio in meeting.audioFileURLs.values {
            let name = audio.deletingLastPathComponent().lastPathComponent
            if validStem(name, for: meeting) { return name }
        }
        return RecordingsDirectory.fileStem(for: meeting)
    }
    private func validate(_ files: MeetingContentFiles, meeting: Meeting) throws {
        guard validStem(files.stem, for: meeting) else { throw StorageError.invalidLocation }
        let pairs: [(URL?, URL)] = [
            (files.summaryJSON, location("summaries", files.stem, "json")),
            (files.summaryMarkdown, location("summaries", files.stem, "md")),
            (files.transcriptJSON, location("transcripts", files.stem, "json")),
            (files.transcriptText, location("transcripts", files.stem, "txt"))]
        for (actual, expected) in pairs {
            if let actual, actual.standardizedFileURL != expected.standardizedFileURL {
                throw StorageError.invalidLocation
            }
            // Refuse redirected content folders/files (including backups).
            for target in [expected, expected.appendingPathExtension("bak")] {
                guard target.resolvingSymlinksInPath().deletingLastPathComponent().path ==
                        root.resolvingSymlinksInPath().appendingPathComponent(expected.deletingLastPathComponent().lastPathComponent).path,
                      target.resolvingSymlinksInPath().lastPathComponent == target.lastPathComponent else {
                    throw StorageError.invalidLocation
                }
            }
        }
    }
    private func read<T>(_ type: T.Type, from file: URL, id: UUID, revision: UUID?) throws -> T where T: Codable & Equatable {
        for candidate in [file, file.appendingPathExtension("bak")] {
            if let bytes = try? Data(contentsOf: candidate),
               let payload = try? JSONDecoder().decode(Payload<T>.self, from: bytes),
               payload.meetingID == id, payload.revision == revision {
                return payload.content
            }
        }
        throw StorageError.missingContent
    }

    public func load() -> [Meeting] {
        lock.lock(); defer { lock.unlock() }
        if let cache { return cache }
        let fm = FileManager.default
        var found = false
        for candidate in [url, url.appendingPathExtension("bak")] {
            guard fm.fileExists(atPath: candidate.path) else { continue }
            found = true
            guard let bytes = try? Data(contentsOf: candidate),
                  var meetings = try? JSONDecoder().decode([Meeting].self, from: bytes) else { continue }
            let rawRows = (try? JSONSerialization.jsonObject(with: bytes)) as? [[String: Any]]
            var legacy = rawRows?.contains { $0["summary"] != nil || $0["transcript"] != nil } ?? false
            var errors = false
            for i in meetings.indices {
                if meetings[i].summary != nil || !meetings[i].transcript.isEmpty { legacy = true }
                guard let files = meetings[i].contentFiles else { continue }
                do {
                    try validate(files, meeting: meetings[i])
                    if meetings[i].deletionPending { continue }
                    if let file = files.summaryJSON, meetings[i].summary == nil {
                        meetings[i].summary = try read(MeetingSummary.self, from: file,
                            id: meetings[i].id, revision: files.summaryRevision)
                    }
                    if let file = files.transcriptJSON, meetings[i].transcript.isEmpty {
                        meetings[i].transcript = try read([TranscriptSegment].self, from: file,
                            id: meetings[i].id, revision: files.transcriptRevision)
                    }
                } catch {
                    errors = true
                    meetings[i].status = .failed
                    meetings[i].failureReason = "A meeting content file is missing or unreadable. Restore it from backup before retrying."
                }
            }
            if errors {
                lastError = "Some meeting files could not be read. Automatic cleanup is paused to preserve your recordings."
            } else if legacy {
                // save() writes all discrete artifacts first, then replaces both
                // indexes. A failed migration leaves the legacy data untouched.
                if save(meetings, sanitizeBackup: true) { return cache ?? meetings }
            }
            cache = meetings
            return meetings
        }
        if found || ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("recordings").path).isEmpty) == false) {
            unreadableLibrary = true
            lastError = "The meeting library could not be read. Automatic cleanup is paused to preserve your recordings."
        }
        return []
    }

    @discardableResult
    public func save(_ meetings: [Meeting], sanitizeBackup: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if memoryOnly { cache = meetings; return true }
        guard !unreadableLibrary else { return false }
        var rollback: [(URL, Data?)] = []
        func write(_ bytes: Data, to file: URL) throws {
            let old = try? Data(contentsOf: file)
            if old == bytes { return }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
            rollback.append((file, old))
        }
        func payload<T>(_ value: T, at file: URL, id: UUID) throws -> UUID where T: Codable & Equatable {
            if let bytes = try? Data(contentsOf: file.appendingPathExtension("bak")),
               let backup = try? JSONDecoder().decode(Payload<T>.self, from: bytes),
               backup.meetingID == id, backup.content == value {
                try write(bytes, to: file)
                return backup.revision
            }
            if let bytes = try? Data(contentsOf: file),
               let old = try? JSONDecoder().decode(Payload<T>.self, from: bytes), old.meetingID == id {
                if old.content == value { return old.revision }
                try write(bytes, to: file.appendingPathExtension("bak"))
            }
            let revision = UUID()
            try write(JSONEncoder().encode(Payload(meetingID: id, revision: revision, content: value)), to: file)
            return revision
        }
        do {
            var stored = meetings
            for i in stored.indices {
                var meeting = stored[i]
                if let existing = meeting.contentFiles { try validate(existing, meeting: meeting) }
                if meeting.deletionPending && meeting.contentFiles != nil { continue }
                var files = meeting.contentFiles ?? MeetingContentFiles(stem: stem(for: meeting))
                try validate(files, meeting: meeting)
                if let summary = meeting.summary {
                    files.summaryJSON = location("summaries", files.stem, "json")
                    files.summaryMarkdown = location("summaries", files.stem, "md")
                    files.summaryRevision = try payload(summary, at: files.summaryJSON!, id: meeting.id)
                    try write(Data(("# \(meeting.title)\n\n" + meeting.summaryText() + "\n").utf8), to: files.summaryMarkdown!)
                } else if files.summaryJSON != nil {
                    throw StorageError.missingContent
                }
                if !meeting.transcript.isEmpty {
                    files.transcriptJSON = location("transcripts", files.stem, "json")
                    files.transcriptText = location("transcripts", files.stem, "txt")
                    files.transcriptRevision = try payload(meeting.transcript, at: files.transcriptJSON!, id: meeting.id)
                    try write(Data(("# \(meeting.title)\n\n" + meeting.transcriptText() + "\n").utf8), to: files.transcriptText!)
                } else {
                    // Clearing existing content is authorized only by a durable
                    // retention decision. Missing files must not silently vanish
                    // from the library on an unrelated metadata save.
                    if let file = files.transcriptJSON, !meeting.pendingArtifactDeletion.contains(file) {
                        throw StorageError.missingContent
                    }
                    files.transcriptJSON = nil; files.transcriptText = nil; files.transcriptRevision = nil
                }
                meeting.contentFiles = files
                stored[i] = meeting
            }
            var index = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as! [[String: Any]]
            for i in index.indices { index[i].removeValue(forKey: "summary"); index[i].removeValue(forKey: "transcript") }
            let data = try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys])
            let clearingTranscript = meetings.contains { meeting in
                meeting.transcript.isEmpty && meeting.contentFiles?.transcriptJSON.map { meeting.pendingArtifactDeletion.contains($0) } == true
            }
            if sanitizeBackup || clearingTranscript {
                try write(data, to: url.appendingPathExtension("bak"))
            } else if let old = try? Data(contentsOf: url),
                      let rows = try? JSONSerialization.jsonObject(with: old) as? [[String: Any]],
                      (try? JSONDecoder().decode([Meeting].self, from: old)) != nil {
                // Never rotate an inline-content legacy index into the metadata
                // backup. Migration installs a fully hydrated replacement.
                let inline = rows.contains { $0["summary"] != nil || $0["transcript"] != nil }
                try write(inline ? data : old, to: url.appendingPathExtension("bak"))
            }
            try write(data, to: url)
            cache = stored; lastError = nil
            return true
        } catch {
            for (file, old) in rollback.reversed() {
                if let old { try? old.write(to: file, options: .atomic) }
                else { try? FileManager.default.removeItem(at: file) }
            }
            lastError = "Meeting files could not be saved. Existing content and recordings were preserved."
            return false
        }
    }
}

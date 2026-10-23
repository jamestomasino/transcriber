import Foundation

// MARK: - MeetingStore (Core, I/O seam)
//
// Persists the collection of `Meeting`s (summaries + any retained
// transcripts) to meetings.json. This is the product's core promise made
// real: the summary is the only *durable* artifact, so it must survive app
// relaunch. Mirrors `SettingsStore` exactly — a JSON file with an
// `inMemory()` seam so the test suite never reads/writes the user's real
// meetings.json.
//
// The engine stays pure: it calls `load()` to hydrate and `save()` to
// persist, but it does no I/O itself. `MeetingEngine.load(_:)` also
// reconciles mid-flight meetings (recording/processing) to `.failed` so a
// crash-during-meeting leaves a retryable record rather than a stuck one.

public final class MeetingStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var cache: [Meeting]?
    private var memoryOnly = false

    public init(url: URL) {
        self.url = url
    }

    /// A store that keeps meetings only in memory (tests). `initial` seeds
    /// the cache so a round-trip test can pre-populate state without disk.
    public static func inMemory(initial: [Meeting] = []) -> MeetingStore {
        let s = MeetingStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriber-meetings-\(UUID().uuidString).json"))
        s.cache = initial
        s.memoryOnly = true
        return s
    }

    /// The backing file path (useful for tests and for the app to locate it).
    public var fileURL: URL { url }

    /// Load the meetings. Missing file or corrupt JSON yields an empty list
    /// (a fresh app) rather than throwing — same lenient posture as
    /// `SettingsStore.load()`.
    public func load() -> [Meeting] {
        if let c = cache { return c }
        for candidate in [url, url.appendingPathExtension("bak")] {
            if let data = try? Data(contentsOf: candidate),
               let meetings = try? JSONDecoder().decode([Meeting].self, from: data) {
                cache = meetings
                return meetings
            }
        }
        return []
    }

    /// Persist the full collection atomically. The collection is the single
    /// source of truth (the engine owns ordering), so we write the whole
    /// array each time rather than diffing.
    ///
    /// Before overwriting, the *current* file is copied to `meetings.json.bak`
    /// (the base repo's `EntryStore` backup-rotation posture: the summary is
    /// the user's irreplaceable data, so the previous good copy is kept).
    /// If the new write fails, the old file is left untouched (atomic write),
    /// and the `.bak` from the prior save is still available to recover from.
    @discardableResult
    public func save(_ meetings: [Meeting], sanitizeBackup: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if memoryOnly { cache = meetings; return true }
        do {
            let data = try JSONEncoder().encode(meetings)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Never overwrite the recovery copy with corrupt live data.
            if sanitizeBackup {
                try data.write(to: url.appendingPathExtension("bak"), options: .atomic)
            } else if let old = try? Data(contentsOf: url),
                      (try? JSONDecoder().decode([Meeting].self, from: old)) != nil {
                try old.write(to: url.appendingPathExtension("bak"), options: .atomic)
            }
            try data.write(to: url, options: .atomic)
            cache = meetings
            return true
        } catch {
            return false
        }
    }
}

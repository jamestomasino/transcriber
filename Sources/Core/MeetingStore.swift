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

    public init(url: URL) {
        self.url = url
    }

    /// A store that keeps meetings only in memory (tests). `initial` seeds
    /// the cache so a round-trip test can pre-populate state without disk.
    public static func inMemory(initial: [Meeting] = []) -> MeetingStore {
        let s = MeetingStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriber-meetings-\(UUID().uuidString).json"))
        s.cache = initial
        return s
    }

    /// The backing file path (useful for tests and for the app to locate it).
    public var fileURL: URL { url }

    /// Load the meetings. Missing file or corrupt JSON yields an empty list
    /// (a fresh app) rather than throwing — same lenient posture as
    /// `SettingsStore.load()`.
    public func load() -> [Meeting] {
        if let c = cache { return c }
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            let ms = try JSONDecoder().decode([Meeting].self, from: data)
            cache = ms
            return ms
        } catch {
            return []
        }
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
    public func save(_ meetings: [Meeting]) {
        lock.lock()
        cache = meetings
        lock.unlock()
        let data = (try? JSONEncoder().encode(meetings)) ?? Data()
        // Rotate: keep a backup of the file as it is *now* (if any).
        if FileManager.default.fileExists(atPath: url.path) {
            let bak = url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: bak)
            try? FileManager.default.copyItem(at: url, to: bak)
        }
        // Atomic write: a crash mid-write can't corrupt the live file.
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // The live file is unchanged (atomic); the .bak is the fallback.
        }
    }
}

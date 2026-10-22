import Foundation

/// Pure meeting lifecycle state machine.
///
/// This is the `TimeTrackerEngine` analog from the base repo: it owns the
/// in-memory collection of `Meeting`s and the transitions between their
/// statuses, but it does **no I/O**. It knows nothing about audio files,
/// transcripts on disk, transcription, or the network — those are side effects
/// the view model performs around the engine, using the injected
/// `MeetingProcessor` and `RetentionPolicy` (added in later phases).
///
/// Clock-injected so tests are exact (no sleeps).
public final class MeetingEngine {
    private var meetings: [Meeting] = []
    private let clock: Clock

    public init(clock: Clock = SystemClock()) {
        self.clock = clock
    }

    // MARK: - Hydration (persistence seam)
    //
    // `load(_:)` is called by the view model with the result of
    // `MeetingStore.load()`. It hydrates the in-memory collection and
    // reconciles any meeting that was mid-flight (`.recording` / `.processing`)
    // at the last save to `.failed`. A meeting can never be recording or
    // processing across a relaunch — the capture is gone and the pipeline is
    // not running — so those are left retryable (`.failed`) rather than stuck.
    // Summarized + already-failed meetings load untouched.
    public func load(_ meetings: [Meeting], now: Date? = nil) {
        let t = now ?? clock.now()
        self.meetings = meetings.map { m in
            var m = m
            if m.status == .recording || m.status == .processing {
                m.status = .failed
                m.lastActivityAt = t
            }
            return m
        }
    }

    /// The current collection in stored order (the view model persists this
    /// verbatim, so the engine is the single source of ordering).
    public var stored: [Meeting] { meetings }

    // MARK: - Queries

    public var all: [Meeting] { meetings }

    public func meeting(id: UUID) -> Meeting? {
        meetings.first { $0.id == id }
    }

    /// The single active (recording) meeting, if any.
    public var active: Meeting? {
        meetings.first { $0.status == .recording }
    }

    /// Most-recently-active first; the active meeting is pinned to the top.
    public var recent: [Meeting] {
        let active = self.active
        let rest = meetings
            .filter { $0.status != .recording }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        if let active { return [active] + rest }
        return rest
    }

    /// Case-insensitive substring search over title, summary text, speaker
    /// names, and transcript text.
    public func search(_ query: String) -> [Meeting] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return recent }
        return recent.filter { m in
            m.title.lowercased().contains(q)
                || m.summary?.overall.lowercased().contains(q) == true
                || m.transcript.contains { $0.speaker.lowercased().contains(q) }
                || m.transcript.contains { $0.text.lowercased().contains(q) }
        }
    }

    // MARK: - Transitions

    /// Start a new meeting. If one is already recording, it is stopped first
    /// (same "only one running" invariant as the base repo).
    /// An empty/blank title defaults to a timestamp.
    @discardableResult
    public func start(title: String? = nil, now: Date? = nil) -> Meeting {
        let t = now ?? clock.now()
        stopActive(now: t)

        let resolved = MeetingEngine.resolvedTitle(title, at: t)
        let m = Meeting(
            title: resolved,
            status: .recording,
            startedAt: t,
            createdAt: t,
            lastActivityAt: t
        )
        meetings.append(m)
        return m
    }

    /// Stop the given meeting and move it to `.processing`.
    public func stop(id: UUID, now: Date? = nil) {
        let t = now ?? clock.now()
        guard let idx = index(of: id) else { return }
        guard meetings[idx].status == .recording else { return }
        meetings[idx].stoppedAt = t
        meetings[idx].duration = max(0, t.timeIntervalSince(meetings[idx].startedAt))
        meetings[idx].status = .processing
        meetings[idx].lastActivityAt = t
    }

    /// Stop whichever meeting is recording (if any).
    public func stopActive(now: Date? = nil) {
        if let a = active { stop(id: a.id, now: now) }
    }

    /// Record the captured audio file URLs for a meeting (a side effect the
    /// view model performs after capture finishes, then hands back here).
    public func setAudioFiles(id: UUID, files: [AudioSource: URL], now: Date? = nil) {
        let t = now ?? clock.now()
        guard let idx = index(of: id) else { return }
        meetings[idx].audioFileURLs = files
        meetings[idx].lastActivityAt = t
    }

    /// Record a successful summary. By default clears the transient transcript
    /// (the product's core promise: keep only the summary). If `keepTranscript`
    /// is true (the user's retention setting), the transcript is retained in
    /// the record. The on-disk audio/transcript-file deletion is a *side
    /// effect* handled by the view model + `RetentionPolicy`, not the engine.
    public func markSummarized(
        id: UUID,
        summary: MeetingSummary,
        speakerCount: Int,
        keepTranscript: Bool = false,
        now: Date? = nil
    ) {
        let t = now ?? clock.now()
        guard let idx = index(of: id) else { return }
        meetings[idx].summary = summary
        meetings[idx].speakerCount = speakerCount
        if !keepTranscript {
            meetings[idx].transcript = []
        }
        meetings[idx].status = .summarized
        meetings[idx].lastActivityAt = t
    }

    /// Attach a transcript to a meeting (set by the view model after the
    /// transcribe stage, so the record is inspectable even before summarizing).
    public func setTranscript(id: UUID, segments: [TranscriptSegment], now: Date? = nil) {
        let t = now ?? clock.now()
        guard let idx = index(of: id) else { return }
        meetings[idx].transcript = segments
        meetings[idx].lastActivityAt = t
    }

    /// Drop the stored audio file URLs from the record (after the view model
    /// has deleted the files per `RetentionPolicy`). The engine never touches
    /// the filesystem — this only clears the in-memory record.
    public func clearAudioFiles(id: UUID, now: Date? = nil) {
        let t = now ?? clock.now()
        guard let idx = index(of: id) else { return }
        meetings[idx].audioFileURLs = [:]
        meetings[idx].lastActivityAt = t
    }

    /// Record a processing failure. Artifacts are kept so the user can retry.
    public func fail(id: UUID, now: Date? = nil) {
        let t = now ?? clock.now()
        guard let idx = index(of: id) else { return }
        meetings[idx].status = .failed
        meetings[idx].lastActivityAt = t
    }

    /// Re-enter processing (retry after a failure).
    public func retry(id: UUID, now: Date? = nil) {
        let t = now ?? clock.now()
        guard let idx = index(of: id) else { return }
        guard meetings[idx].status == .failed else { return }
        meetings[idx].status = .processing
        meetings[idx].lastActivityAt = t
    }

    /// Remove a meeting entirely (its on-disk artifacts are a side effect the
    /// view model performs).
    @discardableResult
    public func delete(id: UUID) -> Bool {
        guard let idx = index(of: id) else { return false }
        meetings.remove(at: idx)
        return true
    }

    // MARK: - Helpers

    private func index(of id: UUID) -> Int? {
        meetings.firstIndex { $0.id == id }
    }

    /// A blank title becomes a human-readable timestamp, e.g. "Meeting 14:30".
    static func resolvedTitle(_ raw: String?, at date: Date) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return "Meeting \(f.string(from: date))"
    }
}

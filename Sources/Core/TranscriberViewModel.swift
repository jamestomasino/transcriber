import Foundation
import Combine

#if canImport(TranscriberCore)
import TranscriberCore
#endif

// MARK: - TranscriberViewModel
//
// The view model is the single source of truth for the UI. It holds the
// `MeetingEngine` (pure state machine) and an injected `AudioCapture` (the
// platform capture implementation, or a fake in tests). It wires the
// engine's state changes to the capture side effects:
//
//   start  → engine.start + capture.start (mic + system audio)
//   stop   → engine.stop  + capture stop → record audioFileURLs
//   process→ (Phase 3) transcribe + summarize, then delete raw audio
//
// It is `@MainActor` and `ObservableObject` so SwiftUI observes it directly.
// The capture runs on its own threads/queues; the view model marshals results
// back onto the main actor.

@MainActor
public final class TranscriberViewModel: ObservableObject {
    @Published public private(set) var meetings: [Meeting] = []
    @Published public private(set) var activeMeeting: Meeting?
    @Published public private(set) var levels: [AudioSource: Float] = [:]
    @Published public private(set) var captureStatus: [AudioSource: AudioCaptureError] = [:]
    /// The pipeline stage currently running (for the detail view's progress
    /// bar). nil when not processing.
    @Published public private(set) var processingProgress: ProcessingProgress?
    /// A human-readable processing error, when the last pipeline run failed.
    @Published public private(set) var processingError: String?

    private let engine: MeetingEngine
    private let capture: AudioCapture
    /// The post-stop pipeline (transcribe → diarize → summarize). Injected so
    /// tests can use a `FakeProcessor` and the app can supply a real backend.
    /// Defaults to `NoopProcessor` (does nothing) so the start/stop flow works
    /// before a backend is chosen.
    private let processor: any MeetingProcessor
    /// Optional factory that rebuilds the pipeline from the *current* settings
    /// at run time. When present, `runPipeline` uses it (so switching backend /
    /// model in Settings takes effect on the next meeting without a relaunch);
    /// otherwise it falls back to the fixed `processor`. Pure: it only takes
    /// `AppSettings` and returns a processor, so Core stays free of Keychain /
    /// URLSession. The App wires it to `ProcessorFactory.make(settings:)`.
    private let processorFactory: ((AppSettings) -> any MeetingProcessor)?
    /// Posts a notification when a meeting reaches a terminal state (summarized
    /// or failed). Injected so tests can use a recording fake and the app can
    /// wire a real `UNUserNotificationCenter` poster. Pure: it only takes the
    /// decided `MeetingNotification` (title / body / severity) — it owns the
    /// platform call, not the decision. `nil` posts nothing, so the test fakes
    /// and any environment without a poster keep working.
    private let notifier: ((MeetingNotification) -> Void)?
    /// User preferences (retention, backend, model, …). Published so the
    /// Settings UI reflects changes live and re-renders on update.
    @Published public var settings: AppSettings
    private let settingsStore: SettingsStore?
    /// Durable store for the meetings themselves (summaries + retained
    /// transcripts). Optional so the test fakes and the legacy no-store path
    /// keep working; the app always supplies one. When present, every engine
    /// mutation is persisted so the summary survives a relaunch.
    private let meetingStore: MeetingStore?
    private var session: AudioCaptureSession?
    /// The meeting id whose capture session is in flight (so a stray stop
    /// can't be misrouted to the wrong meeting).
    private var sessionMeetingID: UUID?
    /// Guards against concurrent pipeline runs for the same meeting.
    private var processingIDs: Set<UUID> = []

    public init(
        engine: MeetingEngine = MeetingEngine(),
        capture: AudioCapture,
        processor: any MeetingProcessor = NoopProcessor(),
        settings: AppSettings = AppSettings(),
        settingsStore: SettingsStore? = nil,
        meetingStore: MeetingStore? = nil,
        processorFactory: ((AppSettings) -> any MeetingProcessor)? = nil,
        notifier: ((MeetingNotification) -> Void)? = nil
    ) {
        self.engine = engine
        self.capture = capture
        self.processor = processor
        self.processorFactory = processorFactory
        self.notifier = notifier
        self.settings = settings
        self.settingsStore = settingsStore
        self.meetingStore = meetingStore
        // Hydrate from disk if a store was supplied (reconciling mid-flight
        // meetings to .failed), then reflect the loaded state in the UI.
        if let store = meetingStore {
            engine.load(store.load())
        }
        self.meetings = engine.recent
        self.activeMeeting = engine.active
        // Backstop for the retention promise: remove any per-meeting recording
        // directories that outlived their meeting (a prior build that cleaned
        // the audio files but not the dir, or a crash mid-pipeline). This is
        // idempotent and safe — it only touches UUID-named dirs that aren't a
        // live meeting's (or are a live meeting's but already empty).
        self.sweepOrphanRecordings()
    }

    /// Remove per-meeting recording directories that no longer correspond to a
    /// live meeting (or are empty leftovers). Pure decision lives in
    /// `RecordingsDirectory.orphanDirectories`; this performs the I/O. Returns
    /// the directories removed, so tests can assert the sweep's effect.
    @discardableResult
    public func sweepOrphanRecordings() -> [URL] {
        let liveIDs = Set(engine.stored.map(\.id))
        let orphans = RecordingsDirectory.orphanDirectories(liveIDs: liveIDs)
        for url in orphans { try? FileManager.default.removeItem(at: url) }
        return orphans
    }

    // MARK: - Persistence

    /// Persist the engine's current collection to disk (a no-op when no store
    /// is wired). Called after every mutation that should survive a relaunch.
    private func persist() {
        meetingStore?.save(engine.stored)
    }

    // MARK: - Derived

    public var isRecording: Bool { activeMeeting?.status == .recording }

    public func meeting(id: UUID) -> Meeting? { engine.meeting(id: id) }

    public func search(_ query: String) -> [Meeting] { engine.search(query) }

    public func level(_ source: AudioSource) -> Float { levels[source] ?? 0 }

    /// Human-readable capture problems, one per failed source, ordered mic →
    /// system. Empty when every requested source is recording cleanly. The UI
    /// renders this verbatim, so it doubles as the permission guidance.
    public var captureStatusMessages: [String] {
        [AudioSource.mic, .system]
            .compactMap { captureStatus[$0]?.description }
    }

    /// True when at least one requested source failed to start (a partial or
    /// total capture failure). Drives the UI's warning banner.
    public var hasCaptureProblem: Bool { !captureStatus.isEmpty }

    // MARK: - Start
    //
    // `startAsync` is the awaitable core (tests drive it directly). `start` is
    // the fire-and-forget wrapper the UI calls.

    /// Begin a meeting and its capture. Awaitable so tests can drive it.
    @discardableResult
    public func startAsync(title: String?, sources: Set<AudioSource> = [.mic, .system]) async -> Meeting {
        let meeting = engine.start(title: title)
        activeMeeting = meeting
        meetings = engine.recent

        do {
            let dir = RecordingsDirectory.forMeeting(meeting.id)
            let s = try await capture.start(sources: sources, directory: dir)
            self.session = s
            self.sessionMeetingID = meeting.id
        } catch {
            // Capture failed outright (e.g. no permission on any source).
            if let active = self.engine.active, active.id == meeting.id {
                // Nothing was recorded — fail the meeting so the user sees why.
                self.engine.fail(id: meeting.id)
                self.activeMeeting = self.engine.meeting(id: meeting.id)
                self.meetings = self.engine.recent
            }
        }
        // Always sync per-source status: a *partial* success (e.g. mic on, but
        // Screen Recording denied) throws nothing, yet the failed source's
        // error must still reach the UI. `capture.status` is empty when every
        // requested source started cleanly.
        self.captureStatus = self.capture.status
        // Persist the new meeting (recording, or failed if capture failed)
        // so it survives a relaunch.
        self.persist()
        return meeting
    }

    /// UI-facing: start a meeting (returns immediately; capture runs async).
    public func start(title: String?, sources: Set<AudioSource> = [.mic, .system]) {
        Task { _ = await self.startAsync(title: title, sources: sources) }
    }

    // MARK: - Stop
    //
    // `stopAsync` is the awaitable core; `stop` is the UI wrapper.

    /// Stop the active meeting, finalize its audio, and run the pipeline.
    public func stopAsync() async {
        guard let meeting = activeMeeting, meeting.status == .recording else { return }
        let id = meeting.id
        engine.stop(id: id)
        activeMeeting = engine.meeting(id: id)
        meetings = engine.recent

        // Stop the capture and record what it produced.
        if let s = self.session {
            do {
                let captured = try await s.stop()
                self.engine.setAudioFiles(id: id, files: captured.fileURLs)
            } catch {
                // Stop failed; the files may still exist. Keep them and let
                // the pipeline decide (it will fail and the user can retry).
            }
        }
        // Persist the stopped state + recorded audio file URLs before the
        // pipeline runs (which persists again on its success/failure).
        self.persist()
        self.session = nil
        self.sessionMeetingID = nil
        self.captureStatus = self.capture.status

        // Kick off the post-stop pipeline (transcribe → summarize → retention).
        await self.runPipeline(for: id)
    }

    /// UI-facing: stop the active meeting (returns immediately).
    public func stop() {
        Task { await self.stopAsync() }
    }

    // MARK: - Pipeline
    //
    // The post-stop pipeline. Runs the injected `MeetingProcessor`, then
    // records the result on the engine, applies retention (deletes the raw
    // audio + transcript per settings), and persists. On failure it keeps the
    // artifacts (so the user can retry) and surfaces the error.

    /// Run the pipeline for a specific meeting. Awaitable so tests drive it.
    @discardableResult
    public func runPipeline(for id: UUID) async -> Bool {
        guard let meeting = engine.meeting(id: id) else { return false }
        guard !processingIDs.contains(id) else { return false }
        processingIDs.insert(id)
        defer { processingIDs.remove(id) }

        processingError = nil
        processingProgress = ProcessingProgress(stage: .transcribing, fraction: 0)

        do {
            // Resolve the pipeline from the *current* settings when a factory
            // is wired (so Settings changes take effect without a relaunch),
            // falling back to the fixed processor otherwise.
            let active: any MeetingProcessor =
                processorFactory?(settings) ?? processor
            let result = try await active.process(
                meeting: meeting,
                audio: CapturedAudio(fileURLs: meeting.audioFileURLs),
                report: { [weak self] p in
                    Task { @MainActor in self?.processingProgress = p }
                }
            )

            // Record the transcript (so it's inspectable before summarizing),
            // then mark summarized (clearing it unless retention keeps it).
            engine.setTranscript(id: id, segments: result.segments)
            let policy = RetentionPolicy(settings: settings)
            engine.markSummarized(
                id: id,
                summary: result.summary,
                speakerCount: result.speakerCount,
                keepTranscript: policy.keepTranscript
            )

            // Retention side effect: delete the raw audio + transcript file per
            // settings. This is the product's core promise (keep only the
            // summary), made testable via the pure `RetentionPolicy` decision.
            let toDelete = policy.artifactsToDelete(for: meeting)
            for url in toDelete { try? FileManager.default.removeItem(at: url) }
            if !policy.keepAudio {
                engine.clearAudioFiles(id: id)
            }
            // The retention promise keeps only the summary: once the raw audio
            // and transcript file are deleted, the per-meeting directory is
            // empty and must not leak into the user's Application Support. If
            // the user opted to keep audio or the transcript, the directory
            // still holds those files and is left in place.
            let dir = RecordingsDirectory.forMeeting(id)
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ), contents.isEmpty {
                try? FileManager.default.removeItem(at: dir)
            }

            processingProgress = nil
            self.meetings = engine.recent
            self.activeMeeting = engine.active
            self.settingsStore?.save(settings)
            self.persist()
            // A headless (menu-bar) meeting just finished: tell the user the
            // summary is ready. Pure decision in MeetingNotificationPolicy; the
            // poster owns the platform call. No-op when the user disabled
            // notifications or no notifier is wired.
            self.notifyTerminal(id: id, errorDescription: nil)
            return true
        } catch {
            engine.fail(id: id)
            processingProgress = nil
            processingError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            self.meetings = engine.recent
            self.activeMeeting = engine.active
            self.persist()
            // The meeting failed — surface it so the user knows to retry, with
            // the reason when we have one.
            self.notifyTerminal(id: id, errorDescription: processingError)
            return false
        }
    }

    /// Post a notification for a meeting that just reached a terminal state
    /// (summarized or failed), if the user enabled notifications and a poster
    /// is wired. The *content* decision is pure (`MeetingNotificationPolicy`);
    /// this only performs the side effect (calling the injected poster).
    private func notifyTerminal(id: UUID, errorDescription: String?) {
        guard let meeting = engine.meeting(id: id),
              let note = MeetingNotificationPolicy.notification(
                  for: meeting, errorDescription: errorDescription, settings: settings
              ) else { return }
        notifier?(note)
    }

    /// Retry a failed meeting's pipeline.
    @discardableResult
    public func retry(id: UUID) async -> Bool {
        guard let m = engine.meeting(id: id), m.status == .failed else { return false }
        engine.retry(id: id)
        self.meetings = engine.recent
        self.activeMeeting = engine.active
        self.persist()
        return await runPipeline(for: id)
    }

    // MARK: - Settings

    /// Update a setting and persist it.
    public func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        settingsStore?.save(settings)
    }

    // MARK: - Live levels (driven by the UI's timer)

    public func refreshLevels() {
        guard isRecording else { return }
        levels[.mic] = capture.level(.mic)
        levels[.system] = capture.level(.system)
    }

    // MARK: - Persistence (Phase 5)

    public func delete(id: UUID) {
        if engine.delete(id: id) {
            meetings = engine.recent
            activeMeeting = engine.active
            persist()
        }
    }

    // MARK: - Level metering task (started once by the app)

    /// The live meter task. Stored so `startLevelMeter` is idempotent: calling
    /// it again (e.g. SwiftUI re-fires `onAppear`) cancels the old task first
    /// instead of stacking a second timer.
    private var meterTask: Task<Void, Never>?

    /// Drives `refreshLevels` on a timer while a meeting is recording.
    /// Idempotent — safe to call on every `onAppear`.
    public func startLevelMeter() {
        meterTask?.cancel()
        meterTask = Task {
            while !Task.isCancelled {
                refreshLevels()
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }
        }
    }

    /// Stop the live meter (e.g. when the window closes). No-op if not running.
    public func stopLevelMeter() {
        meterTask?.cancel()
        meterTask = nil
    }
}

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
    @Published public private(set) var isStarting = false
    @Published public private(set) var isStopping = false
    @Published public private(set) var toastMessage: String?
    private var toastTask: Task<Void, Never>?
    @Published public private(set) var levels: [AudioSource: Float] = [:]
    @Published public private(set) var captureStatus: [AudioSource: AudioCaptureError] = [:]
    /// The pipeline stage currently running (for the detail view's progress
    /// bar). nil when not processing.
    @Published public private(set) var processingProgress: ProcessingProgress?
    @Published public private(set) var progressByMeeting: [UUID: ProcessingProgress] = [:]
    /// A human-readable startup, storage, or processing error.
    @Published public private(set) var processingError: String?

    private let engine: MeetingEngine
    private let capture: AudioCapture
    private let artifacts: any MeetingArtifactManaging
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
    private var processingTasks: [UUID: Task<ProcessedResult, Error>] = [:]

    public init(
        engine: MeetingEngine = MeetingEngine(),
        capture: AudioCapture,
        processor: any MeetingProcessor = NoopProcessor(),
        settings: AppSettings = AppSettings(),
        settingsStore: SettingsStore? = nil,
        meetingStore: MeetingStore? = nil,
        startupError: String? = nil,
        processorFactory: ((AppSettings) -> any MeetingProcessor)? = nil,
        notifier: ((MeetingNotification) -> Void)? = nil,
        artifacts: any MeetingArtifactManaging = MeetingArtifacts()
    ) {
        self.engine = engine
        self.capture = capture
        self.artifacts = artifacts
        self.processor = processor
        self.processorFactory = processorFactory
        self.notifier = notifier
        self.settings = settings
        self.settingsStore = settingsStore
        self.meetingStore = meetingStore
        self.processingError = startupError
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
        // idempotent and safe — it only touches managed meeting dirs that aren't a
        // live meeting's (or are a live meeting's but already empty).
        self.sweepOrphanRecordings()
        // Resume a cleanup interrupted after the summary was safely saved.
        for meeting in engine.stored where meeting.summary != nil && !meeting.pendingArtifactDeletion.isEmpty {
            finishPendingRetention(meeting)
        }
        self.meetings = engine.recent
        self.activeMeeting = engine.active
    }

    /// Remove per-meeting recording directories that no longer correspond to a
    /// live meeting (or are empty leftovers). Pure decision lives in
    /// `RecordingsDirectory.orphanDirectories`; this performs the I/O. Returns
    /// the directories removed, so tests can assert the sweep's effect.
    @discardableResult
    public func sweepOrphanRecordings() -> [URL] {
        let liveIDs = Set(engine.stored.map(\.id))
        return artifacts.sweep(liveIDs: liveIDs)
    }

    // MARK: - Persistence

    /// Persist the engine's current collection to disk (a no-op when no store
    /// is wired). Called after every mutation that should survive a relaunch.
    @discardableResult
    private func persist() -> Bool {
        meetingStore?.save(engine.stored) ?? true
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
    public func startAsync(title: String?, sources: Set<AudioSource>? = nil) async -> Meeting {
        // Starting twice while a permission prompt is open must not orphan a session.
        if isStopping, let id = sessionMeetingID, let stopping = engine.meeting(id: id) { return stopping }
        if let activeMeeting, isRecording || isStarting { return activeMeeting }
        isStarting = true
        defer { isStarting = false }
        let sources = sources ?? settings.requestedSources
        let meeting = engine.start(title: title)
        activeMeeting = meeting
        meetings = engine.recent

        processingError = nil
        guard persist() else {
            processingError = "The meeting could not be saved. Check the data folder’s permissions before recording."
            engine.fail(id: meeting.id, reason: processingError)
            meetings = engine.recent
            activeMeeting = engine.active
            notifyTerminal(id: meeting.id, errorDescription: processingError)
            return meeting
        }
        do {
            guard !sources.isEmpty else {
                throw AudioCaptureError.sourceFailed(source: .mic, detail: "Choose at least one audio source in Settings → Audio.")
            }
            let dir = RecordingsDirectory.forMeeting(meeting)
            let s = try await capture.start(sources: sources, directory: dir)
            self.session = s
            self.sessionMeetingID = meeting.id
            self.engine.setAudioFiles(id: meeting.id, files: s.audio.fileURLs, startOffsets: s.audio.startOffsets)
        } catch {
            processingError = (error as? AudioCaptureError)?.description ?? error.localizedDescription
            // Capture failed outright (e.g. no permission on any source).
            if let active = self.engine.active, active.id == meeting.id {
                // Nothing was recorded — fail the meeting so the user sees why.
                self.engine.fail(id: meeting.id, reason: processingError)
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
        if engine.meeting(id: meeting.id)?.status == .failed {
            notifyTerminal(id: meeting.id, errorDescription: processingError)
        }
        return meeting
    }

    /// UI-facing: start a meeting (returns immediately; capture runs async).
    public func start(title: String?, sources: Set<AudioSource>? = nil) {
        Task { _ = await self.startAsync(title: title, sources: sources) }
    }

    // MARK: - Stop
    //
    // `stopAsync` is the awaitable core; `stop` is the UI wrapper.

    /// Stop the active meeting, finalize its audio, and run the pipeline.
    public func stopAsync() async {
        guard !isStarting, !isStopping, let meeting = activeMeeting, meeting.status == .recording else { return }
        isStopping = true
        let id = meeting.id
        engine.stop(id: id)
        activeMeeting = engine.meeting(id: id)
        meetings = engine.recent

        // Stop the capture and record what it produced.
        if let s = self.session {
            do {
                let captured = try await s.stop()
                self.engine.setAudioFiles(id: id, files: captured.fileURLs, startOffsets: captured.startOffsets)
            } catch {
                processingError = error.localizedDescription
                engine.fail(id: id, reason: processingError)
                session = nil
                sessionMeetingID = nil
                meetings = engine.recent
                activeMeeting = engine.active
                persist()
                isStopping = false
                return
            }
        }
        // Persist the stopped state + recorded audio file URLs before the
        // pipeline runs (which persists again on its success/failure).
        self.persist()
        self.session = nil
        self.sessionMeetingID = nil
        self.captureStatus = self.capture.status
        isStopping = false

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
    public func runPipeline(for id: UUID, reuseTranscript: Bool = true) async -> Bool {
        guard var meeting = engine.meeting(id: id),
              meeting.status == .processing || meeting.status == .failed else { return false }
        guard !processingIDs.contains(id) else { return false }
        // Keep the old checkpoint on disk until a fresh transcription succeeds.
        if !reuseTranscript { meeting.transcript = [] }
        processingIDs.insert(id)
        defer {
            processingIDs.remove(id)
            processingTasks[id] = nil
            progressByMeeting[id] = nil
        }

        processingError = nil
        processingProgress = ProcessingProgress(stage: .transcribing, fraction: 0)
        progressByMeeting[id] = processingProgress

        do {
            // Resolve the pipeline from the *current* settings when a factory
            // is wired (so Settings changes take effect without a relaunch),
            // falling back to the fixed processor otherwise.
            let active: any MeetingProcessor =
                processorFactory?(settings) ?? processor
            let report: @Sendable (ProcessingProgress) -> Void = { [weak self] p in
                Task { @MainActor in
                    guard let self, self.processingIDs.contains(id) else { return }
                    self.processingProgress = p
                    self.progressByMeeting[id] = p
                }
            }
            let task = Task {
                let audio = CapturedAudio(fileURLs: meeting.audioFileURLs, startOffsets: meeting.audioStartOffsets)
                if let checkpointing = active as? any TranscriptCheckpointingProcessor {
                    return try await checkpointing.process(
                        meeting: meeting, audio: audio, report: report,
                        checkpoint: { [weak self] segments in
                            try await self?.retainTranscriptCheckpoint(id: id, segments: segments)
                        }
                    )
                }
                return try await active.process(meeting: meeting, audio: audio, report: report)
            }
            processingTasks[id] = task
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard !task.isCancelled else { throw CancellationError() }

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

            let toDelete = policy.artifactsToDelete(for: meeting)
            engine.scheduleArtifactDeletion(id: id, urls: toDelete)
            // The summary must be durable before any source audio is destroyed.
            guard persist() else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey:
                    "The summary could not be saved. Audio was kept; check your data folder and retry."])
            }

            // Retention side effect: delete the raw audio + transcript file per
            // settings. This is the product's core promise (keep only the
            // summary), made testable via the pure `RetentionPolicy` decision.
            try artifacts.remove(toDelete)
            // The retention promise keeps only the summary: once the raw audio
            // and transcript file are deleted, the per-meeting directory is
            // empty and must not leak into the user's Application Support. If
            // the user opted to keep audio or the transcript, the directory
            // still holds those files and is left in place.
            try artifacts.removeEmptyDirectory(for: id)
            engine.completeArtifactDeletion(id: id)

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
            processingProgress = nil
            processingError = error is CancellationError
                ? "Processing was cancelled. Audio was kept; retry when you’re ready."
                : (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            engine.fail(id: id, reason: processingError)
            self.meetings = engine.recent
            self.activeMeeting = engine.active
            self.persist()
            // The meeting failed — surface it so the user knows to retry, with
            // the reason when we have one.
            self.notifyTerminal(id: id, errorDescription: processingError)
            return false
        }
    }

    private func retainTranscriptCheckpoint(id: UUID, segments: [TranscriptSegment]) throws {
        guard settings.keepTranscriptAfterSummary else { return }
        guard processingIDs.contains(id), engine.meeting(id: id) != nil else { throw CancellationError() }
        engine.setTranscript(id: id, segments: segments)
        meetings = engine.recent
        guard persist() else {
            throw LLMError("The transcript could not be saved. Audio was kept; check your data folder and retry.")
        }
    }

    /// Post a notification for a meeting that just reached a terminal state
    /// (summarized or failed), if the user enabled notifications and a poster
    /// is wired. The *content* decision is pure (`MeetingNotificationPolicy`);
    /// this only performs the side effect (calling the injected poster).
    private func notifyTerminal(id: UUID, errorDescription: String?) {
        if let meeting = engine.meeting(id: id) {
            showToast(meeting.status == .summarized ? "Summary ready: \(meeting.title)" : "Meeting failed: \(meeting.title)")
        }
        guard let meeting = engine.meeting(id: id),
              let note = MeetingNotificationPolicy.notification(
                  for: meeting, errorDescription: errorDescription, settings: settings
              ) else { return }
        notifier?(note)
    }

    private func showToast(_ message: String) {
        guard settings.showToasts else { return }
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 4_000_000_000) }
            catch { return }
            self?.toastMessage = nil
        }
    }

    /// Cleanup retries use the already-saved summary instead of charging for
    /// another transcription/summary call. The stored URL list also respects
    /// the retention choices that were in effect when the summary was saved.
    @discardableResult
    private func finishPendingRetention(_ meeting: Meeting) -> Bool {
        guard let summary = meeting.summary else { return false }
        // A prior save may have failed in this same process. Retry must make
        // the in-memory summary durable too, before removing its source audio.
        guard persist() else {
            processingError = "The summary still could not be saved. Audio was kept; check the data folder and retry."
            engine.fail(id: meeting.id, reason: processingError)
            meetings = engine.recent
            return false
        }
        do {
            try artifacts.remove(meeting.pendingArtifactDeletion)
            try artifacts.removeEmptyDirectory(for: meeting.id)
            engine.completeArtifactDeletion(id: meeting.id)
            engine.markSummarized(id: meeting.id, summary: summary, speakerCount: meeting.speakerCount,
                                  keepTranscript: !meeting.transcript.isEmpty)
            persist()
            processingError = nil
            meetings = engine.recent
            return true
        } catch {
            processingError = "Audio cleanup could not finish: \(error.localizedDescription)"
            engine.fail(id: meeting.id, reason: processingError)
            persist()
            meetings = engine.recent
            return false
        }
    }

    /// Stop a pipeline without discarding its original recording.
    public func cancelProcessing(id: UUID) {
        processingTasks[id]?.cancel()
    }

    /// Retry a failed meeting's pipeline.
    @discardableResult
    public func retry(id: UUID, reuseTranscript: Bool = true) async -> Bool {
        guard let m = engine.meeting(id: id), m.status == .failed else { return false }
        if m.summary != nil && !m.pendingArtifactDeletion.isEmpty { return finishPendingRetention(m) }
        engine.retry(id: id)
        self.meetings = engine.recent
        self.activeMeeting = engine.active
        self.persist()
        return await runPipeline(for: id, reuseTranscript: reuseTranscript)
    }

    // MARK: - Settings

    /// Update a setting and persist it.
    public func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        let previousTranscription = settings.transcriptionBackend
        let previousBackend = settings.summaryBackend
        let previousModel = settings.summaryModel
        mutate(&settings)
        if previousTranscription != settings.transcriptionBackend && settings.transcriptionBackend == .whisper,
           !WhisperCatalog.selectable.contains(where: { $0.id == settings.whisperModel }) {
            settings.whisperModel = WhisperCatalog.defaultID
        }
        if previousBackend != settings.summaryBackend && previousModel == settings.summaryModel {
            settings.summaryModel = AppSettings.defaultSummaryModel(for: settings.summaryBackend)
        }
        if !settings.showToasts { toastTask?.cancel(); toastMessage = nil }
        settingsStore?.save(settings)
    }

    // MARK: - Live levels (driven by the UI's timer)

    public func refreshLevels() {
        guard isRecording else { return }
        captureStatus = capture.status
        levels[.mic] = capture.level(.mic)
        levels[.system] = capture.level(.system)
    }

    // MARK: - Persistence (Phase 5)

    public func delete(id: UUID) {
        guard let meeting = engine.meeting(id: id),
              meeting.status != .recording, meeting.status != .processing,
              !processingIDs.contains(id) else { return }
        do { try artifacts.discard(meeting) }
        catch {
            processingError = "Could not delete this meeting’s files: \(error.localizedDescription)"
            return
        }
        let remaining = engine.stored.filter { $0.id != id }
        guard meetingStore?.save(remaining, sanitizeBackup: true) ?? true else {
            processingError = "The meeting’s files were deleted, but history could not be saved. Check the data folder’s permissions, then retry Delete."
            return
        }
        if engine.delete(id: id) {
            processingError = nil
            showToast("Meeting deleted")
            meetings = engine.recent
            activeMeeting = engine.active
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

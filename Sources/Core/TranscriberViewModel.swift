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

    private let engine: MeetingEngine
    private let capture: AudioCapture
    private var session: AudioCaptureSession?
    /// The meeting id whose capture session is in flight (so a stray stop
    /// can't be misrouted to the wrong meeting).
    private var sessionMeetingID: UUID?

    /// `process` runs the post-stop pipeline (transcribe → summarize → delete
    /// audio). Injected so tests can stub it and the app can supply the real
    /// one. Defaults to a no-op until Phase 3.
    private let process: (Meeting) async -> Void

    public init(
        engine: MeetingEngine = MeetingEngine(),
        capture: AudioCapture,
        process: @escaping (Meeting) async -> Void = { _ in }
    ) {
        self.engine = engine
        self.capture = capture
        self.process = process
        self.meetings = engine.recent
        self.activeMeeting = engine.active
    }

    // MARK: - Derived

    public var isRecording: Bool { activeMeeting?.status == .recording }

    public func meeting(id: UUID) -> Meeting? { engine.meeting(id: id) }

    public func search(_ query: String) -> [Meeting] { engine.search(query) }

    public func level(_ source: AudioSource) -> Float { levels[source] ?? 0 }

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
            self.captureStatus = capture.status
            if let active = self.engine.active, active.id == meeting.id {
                // Nothing was recorded — fail the meeting so the user sees why.
                self.engine.fail(id: meeting.id)
                self.activeMeeting = self.engine.meeting(id: meeting.id)
                self.meetings = self.engine.recent
            }
        }
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
        self.session = nil
        self.sessionMeetingID = nil
        self.captureStatus = self.capture.status

        // Kick off the post-stop pipeline.
        if let m = self.engine.meeting(id: id) {
            await self.process(m)
        }
    }

    /// UI-facing: stop the active meeting (returns immediately).
    public func stop() {
        Task { await self.stopAsync() }
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
        }
    }

    // MARK: - Level metering task (started once by the app)

    /// Drives `refreshLevels` on a timer while a meeting is recording.
    public func startLevelMeter() {
        Task {
            while !Task.isCancelled {
                refreshLevels()
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }
        }
    }
}

import Foundation

#if canImport(TranscriberCore)
import TranscriberCore
#endif

// Lightweight assertion harness. Compiles the Core sources + this file into a
// single executable (no XCTest runner needed), so `swiftc ... && ./tests` works
// without SwiftPM or Xcode.
//
// NOTE: top-level code is a single scope, so every local must be uniquely
// named across the whole file (same convention as the base repo's tests).

private var passed = 0
private var failed = 0
private var currentSection = ""

private func section(_ name: String) {
    currentSection = name
    print("\n\(name)")
}

private func check(_ cond: Bool, _ label: String, _ file: String = #file, _ line: Int = #line) {
    if cond {
        passed += 1
        print("  ✓ \(label)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(label)  (\(file.split(separator: "/").last!.description):\(line))")
    }
}

// A clock we can advance by hand so assertions are exact (no sleeps).
// Thread-safe (lock-guarded) so it satisfies `Clock: Sendable`.
final class ManualClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date
    init(instant: Date) { self.instant = instant }
    func now() -> Date { lock.withLock { self.instant } }
    func advance(_ s: TimeInterval) { lock.withLock { self.instant = self.instant.addingTimeInterval(s) } }
}

let t0 = Date(timeIntervalSince1970: 0)
var clock = ManualClock(instant: t0)
var engine = MeetingEngine(clock: clock)

func reset() {
    clock = ManualClock(instant: t0)
    engine = MeetingEngine(clock: clock)
}

// A `MeetingProcessor` for tests: returns a fixed result and (optionally) lets
// the test observe that the pipeline ran. Lets us assert the VM drives the
// pipeline + retention without any real transcription.
final class FakeProcessor: MeetingProcessor, @unchecked Sendable {
    let result: ProcessedResult
    var shouldThrow: Error?
    let onRun: ((Meeting) -> Void)?
    private let lock = NSLock()
    private var _runs = 0
    var runs: Int { lock.lock(); defer { lock.unlock() }; return _runs }

    init(
        result: ProcessedResult = ProcessedResult(
            segments: [
                TranscriptSegment(speaker: "Speaker 1", text: "hello", startOffset: 0, endOffset: 1),
                TranscriptSegment(speaker: "Speaker 2", text: "world", startOffset: 2, endOffset: 3),
            ],
            summary: MeetingSummary(overall: "A test summary.", keyPoints: ["kp1"])
        ),
        shouldThrow: Error? = nil,
        onRun: ((Meeting) -> Void)? = nil
    ) {
        self.result = result
        self.shouldThrow = shouldThrow
        self.onRun = onRun
    }

    func process(meeting: Meeting, audio: CapturedAudio, report: @Sendable (ProcessingProgress) -> Void) async throws -> ProcessedResult {
        lock.lock(); _runs += 1; lock.unlock()
        onRun?(meeting)
        if let e = shouldThrow { throw e }
        report(ProcessingProgress(stage: .summarizing, fraction: 1))
        return result
    }
}

// MARK: - Start / stop
section("start/stop")
reset()
let startMeet = engine.start(title: "All Hands")
check(engine.all.count == 1, "start creates one meeting")
check(startMeet.status == .recording, "new meeting is recording")
check(engine.active?.id == startMeet.id, "active points at the new meeting")

clock.advance(120)
engine.stop(id: startMeet.id)
let afterStop = engine.meeting(id: startMeet.id)!
check(afterStop.status == .processing, "stop moves meeting to processing")
check(afterStop.stoppedAt == clock.now(), "stoppedAt set to the clock")
check(afterStop.duration == 120, "duration is 120s")
check(engine.active == nil, "no active meeting after stop")

// MARK: - Only one active
section("single-active invariant")
reset()
let firstMeet = engine.start(title: "A")
clock.advance(10)
let secondMeet = engine.start(title: "B")
check(engine.all.count == 2, "two meetings exist")
check(engine.active?.id == secondMeet.id, "second start is the active one")
check(engine.meeting(id: firstMeet.id)!.status == .processing, "first meeting was stopped")
check(engine.meeting(id: firstMeet.id)!.duration == 10, "first meeting recorded 10s")

// MARK: - Title defaulting
section("title defaulting")
reset()
let blankTitle = engine.start(title: "   ")
check(!blankTitle.title.isEmpty, "blank title is replaced")
let nilTitle = engine.start(title: nil)
check(!nilTitle.title.isEmpty, "nil title is replaced")

// MARK: - Summarize clears transcript
section("summarize")
reset()
let sumMeet = engine.start(title: "1:1")
clock.advance(300)
engine.stop(id: sumMeet.id)
engine.markSummarized(
    id: sumMeet.id,
    summary: MeetingSummary(overall: "Discussed roadmap.", keyPoints: ["Ship v1"], decisions: ["Go"], actionItems: ["Write docs"]),
    speakerCount: 2
)
let sumResult = engine.meeting(id: sumMeet.id)!
check(sumResult.status == .summarized, "meeting is summarized")
check(sumResult.summary?.overall == "Discussed roadmap.", "summary stored")
check(sumResult.transcript.isEmpty, "transcript cleared after summary")
check(sumResult.speakerCount == 2, "speaker count recorded")

// MARK: - Fail + retry
section("fail/retry")
reset()
let failMeet = engine.start(title: "Sync")
engine.stop(id: failMeet.id)
engine.fail(id: failMeet.id)
check(engine.meeting(id: failMeet.id)!.status == .failed, "failed")
engine.retry(id: failMeet.id)
check(engine.meeting(id: failMeet.id)!.status == .processing, "retry back to processing")

// MARK: - Search
section("search")
reset()
let searchA = engine.start(title: "Design Review")
let searchB = engine.start(title: "Q3 Planning")
clock.advance(60)
engine.stop(id: searchB.id)
engine.markSummarized(id: searchB.id, summary: MeetingSummary(overall: "Planned the quarter."), speakerCount: 1)
check(engine.search("design").map { $0.id } == [searchA.id], "search by title")
check(engine.search("quarter").map { $0.id } == [searchB.id], "search by summary text")
check(engine.search("zzz").isEmpty, "no match returns empty")
check(engine.search("").count == 2, "empty query returns all")

// MARK: - Recent ordering
section("recent ordering")
reset()
let recentOld = engine.start(title: "Old")
clock.advance(60)
engine.stop(id: recentOld.id)
let recentNew = engine.start(title: "New")
check(engine.recent.first?.id == recentNew.id, "active pinned to top")
clock.advance(30)
engine.stop(id: recentNew.id)
check(engine.recent.first?.id == recentNew.id, "most recent first when none active")

// MARK: - Delete
section("delete")
reset()
let delMeet = engine.start(title: "Toss")
check(engine.delete(id: delMeet.id) == true, "delete returns true")
check(engine.all.isEmpty, "meeting removed")
check(engine.delete(id: delMeet.id) == false, "delete of missing returns false")

// MARK: - Codable round-trip (forward-compatible decoding)
section("codable")
reset()
let codeMeet = engine.start(title: "Encode me")
engine.stop(id: codeMeet.id)
let codeData = try! JSONEncoder().encode(engine.meeting(id: codeMeet.id)!)
let codeBack = try! JSONDecoder().decode(Meeting.self, from: codeData)
check(codeBack == engine.meeting(id: codeMeet.id), "meeting round-trips through Codable")

// MARK: - Phase 1: fake capture writes valid audio
section("capture: fake writes readable audio")
import AVFoundation
let capDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("transcriber-test-\(UUID().uuidString)", isDirectory: true)
do {
    try FileManager.default.createDirectory(at: capDir, withIntermediateDirectories: true)
    let cap = RecordingAudioCapture(directory: capDir)
    let session = try await cap.start(sources: [.mic, .system], directory: capDir)
    let captured = try await session.stop()
    check(captured.fileURLs.count == 2, "fake produced two files (mic + system)")
    for source in [AudioSource.mic, AudioSource.system] {
        guard let url = captured.fileURLs[source] else {
            check(false, "file exists for \(source)")
            continue
        }
        check(FileManager.default.fileExists(atPath: url.path), "file on disk: \(url.lastPathComponent)")
        do {
            let af = try AVAudioFile(forReading: url)
            check(af.length > 0, "\(url.lastPathComponent) is readable (\(af.length) frames)")
            check(af.processingFormat.channelCount >= 1, "\(url.lastPathComponent) has channels")
        } catch {
            check(false, "\(url.lastPathComponent) readable: \(error)")
        }
    }
} catch {
    check(false, "fake capture start/stop: \(error)")
}
try? FileManager.default.removeItem(at: capDir)

// MARK: - Phase 1: view model drives capture
section("view model: start/stop drives capture")
RecordingsDirectory.baseDirectory = {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("transcriber-vm-\(UUID().uuidString)", isDirectory: true)
}
do {
    let vmCapDir = RecordingsDirectory.base()
    let vmEngine = MeetingEngine(clock: clock)
    let vmCap = RecordingAudioCapture(directory: vmCapDir)
    let vmFake = FakeProcessor()
    let vm = TranscriberViewModel(engine: vmEngine, capture: vmCap, processor: vmFake)

    let m = await vm.startAsync(title: "VM Meeting")
    check(vm.isRecording, "VM reports recording after start")
    check(vmEngine.active?.id == m.id, "engine has the active meeting")

    await vm.stopAsync()
    check(vmEngine.meeting(id: m.id)!.status == .summarized, "meeting is summarized after stop (pipeline ran)")
    check(vmFake.runs == 1, "process pipeline was invoked")
    check(vmEngine.meeting(id: m.id)!.summary?.overall == "A test summary.", "summary recorded on the meeting")
    check(vmEngine.meeting(id: m.id)!.speakerCount == 2, "speaker count recorded (2)")
    // Retention (default: keep only the summary): transcript cleared + audio files deleted.
    check(vmEngine.meeting(id: m.id)!.transcript.isEmpty, "transcript cleared by retention (default)")
    check(vmEngine.meeting(id: m.id)!.audioFileURLs.isEmpty, "audio file URLs cleared by retention (default)")
} catch {
    check(false, "VM start/stop: \(error)")
}
RecordingsDirectory.baseDirectory = nil
try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
    .appendingPathComponent("transcriber-vm-\(UUID().uuidString)", isDirectory: true))

// MARK: - Phase 5: persistence (the summary is the durable artifact)
section("persistence: engine.load hydrates + reconciles mid-flight")
do {
    let rec = Meeting(title: "Was recording", status: .recording,
        startedAt: t0, createdAt: t0, lastActivityAt: t0)
    let proc = Meeting(title: "Was processing", status: .processing,
        startedAt: t0, createdAt: t0, lastActivityAt: t0)
    let summ = Meeting(title: "Done", status: .summarized,
        startedAt: t0, createdAt: t0, lastActivityAt: t0,
        summary: MeetingSummary(overall: "Kept."))
    let faild = Meeting(title: "Broke", status: .failed,
        startedAt: t0, createdAt: t0, lastActivityAt: t0)

    let e = MeetingEngine(clock: clock)
    e.load([rec, proc, summ, faild])
    check(e.meeting(id: rec.id)!.status == .failed, "recording reconciled to failed (retryable)")
    check(e.meeting(id: proc.id)!.status == .failed, "processing reconciled to failed (retryable)")
    check(e.meeting(id: summ.id)!.status == .summarized, "summarized loads untouched")
    check(e.meeting(id: summ.id)!.summary?.overall == "Kept.", "summary survives hydration")
    check(e.meeting(id: faild.id)!.status == .failed, "failed loads untouched")
    check(e.stored.count == 4, "all four hydrated")
}

section("persistence: MeetingStore round-trips to a real file")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcriber-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("meetings.json")
    defer { try? FileManager.default.removeItem(at: dir) }

    let m1 = Meeting(title: "Alpha", status: .summarized,
        startedAt: t0, createdAt: t0, lastActivityAt: t0,
        summary: MeetingSummary(overall: "One", keyPoints: ["a"]))
    let m2 = Meeting(title: "Beta", status: .summarized,
        startedAt: t0, createdAt: t0, lastActivityAt: t0,
        summary: MeetingSummary(overall: "Two"))

    let store = MeetingStore(url: file)
    store.save([m1, m2])
    check(FileManager.default.fileExists(atPath: file.path), "save wrote meetings.json")

    let fresh = MeetingStore(url: file)
    let loaded = fresh.load()
    check(loaded.count == 2, "load returns two meetings")
    check(loaded[0].id == m1.id && loaded[1].id == m2.id, "order preserved")
    check(loaded[0].summary?.overall == "One", "summary content survives")
    check(loaded[1].summary?.keyPoints.isEmpty == true, "empty keyPoints survive (not dropped)")

    // Backup rotation: saving a second version keeps the first in .bak, so an
    // irreplaceable summary is recoverable even if the live file is lost.
    let m1v2 = Meeting(title: "Alpha v2", status: .summarized,
        startedAt: t0, createdAt: t0, lastActivityAt: t0,
        summary: MeetingSummary(overall: "One, revised."))
    store.save([m1v2])
    let bak = file.appendingPathExtension("bak")
    check(FileManager.default.fileExists(atPath: bak.path), "save rotated the previous file to .bak")
    let bakData = try? Data(contentsOf: bak)
    let bakMeetings = (try? JSONDecoder().decode([Meeting].self, from: bakData ?? Data())) ?? []
    check(bakMeetings.count == 2 && bakMeetings[0].summary?.overall == "One",
        ".bak holds the prior generation (recoverable)")
    check(MeetingStore(url: file).load()[0].summary?.overall == "One, revised.",
        "live file has the newest generation")
}

section("persistence: MeetingStore is lenient on missing/corrupt files")
do {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcriber-missing-\(UUID().uuidString).json")
    check(!FileManager.default.fileExists(atPath: missing.path), "precondition: file absent")
    check(MeetingStore(url: missing).load().isEmpty, "missing file loads as empty (fresh app)")

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcriber-corrupt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("meetings.json")
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("this is not valid json {".utf8).write(to: file)
    check(MeetingStore(url: file).load().isEmpty, "corrupt file loads as empty (no crash)")
}

section("persistence: a summarized meeting survives a relaunch (end-to-end)")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcriber-e2e-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("meetings.json")
    defer { try? FileManager.default.removeItem(at: dir) }

    // Session 1: run a meeting through the pipeline and persist it.
    let e1 = MeetingEngine(clock: clock)
    let store1 = MeetingStore(url: file)
    let vm1 = TranscriberViewModel(
        engine: e1,
        capture: RecordingAudioCapture(directory: dir),
        processor: FakeProcessor(),
        meetingStore: store1
    )
    let m = await vm1.startAsync(title: "Durable")
    await vm1.stopAsync()
    check(e1.meeting(id: m.id)!.status == .summarized, "session 1: meeting summarized")
    check(FileManager.default.fileExists(atPath: file.path), "session 1: meetings.json written")

    // Session 2: a brand-new engine + VM hydrates from the same file.
    let e2 = MeetingEngine(clock: clock)
    let vm2 = TranscriberViewModel(
        engine: e2,
        capture: RecordingAudioCapture(directory: dir),
        processor: FakeProcessor(),
        meetingStore: MeetingStore(url: file)
    )
    check(vm2.meetings.count == 1, "session 2: one meeting loaded")
    check(vm2.meeting(id: m.id)!.status == .summarized, "session 2: still summarized")
    check(vm2.meeting(id: m.id)!.summary?.overall == "A test summary.",
        "session 2: the summary text survived the relaunch")
}

section("persistence: a failed meeting persists and is retryable after relaunch")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcriber-retry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("meetings.json")
    defer { try? FileManager.default.removeItem(at: dir) }

    // Session 1: the pipeline throws → the meeting is failed and persisted.
    let throwing = FakeProcessor(shouldThrow: ModelError.notFound("whisper-base"))
    let e1 = MeetingEngine(clock: clock)
    let vm1 = TranscriberViewModel(
        engine: e1,
        capture: RecordingAudioCapture(directory: dir),
        processor: throwing,
        meetingStore: MeetingStore(url: file)
    )
    let m = await vm1.startAsync(title: "Will fail")
    await vm1.stopAsync()
    check(e1.meeting(id: m.id)!.status == .failed, "session 1: meeting failed (pipeline threw)")

    // Session 2: the failed meeting loads and the user can retry it.
    let e2 = MeetingEngine(clock: clock)
    let vm2 = TranscriberViewModel(
        engine: e2,
        capture: RecordingAudioCapture(directory: dir),
        processor: FakeProcessor(),
        meetingStore: MeetingStore(url: file)
    )
    check(vm2.meeting(id: m.id)!.status == .failed, "session 2: failed meeting loaded")
    let retried = await vm2.retry(id: m.id)
    check(retried, "session 2: retry succeeds with a working processor")
    check(e2.meeting(id: m.id)!.status == .summarized, "session 2: now summarized after retry")
}

section("persistence: in-memory store seeds a fresh engine (test seam)")
do {
    let seed = Meeting(title: "Seeded", status: .summarized,
        startedAt: t0, createdAt: t0, lastActivityAt: t0,
        summary: MeetingSummary(overall: "Pre-existing."))
    let e = MeetingEngine(clock: clock)
    let vm = TranscriberViewModel(
        engine: e,
        capture: RecordingAudioCapture(directory: FileManager.default.temporaryDirectory),
        processor: FakeProcessor(),
        meetingStore: MeetingStore.inMemory(initial: [seed])
    )
    check(vm.meetings.count == 1, "in-memory seed hydrates the engine")
    check(vm.meeting(id: seed.id)!.summary?.overall == "Pre-existing.", "seeded summary is visible")
}

// MARK: - Phase 3: error descriptions are actionable
section("capture: error descriptions")
check(AudioCaptureError.microphoneNotAuthorized.description.contains("Microphone"),
      "mic error names the microphone")
check(AudioCaptureError.microphoneNotAuthorized.description.contains("Privacy & Security"),
      "mic error points at the setting")
check(AudioCaptureError.screenRecordingNotAuthorized.description.contains("Screen Recording"),
      "system error names Screen Recording")
check(AudioCaptureError.noDisplayAvailable.description.contains("display"),
      "no-display error mentions display")
check(AudioCaptureError.sourceFailed(source: .mic, detail: "boom").description.contains("boom"),
      "sourceFailed carries the detail")
check(AudioCaptureError.sourceFailed(source: .system, detail: "x").description.contains("System audio"),
      "sourceFailed names the source")

// MARK: - Phase 3: partial failure surfaces status without throwing
//
// A capture whose system source fails but whose mic succeeds. `start` must
// NOT throw (the meeting still records the mic), yet the failed source's
// error must reach the UI via `captureStatus` / `captureStatusMessages`.
final class PartialFailureCapture: AudioCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: [AudioSource: AudioCaptureError] = [:]
    private var _captured: [AudioSource: URL] = [:]
    var status: [AudioSource: AudioCaptureError] { lock.lock(); defer { lock.unlock() }; return _status }
    var capturedFiles: [AudioSource: URL] { lock.lock(); defer { lock.unlock() }; return _captured }
    func recordCaptured(_ urls: [AudioSource: URL]) { lock.lock(); _captured = urls; lock.unlock() }
    func level(_ source: AudioSource) -> Float { 0.5 }
    func start(sources: Set<AudioSource>, directory: URL) async throws -> AudioCaptureSession {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if sources.contains(.system) {
            lock.lock(); _status[.system] = .screenRecordingNotAuthorized; lock.unlock()
        }
        return PartialSession(capture: self, directory: directory, sources: sources)
    }
}

final class PartialSession: AudioCaptureSession, @unchecked Sendable {
    private let capture: PartialFailureCapture
    private let directory: URL
    private let sources: Set<AudioSource>
    private var stopped = false
    init(capture: PartialFailureCapture, directory: URL, sources: Set<AudioSource>) {
        self.capture = capture
        self.directory = directory
        self.sources = sources
    }
    func stop() async throws -> CapturedAudio {
        if stopped { return CapturedAudio() }
        stopped = true
        var urls: [AudioSource: URL] = [:]
        for source in sources where source == .mic {
            let url = directory.appendingPathComponent("mic.wav")
            try Data().write(to: url)
            urls[.mic] = url
        }
        capture.recordCaptured(urls)
        return CapturedAudio(fileURLs: urls)
    }
}

section("view model: partial failure surfaces status")
RecordingsDirectory.baseDirectory = {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("transcriber-partial-\(UUID().uuidString)", isDirectory: true)
}
do {
    let pEngine = MeetingEngine(clock: clock)
    let pCap = PartialFailureCapture()
    let pFake = FakeProcessor()
    let pvm = TranscriberViewModel(engine: pEngine, capture: pCap, processor: pFake)

    let pm = await pvm.startAsync(title: "Partial")
    // Mic succeeded, so the meeting is still recording (not failed).
    check(pvm.isRecording, "partial failure keeps the meeting recording")
    check(pEngine.meeting(id: pm.id)!.status == .recording, "meeting not failed on partial loss")
    // But the failed source's error is surfaced.
    check(pvm.hasCaptureProblem, "hasCaptureProblem is true")
    check(pvm.captureStatus[.system] == .screenRecordingNotAuthorized, "system error recorded")
    check(pvm.captureStatus[.mic] == nil, "mic has no error")
    check(pvm.captureStatusMessages.count == 1, "one status message (only the failed source)")
    check(pvm.captureStatusMessages.first!.contains("Screen Recording"), "message names the fix")

    // Stopping finalizes the mic file, then runs the pipeline (summarizes).
    await pvm.stopAsync()
    check(pEngine.meeting(id: pm.id)!.status == .summarized, "pipeline still ran on stop (mic file present)")
    check(pFake.runs == 1, "pipeline invoked once despite partial capture loss")
    check(pEngine.meeting(id: pm.id)!.audioFileURLs.isEmpty, "audio cleared by retention after summarizing")
    check(pCap.capturedFiles[.mic] != nil, "capture recorded the mic file before retention deleted it")
} catch {
    check(false, "partial-failure VM: \(error)")
}
RecordingsDirectory.baseDirectory = nil

// MARK: - Phase 4: pipeline composition
section("pipeline: transcribe → diarize → summarize")
final class StubTranscriber: Transcriber {
    let segs: [TranscriptSegment]
    init(segs: [TranscriptSegment]) { self.segs = segs }
    func transcribe(audio: CapturedAudio, language: String) async throws -> [TranscriptSegment] { segs }
}
final class StubSummarizer: Summarizer {
    func summarize(segments: [TranscriptSegment], title: String) async throws -> MeetingSummary {
        MeetingSummary(overall: "sum of \(segments.count) segs", keyPoints: ["kp"])
    }
}
do {
    let rawSegs = [
        TranscriptSegment(speaker: "?", text: "a", startOffset: 0, endOffset: 1),
        TranscriptSegment(speaker: "?", text: "b", startOffset: 3, endOffset: 4),
    ]
    let p4 = PipelineProcessor(
        transcriber: StubTranscriber(segs: rawSegs),
        diarizer: HeuristicDiarizer(gapThreshold: 1.5),
        summarizer: StubSummarizer(),
        language: "en"
    )
    var lastProgress = ProcessingProgress(stage: .transcribing, fraction: 0)
    let p4result = try await p4.process(meeting: Meeting(title: "P4", startedAt: t0, createdAt: t0, lastActivityAt: t0), audio: CapturedAudio(), report: { lastProgress = $0 })
    check(p4result.summary.overall == "sum of 2 segs", "summarizer ran on diarized segments")
    check(p4result.segments[0].speaker == "Speaker 1", "diarizer labeled first segment")
    check(p4result.segments[1].speaker == "Speaker 2", "diarizer labeled second segment (gap)")
    check(lastProgress.stage == .summarizing, "progress reached the summarizing stage")
} catch {
    check(false, "pipeline composition: \(error)")
}

// MARK: - Phase 4: heuristic diarizer
section("diarizer: heuristic speaker splitting")
do {
    let d = HeuristicDiarizer(gapThreshold: 1.0)
    let noGap = [
        TranscriptSegment(speaker: "?", text: "a", startOffset: 0, endOffset: 0.5),
        TranscriptSegment(speaker: "?", text: "b", startOffset: 0.6, endOffset: 1.0),
    ]
    let noGapOut = try await d.diarize(noGap)
    check(noGapOut[0].speaker == "Speaker 1" && noGapOut[1].speaker == "Speaker 1", "no gap → same speaker")

    let withGap = [
        TranscriptSegment(speaker: "?", text: "a", startOffset: 0, endOffset: 0.5),
        TranscriptSegment(speaker: "?", text: "b", startOffset: 5.0, endOffset: 5.5),
    ]
    let withGapOut = try await d.diarize(withGap)
    check(withGapOut[0].speaker == "Speaker 1" && withGapOut[1].speaker == "Speaker 2", "gap → new speaker")

    let emptyOut = try await d.diarize([])
    check(emptyOut.isEmpty, "empty input → empty output")

    let idOut = try await IdentityDiarizer().diarize([TranscriptSegment(speaker: "Alice", text: "x")])
    check(idOut[0].speaker == "Alice", "identity diarizer preserves labels")
} catch {
    check(false, "diarizer: \(error)")
}

// MARK: - Phase 4: summary parser
section("summary: lenient JSON parser")
do {
    let clean = Summary.parse(#"{"overall":"did things","key_points":["kp1","kp2"],"decisions":["d1"],"action_items":["a1"]}"#)
    check(clean.overall == "did things", "parses overall")
    check(clean.keyPoints.count == 2, "parses key_points")
    check(clean.decisions == ["d1"], "parses decisions")
    check(clean.actionItems == ["a1"], "parses action_items")

    let fenced = Summary.parse("```json\n{\"overall\":\"fenced\"}\n```")
    check(fenced.overall == "fenced", "parses a fenced JSON block")

    let prose = Summary.parse("Here is the summary:\n{\"overall\":\"prose\",\"key_points\":[]}")
    check(prose.overall == "prose", "parses JSON embedded in prose")

    let camel = Summary.parse(#"{"overall":"c","keyPoints":["k"],"actionItems":["a"]}"#)
    check(camel.keyPoints == ["k"] && camel.actionItems == ["a"], "tolerates camelCase keys")

    let fallback = Summary.parse("plain text summary, no json")
    check(fallback.overall == "plain text summary, no json", "falls back to raw text when no JSON")

    let text = Summary.transcriptText([
        TranscriptSegment(speaker: "S1", text: "hi"),
        TranscriptSegment(speaker: "S2", text: "yo"),
    ])
    check(text == "S1: hi\nS2: yo", "transcriptText formats speaker: text")

    let prompt = Summary.prompt(title: "T", transcript: "x")
    check(prompt.contains("JSON object") && prompt.contains("T"), "prompt asks for JSON + includes title")
} catch {
    check(false, "summary parser: \(error)")
}

// MARK: - Phase 4: retention policy
section("retention: delete audio + transcript, keep summary")
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("transcriber-ret-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let micFile = dir.appendingPathComponent("mic.wav")
    try Data().write(to: micFile)

    let meeting = Meeting(
        title: "Ret", startedAt: t0, createdAt: t0, lastActivityAt: t0,
        audioFileURLs: [.mic: micFile, .system: dir.appendingPathComponent("sys.wav")]
    )

    // Default: keep only the summary → delete both audio files + transcript file.
    let defaultPolicy = RetentionPolicy(settings: AppSettings())
    let toDelete = defaultPolicy.artifactsToDelete(for: meeting)
    check(toDelete.contains(micFile), "default policy deletes the mic file")
    check(!defaultPolicy.keepTranscript, "default: transcript not kept")
    check(!defaultPolicy.keepAudio, "default: audio not kept")

    // Keep transcript + audio: nothing deleted.
    let keepAll = RetentionPolicy(settings: AppSettings(keepTranscriptAfterSummary: true, keepAudioAfterSummary: true))
    check(keepAll.artifactsToDelete(for: meeting).isEmpty, "keep-all policy deletes nothing")
    check(keepAll.keepTranscript && keepAll.keepAudio, "keep-all flags are set")
} catch {
    check(false, "retention: \(error)")
}
try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("transcriber-ret-\(UUID().uuidString)", isDirectory: true))

// MARK: - Phase 4: model store (download-on-demand, not bundle)
section("models: download-on-demand + cache reuse")
final class FakeDownloader: ModelDownloader {
    var downloads = 0
    private let lock = NSLock()
    func download(spec: ModelSpec, to destination: URL, report: @Sendable (Double) -> Void) async throws {
        lock.lock(); downloads += 1; lock.unlock()
        report(1.0)
        // Write a file at least sizeBytes/4 so the size check passes.
        let size = max(1024, spec.sizeBytes / 4)
        try Data(count: size).write(to: destination)
    }
}
do {
    let modelsDir = FileManager.default.temporaryDirectory.appendingPathComponent("transcriber-models-\(UUID().uuidString)", isDirectory: true)
    ModelsDirectory.baseDirectory = { modelsDir }
    let spec = WhisperCatalog.spec(id: "whisper-base")!
    check(WhisperCatalog.all.count == 4, "catalog lists 4 model sizes")
    check(spec.sizeBytes > 0, "catalog spec has a size")

    let dl = FakeDownloader()
    let store = ModelStore(downloader: dl)
    check(!store.isCached(spec), "model not cached before first use")

    let url1 = try await store.ensure(spec: spec)
    check(url1.path.hasSuffix("whisper-base.bin"), "model cached under its id")
    check(FileManager.default.fileExists(atPath: url1.path), "model file exists after download")
    check(dl.downloads == 1, "downloaded exactly once")

    let url2 = try await store.ensure(spec: spec)
    check(url1 == url2, "second ensure returns the same URL (cache hit)")
    check(dl.downloads == 1, "second ensure did NOT re-download (offline reuse)")
    check(store.isCached(spec), "model now reports cached")

    // A truncated download is rejected, not silently accepted.
    final class TruncDownloader: ModelDownloader {
        func download(spec: ModelSpec, to destination: URL, report: @Sendable (Double) -> Void) async throws {
            try Data(count: 16).write(to: destination) // far below sizeBytes/4
        }
    }
    let truncSpec = ModelSpec(id: "whisper-tiny", displayName: "t", sizeBytes: 1_000_000, url: URL(string: "https://example.com/t.bin")!)
    let truncStore = ModelStore(downloader: TruncDownloader())
    do {
        _ = try await truncStore.ensure(spec: truncSpec)
        check(false, "truncated download should throw")
    } catch let e as ModelError {
        check(e == ModelError.incompleteDownload("whisper-tiny", expected: 1_000_000, got: 16), "truncated download surfaces an incomplete error")
    } catch {
        check(false, "truncated download threw wrong error: \(error)")
    }
} catch {
    check(false, "model store: \(error)")
}
ModelsDirectory.baseDirectory = nil
try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("transcriber-models-\(UUID().uuidString)", isDirectory: true))

// MARK: - Phase 4: settings (lenient decode + in-memory store)
section("settings: defaults + lenient decode + in-memory persistence")
do {
    let def = AppSettings()
    check(def.transcriptionBackend == .local, "default backend is local (private)")
    check(def.keepTranscriptAfterSummary == false, "default: transcript not kept")
    check(def.keepAudioAfterSummary == false, "default: audio not kept")
    check(def.summaryBackend == .openai, "default summary backend is openai")
    check(def.whisperModel == "whisper-base", "default whisper model is base")

    // Round-trip through the in-memory store (no real file touched).
    let store = SettingsStore.inMemory()
    var s = store.load()
    s.transcriptionBackend = .deepgram
    s.keepTranscriptAfterSummary = true
    store.save(s)
    let reloaded = store.load()
    check(reloaded.transcriptionBackend == .deepgram, "in-memory store persists backend")
    check(reloaded.keepTranscriptAfterSummary, "in-memory store persists keepTranscript")

    // Lenient decode: an old file missing new keys still loads with defaults.
    let oldJSON = #"{"captureMic":true,"captureSystem":true}"#.data(using: .utf8)!
    let old = try JSONDecoder().decode(AppSettings.self, from: oldJSON)
    check(old.captureMic && old.captureSystem, "old file: explicit keys decoded")
    check(old.transcriptionBackend == .local, "old file: new keys fall back to defaults")
    check(old.summaryBackend == .openai, "old file: summary backend defaults")
} catch {
    check(false, "settings: \(error)")
}

// MARK: - Phase 4: LLM summarizer over a fake HTTP client
section("llm: summarizer uses HTTP seam + shared parser")
final class FakeHTTP: HTTPClient {
    let status: Int
    let body: Data
    var lastRequest: HTTPRequest?
    init(status: Int, body: Data) { self.status = status; self.body = body }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lastRequest = request
        return HTTPResponse(statusCode: status, body: body)
    }
}
do {
    let openaiBody = Data(#"{"choices":[{"message":{"content":"{\"overall\":\"oai\",\"key_points\":[\"k\"],\"decisions\":[],\"action_items\":[]}"}}]}"#.utf8)
    let oai = OpenAISummarizer(model: "gpt-4o-mini", apiKey: { "test-key" }, http: FakeHTTP(status: 200, body: openaiBody))
    let oaiOut = try await oai.summarize(segments: [TranscriptSegment(speaker: "S1", text: "hi")], title: "T")
    check(oaiOut.overall == "oai", "OpenAI summarizer parses the summary")
    check(oaiOut.keyPoints == ["k"], "OpenAI summarizer parses key points")

    // Missing key → clear error, no network.
    let noKey = OpenAISummarizer(model: "gpt-4o-mini", apiKey: { nil }, http: FakeHTTP(status: 200, body: Data()))
    do {
        _ = try await noKey.summarize(segments: [], title: "T")
        check(false, "missing key should throw")
    } catch let e as LLMError {
        check(e.message.contains("OpenAI"), "missing OpenAI key surfaces a clear error")
    } catch {
        check(false, "missing key threw wrong error: \(error)")
    }

    let anthBody = Data(#"{"content":[{"text":"{\"overall\":\"anth\",\"key_points\":[\"k2\"]}"}]}"#.utf8)
    let anth = AnthropicSummarizer(model: "claude-3-5-haiku-latest", apiKey: { "ak" }, http: FakeHTTP(status: 200, body: anthBody))
    let anthOut = try await anth.summarize(segments: [TranscriptSegment(speaker: "S1", text: "hi")], title: "T")
    check(anthOut.overall == "anth", "Anthropic summarizer parses the summary")
    check(anthOut.keyPoints == ["k2"], "Anthropic summarizer parses key points")
} catch {
    check(false, "llm: \(error)")
}

// MARK: - Phase 4: Deepgram transcriber parses diarized words
section("cloud: deepgram transcriber parses speaker words")
do {
    let body = Data(#"""
    {"results":{"channels":[{"alternatives":[{"transcript":"hi there",
      "words":[
        {"word":"hi","start":0.0,"dur":0.5,"speaker":"1"},
        {"word":"there","start":0.6,"dur":0.5,"speaker":"1"},
        {"word":"hello","start":3.0,"dur":0.5,"speaker":"2"}
      ]}]}]}}
    """#.utf8)
    let http = FakeHTTP(status: 200, body: body)
    let dg = DeepgramTranscriber(apiKey: { "dg-key" }, http: http)
    let dgFile = FileManager.default.temporaryDirectory.appendingPathComponent("dg-audio-\(UUID().uuidString).wav")
    try Data(count: 1024).write(to: dgFile)
    defer { try? FileManager.default.removeItem(at: dgFile) }
    let segs = try await dg.transcribe(audio: CapturedAudio(fileURLs: [.mic: dgFile]), language: "en")
    check(segs.count == 2, "groups consecutive words into 2 speaker segments")
    check(segs[0].text == "hi there", "first segment joins same-speaker words")
    check(segs[1].text == "hello", "second segment is the other speaker")
    check(segs[0].startOffset == 0.0 && segs[0].endOffset == 1.1, "first segment timing spans its words")

    // Missing key → clear error.
    let noKeyDg = DeepgramTranscriber(apiKey: { nil }, http: FakeHTTP(status: 200, body: Data()))
    do {
        _ = try await noKeyDg.transcribe(audio: CapturedAudio(), language: "en")
        check(false, "missing key should throw")
    } catch let e as DeepgramError {
        check(e.message.contains("Deepgram"), "missing Deepgram key surfaces a clear error")
    } catch {
        check(false, "missing key threw wrong error: \(error)")
    }
} catch {
    check(false, "deepgram: \(error)")
}

// MARK: - Settings: updateSettings persists to disk

section("updateSettings persists to settings.json")
RecordingsDirectory.baseDirectory = {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("transcriber-settings-\(UUID().uuidString)", isDirectory: true)
}
do {
    let settingsURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("t_settings_\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: settingsURL) }

    let store = SettingsStore(url: settingsURL)
    let capDir = RecordingsDirectory.base()
    var vm = TranscriberViewModel(
        capture: RecordingAudioCapture(directory: capDir),
        processor: FakeProcessor(),
        settings: AppSettings(),
        settingsStore: store
    )

    check(vm.settings.transcriptionBackend == .local, "default backend is local")
    vm.updateSettings { $0.transcriptionBackend = .deepgram }
    vm.updateSettings { $0.summaryBackend = .anthropic }
    vm.updateSettings { $0.keepAudioAfterSummary = true }
    vm.updateSettings { $0.language = "fr" }

    check(vm.settings.transcriptionBackend == .deepgram, "in-memory backend updated")
    check(vm.settings.summaryBackend == .anthropic, "in-memory summary backend updated")
    check(vm.settings.keepAudioAfterSummary == true, "in-memory retention updated")
    check(vm.settings.language == "fr", "in-memory language updated")

    // A fresh store reading the same file sees the changes (persisted).
    let reloaded = SettingsStore(url: settingsURL).load()
    check(reloaded.transcriptionBackend == .deepgram, "backend persisted to disk")
    check(reloaded.summaryBackend == .anthropic, "summary backend persisted to disk")
    check(reloaded.keepAudioAfterSummary == true, "retention persisted to disk")
    check(reloaded.language == "fr", "language persisted to disk")
} catch {
    check(false, "updateSettings: \(error)")
}

// MARK: - Settings: processor factory is consulted with live settings

section("runPipeline rebuilds the pipeline from current settings (factory seam)")
RecordingsDirectory.baseDirectory = {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("transcriber-factory-\(UUID().uuidString)", isDirectory: true)
}
do {
    // A processor that reports which backend it was built for, so we can assert
    // the factory saw the *current* settings at run time.
    final class BackendTagProcessor: MeetingProcessor, @unchecked Sendable {
        let tag: String
        init(tag: String) { self.tag = tag }
        func process(meeting: Meeting, audio: CapturedAudio,
                     report: @Sendable (ProcessingProgress) -> Void) async throws -> ProcessedResult {
            return ProcessedResult(
                segments: [TranscriptSegment(speaker: "Speaker 1", text: "hi", startOffset: 0, endOffset: 1)],
                summary: MeetingSummary(overall: "built for \(tag)")
            )
        }
    }

    let capDir = RecordingsDirectory.base()
    var vm = TranscriberViewModel(
        capture: RecordingAudioCapture(directory: capDir),
        processor: BackendTagProcessor(tag: "initial"),
        settings: AppSettings(),
        // Factory rebuilds from the settings it is handed at run time.
        processorFactory: { settings in
            BackendTagProcessor(tag: settings.transcriptionBackend == .deepgram ? "deepgram" : "local")
        }
    )

    let m = await vm.startAsync(title: "factory test")
    await vm.stopAsync()   // stopAsync runs the pipeline (via the factory)
    check(vm.meetings.first(where: { $0.id == m.id })?.status == .summarized,
          "pipeline succeeded via factory")

    // The factory was consulted (not the fixed initial processor), because the
    // default settings backend is .local → tag "local", not "initial".
    check(vm.meetings.first(where: { $0.id == m.id })?.summary?.overall == "built for local",
          "factory saw current settings (local), not the fixed initial processor")

    // Now flip the backend in settings and run again: the factory must see it.
    vm.updateSettings { $0.transcriptionBackend = .deepgram }
    let m2 = await vm.startAsync(title: "factory test 2")
    await vm.stopAsync()
    check(vm.meetings.first(where: { $0.id == m2.id })?.status == .summarized,
          "second pipeline succeeded via factory")
    check(vm.meetings.first(where: { $0.id == m2.id })?.summary?.overall == "built for deepgram",
          "factory saw the *updated* backend (deepgram) after a settings change")
} catch {
    check(false, "factory seam: \(error)")
}

// MARK: - Pure text rendering (summaryText / transcriptText)
section("summaryText / transcriptText render deterministically")
do {
    let full = Meeting(
        title: "T",
        startedAt: Date(timeIntervalSince1970: 0),
        createdAt: Date(timeIntervalSince1970: 0),
        lastActivityAt: Date(timeIntervalSince1970: 0),
        transcript: [
            TranscriptSegment(speaker: "Alice", text: "Hello"),
            TranscriptSegment(speaker: "Bob", text: "Hi Alice")
        ],
        summary: MeetingSummary(
            overall: "We shipped it.",
            keyPoints: ["Point one", "Point two"],
            decisions: ["Ship on Friday"],
            actionItems: ["Write docs"]
        )
    )

    let st = full.summaryText()
    check(st.hasPrefix("We shipped it."), "summaryText starts with overall")
    check(st.contains("Key points:"), "summaryText has key points header")
    check(st.contains("• Point one"), "summaryText bullets key points")
    check(st.contains("Decisions:") && st.contains("• Ship on Friday"), "summaryText has decisions")
    check(st.contains("Action items:") && st.contains("• Write docs"), "summaryText has action items")

    // Sections that are empty must not appear.
    let minimal = Meeting(
        title: "M",
        startedAt: Date(timeIntervalSince1970: 0),
        createdAt: Date(timeIntervalSince1970: 0),
        lastActivityAt: Date(timeIntervalSince1970: 0),
        summary: MeetingSummary(overall: "Just a line.")
    )
    check(minimal.summaryText() == "Just a line.",
          "summaryText omits empty sections")

    // No summary at all → empty string.
    let none = Meeting(
        title: "N",
        startedAt: Date(timeIntervalSince1970: 0),
        createdAt: Date(timeIntervalSince1970: 0),
        lastActivityAt: Date(timeIntervalSince1970: 0)
    )
    check(none.summaryText() == "", "summaryText empty when no summary")

    // Transcript rendering: "Speaker: text" per line, joined by newline.
    let tt = full.transcriptText()
    check(tt == "[Alice] Hello\n[Bob] Hi Alice", "transcriptText renders speaker: text lines")
    check(none.transcriptText() == "", "transcriptText empty when no transcript")
}

// MARK: - Integration: real pipeline → real store → copyable text
section("integration: pipeline result renders through the real store + text helpers")
do {
    // A realistic pipeline result: two speakers, a full structured summary.
    let realistic = ProcessedResult(
        segments: [
            TranscriptSegment(speaker: "Alice", text: "Let's lock the roadmap."),
            TranscriptSegment(speaker: "Bob", text: "Ship settings first.")
        ],
        summary: MeetingSummary(
            overall: "Aligned on the roadmap; settings is priority one.",
            keyPoints: ["Settings first", "e2e demo deferred"],
            decisions: ["Ship settings before beta"],
            actionItems: ["Alice to write the spec"]
        )
    )

    let capDir2 = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcriber-int-\(UUID().uuidString)")
    RecordingsDirectory.baseDirectory = { capDir2 }

    // Real VM, real FakeProcessor, real MeetingStore (a real file on disk).
    let file2 = capDir2.appendingPathComponent("meetings.json")
    let settings2 = AppSettings(keepTranscriptAfterSummary: true) // keep transcript
    let vm2 = TranscriberViewModel(
        capture: RecordingAudioCapture(directory: capDir2),
        processor: FakeProcessor(result: realistic),
        settings: settings2,
        settingsStore: SettingsStore.inMemory(),
        meetingStore: MeetingStore(url: file2)
    )
    let im = await vm2.startAsync(title: "Integration meeting")
    await vm2.stopAsync()   // runs the real pipeline through the real engine

    // 1. The pipeline succeeded and the meeting is summarized.
    let got = vm2.meetings.first(where: { $0.id == im.id })
    check(got?.status == .summarized, "integration: pipeline summarized the meeting")

    // 2. summaryText() renders the REAL pipeline's structured summary.
    let st2 = got?.summaryText() ?? ""
    check(st2.hasPrefix("Aligned on the roadmap; settings is priority one."),
          "integration: summaryText starts with the real overall")
    check(st2.contains("Key points:") && st2.contains("• Settings first"),
          "integration: summaryText renders the real key points")
    check(st2.contains("Decisions:") && st2.contains("• Ship settings before beta"),
          "integration: summaryText renders the real decisions")
    check(st2.contains("Action items:") && st2.contains("• Alice to write the spec"),
          "integration: summaryText renders the real action items")

    // 3. Because keepTranscript is on, the transcript is retained and its
    //    text matches exactly what the detail pane would show / copy.
    let tt2 = got?.transcriptText() ?? ""
    check(tt2 == "[Alice] Let's lock the roadmap.\n[Bob] Ship settings first.",
          "integration: retained transcriptText matches the real segments")

    // 4. The same meeting, re-loaded from disk by a FRESH store, renders
    //    identically — proving the copyable text is stable across the
    //    persistence boundary the detail pane actually reads from.
    let reloaded = MeetingStore(url: file2).load().first(where: { $0.id == im.id })
    check(reloaded?.summaryText() == st2, "integration: summaryText stable across store reload")
    check(reloaded?.transcriptText() == tt2, "integration: transcriptText stable across store reload")

    // 5. The delete action removes the meeting from the real store + disk.
    vm2.delete(id: im.id)
    check(vm2.meetings.isEmpty, "integration: delete removes the meeting from the VM")
    check(MeetingStore(url: file2).load().isEmpty,
          "integration: delete persists to disk (real store now empty)")
} catch {
    check(false, "integration: \(error)")
}

// MARK: - Integration: default retention + retry render (detail-pane acceptance)
section("integration: default retention clears transcript; retry then renders summary")
do {
    let realistic2 = ProcessedResult(
        segments: [TranscriptSegment(speaker: "Alice", text: "default path")],
        summary: MeetingSummary(overall: "Default-retention result.", keyPoints: ["kp"])
    )

    // --- 1. DEFAULT retention (keepTranscript=false, the product's promise) ---
    // The transcript must be cleared after summarizing, so transcriptText() is
    // empty (detail pane hides the transcript section) while summaryText()
    // still renders the summary.
    let dDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcriber-def-\(UUID().uuidString)")
    RecordingsDirectory.baseDirectory = { dDir }
    let dFile = dDir.appendingPathComponent("meetings.json")
    let dvm = TranscriberViewModel(
        capture: RecordingAudioCapture(directory: dDir),
        processor: FakeProcessor(result: realistic2),
        settings: AppSettings(),                       // keepTranscriptAfterSummary = false
        settingsStore: SettingsStore.inMemory(),
        meetingStore: MeetingStore(url: dFile)
    )
    let dm = await dvm.startAsync(title: "Default retention")
    await dvm.stopAsync()
    let dgot = dvm.meetings.first(where: { $0.id == dm.id })
    check(dgot?.status == .summarized, "default: summarized")
    check(dgot?.transcript.isEmpty == true, "default: transcript cleared (product promise)")
    check((dgot?.transcriptText() ?? "") == "", "default: transcriptText empty → pane hides transcript")
    check((dgot?.summaryText() ?? "").hasPrefix("Default-retention result."),
          "default: summaryText still renders the summary")
    // And it is stable across the persistence boundary.
    let dReload = MeetingStore(url: dFile).load().first(where: { $0.id == dm.id })
    check(dReload?.transcript.isEmpty == true, "default: cleared transcript persists as empty")
    check((dReload?.summaryText() ?? "") == (dgot?.summaryText() ?? ""),
          "default: summaryText stable across store reload")

    // --- 2. RETRY then render (the detail pane's failed → retry → summary flow) ---
    // Session A: the pipeline throws → the meeting is failed, NO summary, so
    // summaryText() is empty (the pane shows the failed/error state).
    let rDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcriber-retr-\(UUID().uuidString)")
    RecordingsDirectory.baseDirectory = { rDir }
    let rFile = rDir.appendingPathComponent("meetings.json")
    let rvm = TranscriberViewModel(
        capture: RecordingAudioCapture(directory: rDir),
        processor: FakeProcessor(shouldThrow: ModelError.notFound("whisper-base")),
        settings: AppSettings(),
        settingsStore: SettingsStore.inMemory(),
        meetingStore: MeetingStore(url: rFile)
    )
    let rm = await rvm.startAsync(title: "Will retry")
    await rvm.stopAsync()
    let rfailed = rvm.meetings.first(where: { $0.id == rm.id })
    check(rfailed?.status == .failed, "retry: meeting is failed after a throwing pipeline")
    check((rfailed?.summaryText() ?? "") == "", "retry: no summary yet → summaryText empty (pane shows error)")

    // Session B: the user fixes the backend (now a working processor) and
    // retries. The detail pane's Retry button calls vm.retry(id:).
    let rvm2 = TranscriberViewModel(
        capture: RecordingAudioCapture(directory: rDir),
        processor: FakeProcessor(result: realistic2),
        settings: AppSettings(),
        settingsStore: SettingsStore.inMemory(),
        meetingStore: MeetingStore(url: rFile)   // loads the failed meeting from disk
    )
    let loadedFailed = rvm2.meetings.first(where: { $0.id == rm.id })
    check(loadedFailed?.status == .failed, "retry: failed meeting loaded from disk")
    let retried = await rvm2.retry(id: rm.id)
    check(retried, "retry: vm.retry(id:) reports success")
    let rdone = rvm2.meetings.first(where: { $0.id == rm.id })
    check(rdone?.status == .summarized, "retry: now summarized")
    check((rdone?.summaryText() ?? "").hasPrefix("Default-retention result."),
          "retry: summaryText now renders the summary after a successful retry")
} catch {
    check(false, "default-retention/retry: \(error)")
}

// MARK: - Orphan recording-directory sweep (Phase 7.1)
section("orphan sweep: pure decision + VM cleanup")
do {
    // --- 1. Pure decision: which dirs are orphans ---
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcriber-sweep-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

    // A non-UUID dir (not ours) → never touched.
    let foreign = base.appendingPathComponent("not-a-uuid")
    try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)

    // A UUID dir with no live meeting → orphan.
    let dead = UUID()
    let deadDir = base.appendingPathComponent(dead.uuidString)
    try FileManager.default.createDirectory(at: deadDir, withIntermediateDirectories: true)
    try Data("stale audio".utf8).write(to: deadDir.appendingPathComponent("mic.wav"))

    // A UUID dir for a *live* meeting that is non-empty → kept (retryable audio).
    let live = UUID()
    let liveDir = base.appendingPathComponent(live.uuidString)
    try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
    try Data("live audio".utf8).write(to: liveDir.appendingPathComponent("mic.wav"))

    // A UUID dir for a *live* meeting that is empty → orphan (leftover).
    let liveEmpty = UUID()
    let liveEmptyDir = base.appendingPathComponent(liveEmpty.uuidString)
    try FileManager.default.createDirectory(at: liveEmptyDir, withIntermediateDirectories: true)

    let liveIDs: Set<UUID> = [live, liveEmpty]
    let orphans = Set(RecordingsDirectory.orphanDirectories(liveIDs: liveIDs, base: base).map(\.lastPathComponent))
    check(orphans.contains(deadDir.lastPathComponent), "sweep: dead UUID dir is an orphan")
    check(orphans.contains(liveEmptyDir.lastPathComponent), "sweep: live but empty dir is an orphan")
    check(!orphans.contains(liveDir.lastPathComponent), "sweep: live non-empty dir is KEPT (retryable)")
    check(!orphans.contains(foreign.lastPathComponent), "sweep: non-UUID dir is never touched")

    // --- 2. VM sweep actually removes the orphans and keeps the live one ---
    RecordingsDirectory.baseDirectory = { base }
    let liveNow = Date()
    let liveMeeting = Meeting(id: live, title: "Live", status: .failed,
                              startedAt: liveNow, createdAt: liveNow, lastActivityAt: liveNow,
                              audioFileURLs: [.mic: liveDir.appendingPathComponent("mic.wav")])
    let vm = TranscriberViewModel(
        capture: RecordingAudioCapture(directory: base),
        processor: NoopProcessor(),
        settings: AppSettings(),
        settingsStore: SettingsStore.inMemory(),
        meetingStore: MeetingStore.inMemory(initial: [liveMeeting])
    )
    // The sweep runs in init; assert its effect on disk.
    check(!FileManager.default.fileExists(atPath: deadDir.path), "sweep: dead dir removed from disk")
    check(!FileManager.default.fileExists(atPath: liveEmptyDir.path), "sweep: live-empty dir removed from disk")
    check(FileManager.default.fileExists(atPath: liveDir.appendingPathComponent("mic.wav").path),
          "sweep: live non-empty dir's audio is preserved")
    check(FileManager.default.fileExists(atPath: foreign.path), "sweep: foreign dir untouched")

    // --- 3. Pipeline retention now removes the empty per-meeting dir ---
    // Drive a real pipeline to success (default retention) and confirm the
    // per-meeting directory is gone from disk, not just the audio files.
    let pDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcriber-pipeline-dir-\(UUID().uuidString)")
    RecordingsDirectory.baseDirectory = { pDir }
    let pFile = pDir.appendingPathComponent("meetings.json")
    let pvm = TranscriberViewModel(
        capture: RecordingAudioCapture(directory: pDir),
        processor: FakeProcessor(result: ProcessedResult(
            segments: [TranscriptSegment(speaker: "A", text: "hi")],
            summary: MeetingSummary(overall: "ok", keyPoints: ["p"])
        )),
        settings: AppSettings(),   // default retention: delete audio + transcript
        settingsStore: SettingsStore.inMemory(),
        meetingStore: MeetingStore(url: pFile)
    )
    let pm = await pvm.startAsync(title: "Pipeline dir cleanup")
    await pvm.stopAsync()
    let pMeeting = pvm.meetings.first(where: { $0.id == pm.id })
    check(pMeeting?.status == .summarized, "dir-cleanup: summarized")
    let pdir = RecordingsDirectory.forMeeting(pm.id)
    check(!FileManager.default.fileExists(atPath: pdir.path),
          "dir-cleanup: empty per-meeting dir removed after retention (no leak)")

    // --- 4. keepAudio=true → the dir survives (audio is retained) ---
    let kDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcriber-keep-dir-\(UUID().uuidString)")
    RecordingsDirectory.baseDirectory = { kDir }
    let kFile = kDir.appendingPathComponent("meetings.json")
    var keepSettings = AppSettings()
    keepSettings.keepAudioAfterSummary = true
    let kvm = TranscriberViewModel(
        capture: RecordingAudioCapture(directory: kDir),
        processor: FakeProcessor(result: ProcessedResult(
            segments: [TranscriptSegment(speaker: "A", text: "hi")],
            summary: MeetingSummary(overall: "ok", keyPoints: ["p"])
        )),
        settings: keepSettings,
        settingsStore: SettingsStore.inMemory(),
        meetingStore: MeetingStore(url: kFile)
    )
    let km = await kvm.startAsync(title: "Keep audio dir")
    await kvm.stopAsync()
    let kdir = RecordingsDirectory.forMeeting(km.id)
    check(FileManager.default.fileExists(atPath: kdir.path),
          "keepAudio: per-meeting dir retained because audio is kept")
} catch {
    check(false, "orphan-sweep: \(error)")
}

// MARK: - Report
print("\n\(passed) passed, \(failed) failed")
if failed > 0 {
    exit(1)
}

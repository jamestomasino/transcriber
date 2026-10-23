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

// Every view-model test gets an isolated recordings root, including tests
// that reset an override. A nil override would sweep the user's real files.
let suiteRoot = FileManager.default.temporaryDirectory.appendingPathComponent("transcriber-suite-\(UUID().uuidString)")
let suiteRecordings = suiteRoot.appendingPathComponent("recordings")
RecordingsDirectory.baseDirectory = { suiteRecordings }

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
RecordingsDirectory.baseDirectory = { suiteRecordings }
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
RecordingsDirectory.baseDirectory = { suiteRecordings }

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

    // Keep original transcript + audio; the derived mix is always deleted.
    let keepAll = RetentionPolicy(settings: AppSettings(keepTranscriptAfterSummary: true, keepAudioAfterSummary: true))
    check(keepAll.artifactsToDelete(for: meeting) == [dir.appendingPathComponent(CapturedAudio.preparedFileName)], "keep-all retains originals but deletes the transient mix")
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
    check(def.summaryBackend == .local, "default summary backend is local")
    check(def.summaryModel.isEmpty, "local summary uses the on-device model")
    check(def.language == "en", "default language is English")
    check(def.storageDirectory == StorageDirectory.defaultDirectory, "new settings select Documents storage")
    let fresh = SettingsStore(url: suiteRoot.appendingPathComponent("first-run/settings.json")).load()
    check(fresh == def, "first startup without saved settings uses the new defaults")
    let startupVM = TranscriberViewModel(capture: RecordingAudioCapture(directory: suiteRecordings),
                                        startupError: "Could not create the data folder")
    check(startupVM.processingError == "Could not create the data folder", "startup storage failures are visible to the UI")
    check(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(def)) == def,
          "new defaults survive settings serialization")
    check(AppSettings(summaryBackend: .openai).summaryModel == "gpt-4o-mini", "explicit cloud backend selects its compatible model")
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
    check(old.summaryBackend == .local, "old file: missing summary backend uses local default")
    check(old.language == "en", "old file: missing language uses English default")
    check(old.storageDirectory == nil, "old file: missing storage preserves legacy location")
    let existingJSON = #"{"transcriptionBackend":"deepgram","summaryBackend":"openai","language":""}"#.data(using: .utf8)!
    let existing = try JSONDecoder().decode(AppSettings.self, from: existingJSON)
    check(existing.transcriptionBackend == .deepgram && existing.summaryBackend == .openai && existing.language.isEmpty,
          "saved cloud backends and automatic language remain unchanged")
    check(existing.summaryModel == "gpt-4o-mini", "missing model matches the saved cloud backend")
} catch {
    check(false, "settings: \(error)")
}

// MARK: - Phase 7: local (on-device) summary backend
section("settings: local summary backend is a distinct, round-trippable case")
do {
    // `.local` is a distinct case from the two cloud backends.
    check(SummaryBackend.local != .openai, "local is not openai")
    check(SummaryBackend.local != .anthropic, "local is not anthropic")
    check(SummaryBackend.allCases.contains(.local), "allCases includes local")

    // It encodes to a stable string and round-trips through JSON.
    let localData = try JSONEncoder().encode(SummaryBackend.local)
    check(String(data: localData, encoding: .utf8) == #""local""#, "encodes to the string 'local'")
    let decoded = try JSONDecoder().decode(SummaryBackend.self, from: localData)
    check(decoded == .local, "round-trips back to .local")

    // An AppSettings with the local backend persists through the in-memory store.
    let store = SettingsStore.inMemory()
    var s = store.load()
    s.summaryBackend = .local
    store.save(s)
    check(store.load().summaryBackend == .local, "in-memory store persists the local backend")

    // A settings file written by an older version (no summaryBackend key) still
    // loads with the local default.
    let oldJSON = #"{"captureMic":true}"#.data(using: .utf8)!
    let old = try JSONDecoder().decode(AppSettings.self, from: oldJSON)
    check(old.summaryBackend == .local, "old file defaults to local (lenient)")
} catch {
    check(false, "local summary backend: \(error)")
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

// MARK: - Phase 7: long-recording transcript cap (pure)
section("long recording: transcript cap keeps the LLM prompt bounded")
check(Summary.defaultTranscriptBudget > 60_000, "default transcript budget is generous")

// Short transcripts pass through unchanged.
let capShort = "Alice: kickoff\nBob: great"
check(Summary.fitTranscript(capShort) == capShort, "short transcript is untouched")
check(Summary.fitTranscript(capShort, budget: 10_000) == capShort, "short transcript untouched under an explicit budget")

// A very long transcript is capped to the budget, keeps the opening + closing,
// and marks the omission in between.
let capLong = String(repeating: "speaker line of speech\n", count: 20_000)
let capCapped = Summary.fitTranscript(capLong, budget: 10_000)
check(capCapped.count <= 10_000, "capped transcript is within the budget")
check(capCapped.contains("middle of transcript omitted"), "capped transcript marks the omission")
check(capCapped.hasPrefix("speaker line"), "capped transcript keeps the opening")
check(capCapped.hasSuffix("speech\n"), "capped transcript keeps the closing")

// The cap is applied inside the real summarizer request, not just the pure fn.
final class CapProbeHTTP: HTTPClient {
    var lastBody: Data?
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lastBody = request.body
        return HTTPResponse(statusCode: 200, body: Data(#"{"choices":[{"message":{"content":"{\"overall\":\"ok\"}"}}]}"#.utf8))
    }
}
do {
    let capProbe = CapProbeHTTP()
    let capOai = OpenAISummarizer(model: "gpt-4o-mini", apiKey: { "k" }, http: capProbe)
    let capBig = (0..<20_000).map { TranscriptSegment(speaker: "S\($0)", text: "a line of speech about the project") }
    _ = try await capOai.summarize(segments: capBig, title: "Long meeting")
    let capSent = String(data: capProbe.lastBody ?? Data(), encoding: .utf8) ?? ""
    check(capSent.contains("middle of transcript omitted"), "summarizer request is capped for a very long transcript")
    check(capSent.contains("S0"), "capped request keeps the opening segment")
    check(capSent.contains("S19999"), "capped request keeps the closing segment")
} catch {
    check(false, "cap probe: \(error)")
}

// --- Warning: the user is told the summary is a partial view ---

// transcriptFits predicate: short fits, long doesn't.
check(Summary.transcriptFits("short"), "short transcript fits")
check(!Summary.transcriptFits(String(repeating: "x", count: 200_000)), "very long transcript does not fit")

// parse records the flag when told the transcript was capped.
let capFlagged = Summary.parse(#"{"overall":"o"}"#, transcriptWasCapped: true)
check(capFlagged.transcriptWasCapped, "parse records transcriptWasCapped=true")
let capNotFlagged = Summary.parse(#"{"overall":"o"}"#)
check(!capNotFlagged.transcriptWasCapped, "parse defaults transcriptWasCapped=false")

// The summarizer sets the flag for a very long transcript and clears it for a short one.
final class CapFlagProbe: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        return HTTPResponse(statusCode: 200, body: Data(#"{"choices":[{"message":{"content":"{\"overall\":\"ok\"}"}}]}"#.utf8))
    }
}
do {
    let capFlagLong = (0..<20_000).map { TranscriptSegment(speaker: "S\($0)", text: "a line of speech about the project") }
    let capFlagShort = [TranscriptSegment(speaker: "S", text: "hi")]
    let capLongOut = try await OpenAISummarizer(model: "m", apiKey: { "k" }, http: CapFlagProbe()).summarize(segments: capFlagLong, title: "T")
    check(capLongOut.transcriptWasCapped, "summarizer flags a very long transcript as capped")
    let capShortOut = try await OpenAISummarizer(model: "m", apiKey: { "k" }, http: CapFlagProbe()).summarize(segments: capFlagShort, title: "T")
    check(!capShortOut.transcriptWasCapped, "summarizer leaves a short transcript uncapped")
} catch {
    check(false, "cap flag probe: \(error)")
}

// summaryText() carries the partial-view note when capped, and omits it otherwise.
let capNoteMeeting = Meeting(title: "M", startedAt: .init(timeIntervalSince1970: 0), createdAt: .init(timeIntervalSince1970: 0), lastActivityAt: .init(timeIntervalSince1970: 0),
    summary: MeetingSummary(overall: "did things", transcriptWasCapped: true))
check(capNoteMeeting.summaryText().contains("opening and closing"), "summaryText carries the partial-view note when capped")
check(capNoteMeeting.summaryText().contains("did things"), "summaryText still includes the overall line")
let capNoNoteMeeting = Meeting(title: "M", startedAt: .init(timeIntervalSince1970: 0), createdAt: .init(timeIntervalSince1970: 0), lastActivityAt: .init(timeIntervalSince1970: 0),
    summary: MeetingSummary(overall: "did things"))
check(!capNoNoteMeeting.summaryText().contains("opening and closing"), "summaryText omits the note when not capped")

// Lenient decode: a stored summary from an older build (no field) loads as uncapped.
do {
    let capOldJSON = #"{"overall":"o","keyPoints":[],"decisions":[],"actionItems":[],"generatedAt":0,"model":""}"#.data(using: .utf8)!
    let capOld = try JSONDecoder().decode(MeetingSummary.self, from: capOldJSON)
    check(!capOld.transcriptWasCapped, "old stored summary loads with transcriptWasCapped=false")
    // Round-trip: a capped summary encodes + decodes with the flag intact.
    let capRound = MeetingSummary(overall: "o", transcriptWasCapped: true)
    let capRoundData = try JSONEncoder().encode(capRound)
    let capRoundBack = try JSONDecoder().decode(MeetingSummary.self, from: capRoundData)
    check(capRoundBack.transcriptWasCapped, "capped flag survives an encode/decode round-trip")
} catch {
    check(false, "cap decode: \(error)")
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

// MARK: - Phase 7: long-meeting hardening — retry policy (pure)
section("http retry: pure policy decides which failures are worth retrying")
do {
    // Transient server / rate-limit statuses are retriable.
    check(HTTPRetryPolicy.isRetryable(HTTPError.badStatus(429)), "429 (rate limited) is retriable")
    check(HTTPRetryPolicy.isRetryable(HTTPError.badStatus(500)), "500 is retriable")
    check(HTTPRetryPolicy.isRetryable(HTTPError.badStatus(502)), "502 is retriable")
    check(HTTPRetryPolicy.isRetryable(HTTPError.badStatus(503)), "503 is retriable")
    check(HTTPRetryPolicy.isRetryable(HTTPError.badStatus(504)), "504 is retriable")

    // Client errors and other HTTP errors are NOT retriable — retrying just wastes a round trip.
    check(!HTTPRetryPolicy.isRetryable(HTTPError.badStatus(400)), "400 is not retriable")
    check(!HTTPRetryPolicy.isRetryable(HTTPError.badStatus(401)), "401 (bad key) is not retriable")
    check(!HTTPRetryPolicy.isRetryable(HTTPError.badStatus(404)), "404 is not retriable")
    check(!HTTPRetryPolicy.isRetryable(HTTPError.noBody), "noBody is not retriable")
    check(!HTTPRetryPolicy.isRetryable(HTTPError.decoding("x")), "decoding is not retriable")

    // Transient network hiccups (timeouts, dropped connection) are retriable.
    check(HTTPRetryPolicy.isRetryable(URLError(.timedOut)), "URLError.timedOut is retriable")
    check(HTTPRetryPolicy.isRetryable(URLError(.networkConnectionLost)), "connection lost is retriable")
    check(HTTPRetryPolicy.isRetryable(URLError(.notConnectedToInternet)), "no network is retriable")
    check(HTTPRetryPolicy.isRetryable(URLError(.cannotConnectToHost)), "cannot connect is retriable")

    // A non-transient URLError (bad server response, user cancellation) is not retriable.
    check(!HTTPRetryPolicy.isRetryable(URLError(.badURL)), "bad URL is not retriable")
    check(!HTTPRetryPolicy.isRetryable(URLError(.badServerResponse)), "bad server response is not retriable")
    check(!HTTPRetryPolicy.isRetryable(URLError(.cancelled)), "user cancellation is not retriable")

    // An unrelated error type is never retriable.
    struct PlainError: Error {}
    check(!HTTPRetryPolicy.isRetryable(PlainError()), "unknown error is not retriable")

    // The generous defaults are sensible for long meetings.
    check(HTTPRetryPolicy.defaultMaxAttempts >= 2, "default allows at least one retry")
    check(HTTPRetryPolicy.defaultRequestTimeout > 60, "default request timeout beats URLSession.shared's 60s")
}

// MARK: - Phase 7: long-meeting hardening — retrying client (decorator)
section("http retry: decorator retries transient failures, respects the cap, never retries 4xx")
do {
    final class ScriptedHTTP: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        let outcomes: [Result<HTTPResponse, Error>]
        init(outcomes: [Result<HTTPResponse, Error>]) { self.outcomes = outcomes }
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            lock.lock(); let idx = min(_calls, outcomes.count - 1); _calls += 1; lock.unlock()
            switch outcomes[idx] {
            case .success(let r): return r
            case .failure(let e): throw e
            }
        }
    }

    // --- success after two transient 503s → 3 calls, returns the 200 ---
    let okBody = Data(#"{"ok":true}"#.utf8)
    let flaky = ScriptedHTTP(outcomes: [
        .failure(HTTPError.badStatus(503)),
        .failure(HTTPError.badStatus(503)),
        .success(HTTPResponse(statusCode: 200, body: okBody)),
    ])
    let flakyClient = RetryingHTTPClient(inner: flaky, backoffDelay: 0)
    let flakyResp = try await flakyClient.send(HTTPRequest(url: URL(string: "https://example.com")!))
    check(flakyResp.statusCode == 200, "flaky: returns the eventual success")
    check(flaky.calls == 3, "flaky: took exactly 3 attempts (2 failures + 1 success)")

    // --- succeeds on the first try → exactly one call, no wasted retry ---
    let oneShot = ScriptedHTTP(outcomes: [.success(HTTPResponse(statusCode: 200, body: okBody))])
    let oneShotClient = RetryingHTTPClient(inner: oneShot, backoffDelay: 0)
    _ = try await oneShotClient.send(HTTPRequest(url: URL(string: "https://example.com")!))
    check(oneShot.calls == 1, "one-shot: a clean success is not retried")

    // --- transient URLError (timeout) then success → retried ---
    let timeoutThenOk = ScriptedHTTP(outcomes: [
        .failure(URLError(.timedOut)),
        .success(HTTPResponse(statusCode: 200, body: okBody)),
    ])
    let timeoutClient = RetryingHTTPClient(inner: timeoutThenOk, backoffDelay: 0)
    let timeoutResp = try await timeoutClient.send(HTTPRequest(url: URL(string: "https://example.com")!))
    check(timeoutResp.statusCode == 200, "timeout: recovers after a transient timeout")
    check(timeoutThenOk.calls == 2, "timeout: one retry then success")

    // --- cap respected: 503 forever → exactly maxAttempts calls, then throws ---
    let always503 = ScriptedHTTP(outcomes: [.failure(HTTPError.badStatus(503))])
    let capped = RetryingHTTPClient(inner: always503, maxAttempts: 3, backoffDelay: 0)
    do {
        _ = try await capped.send(HTTPRequest(url: URL(string: "https://example.com")!))
        check(false, "cap: should have thrown after exhausting retries")
    } catch let e as HTTPError {
        check(e == .badStatus(503), "cap: rethrows the last transient error")
        check(always503.calls == 3, "cap: stopped at exactly maxAttempts (3) calls")
    } catch {
        check(false, "cap: threw the wrong error: \(error)")
    }

    // --- a 4xx is never retried, even if more attempts remain ---
    let client401 = ScriptedHTTP(outcomes: [.failure(HTTPError.badStatus(401))])
    let noRetry = RetryingHTTPClient(inner: client401, maxAttempts: 5, backoffDelay: 0)
    do {
        _ = try await noRetry.send(HTTPRequest(url: URL(string: "https://example.com")!))
        check(false, "401: should have thrown")
    } catch let e as HTTPError {
        check(e == .badStatus(401), "401: rethrows the client error")
        check(client401.calls == 1, "401: a client error is never retried (exactly 1 call)")
    } catch {
        check(false, "401: threw the wrong error: \(error)")
    }
} catch {
    check(false, "http retry: \(error)")
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
section("recording folders: sortable start dates and compatible cleanup")
do {
    let root = suiteRoot.appendingPathComponent("dated-folders", isDirectory: true)
    let previousRoot = RecordingsDirectory.baseDirectory
    RecordingsDirectory.baseDirectory = { root }
    defer {
        RecordingsDirectory.baseDirectory = previousRoot
        try? FileManager.default.removeItem(at: root)
    }
    let utc = TimeZone(secondsFromGMT: 0)!
    let start = ISO8601DateFormatter().date(from: "2026-10-23T09:05:00Z")!
    let meeting = Meeting(title: "Dated", startedAt: start, createdAt: start, lastActivityAt: start)
    let dated = RecordingsDirectory.forMeeting(meeting, timeZone: utc)
    check(dated.lastPathComponent == "20261023-0905-\(meeting.id.uuidString)", "folder uses the meeting start date and a unique ID")
    let sameMinute = Meeting(title: "Another", startedAt: start, createdAt: start, lastActivityAt: start)
    check(RecordingsDirectory.forMeeting(sameMinute, timeZone: utc) != dated, "meetings in the same minute have distinct folders")
    let next = Meeting(title: "Later", startedAt: start.addingTimeInterval(60), createdAt: start, lastActivityAt: start)
    check(dated.lastPathComponent < RecordingsDirectory.forMeeting(next, timeZone: utc).lastPathComponent,
          "folder names sort chronologically")
    let offset = RecordingsDirectory.forMeeting(meeting, timeZone: TimeZone(secondsFromGMT: 3600)!)
    check(offset.lastPathComponent.hasPrefix("20261023-1005-"), "folder time uses the selected local timezone")
    let yearEnd = ISO8601DateFormatter().date(from: "2021-01-01T00:05:00Z")!
    let newYear = Meeting(title: "New Year", startedAt: yearEnd, createdAt: yearEnd, lastActivityAt: yearEnd)
    check(RecordingsDirectory.forMeeting(newYear, timeZone: utc).lastPathComponent.hasPrefix("20210101-0005-"),
          "folder year is the calendar year, including near New Year")

    try FileManager.default.createDirectory(at: dated, withIntermediateDirectories: true)
    let audio = dated.appendingPathComponent("mic.wav")
    try Data("retryable audio".utf8).write(to: audio)
    let empty = RecordingsDirectory.forMeeting(sameMinute, timeZone: utc)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let orphan = RecordingsDirectory.forMeeting(next, timeZone: utc)
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    try Data("orphan audio".utf8).write(to: orphan.appendingPathComponent("mic.wav"))
    let foreign = root.appendingPathComponent("notes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
    let invalid = root.appendingPathComponent("20261023-0905-not-a-meeting")
    try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
    let artifacts = MeetingArtifacts()
    let swept = Set(artifacts.sweep(liveIDs: [meeting.id, sameMinute.id]).map(\.lastPathComponent))
    check(swept == Set([empty.lastPathComponent, orphan.lastPathComponent]), "sweep removes dated orphans and empty folders while preserving live audio and foreign folders")
    try artifacts.removeEmptyDirectory(for: meeting.id)
    check(FileManager.default.fileExists(atPath: audio.path), "empty-folder cleanup keeps retained dated audio")
    try artifacts.remove([audio])
    try artifacts.removeEmptyDirectory(for: meeting.id)
    check(!FileManager.default.fileExists(atPath: dated.path), "cleanup finds dated folders by ID without recomputing the timezone")

    // Discard handles both naming generations, including non-empty folders.
    let legacy = root.appendingPathComponent(meeting.id.uuidString, isDirectory: true)
    for dir in [legacy, offset] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: dir.appendingPathComponent("mic.wav"))
    }
    try artifacts.discard(meeting)
    check(!FileManager.default.fileExists(atPath: legacy.path) && !FileManager.default.fileExists(atPath: offset.path),
          "discard removes legacy and dated folders for the meeting")
    check(FileManager.default.fileExists(atPath: foreign.path) && FileManager.default.fileExists(atPath: invalid.path),
          "discard preserves unrecognized folder names")
} catch { check(false, "dated recording folders: \(error)") }

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
    let pdir = RecordingsDirectory.forMeeting(pm)
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
    let kdir = RecordingsDirectory.forMeeting(km)
    check(kvm.meeting(id: km.id)?.audioFileURLs[.mic]?.deletingLastPathComponent().path == kdir.path,
          "recording writes audio into the folder based on meeting start time")
    check(FileManager.default.fileExists(atPath: kdir.path),
          "keepAudio: per-meeting dir retained because audio is kept")
} catch {
    check(false, "orphan-sweep: \(error)")
}

// MARK: - Phase 7.2: notifications (pure decision)
section("notification: pure decision (MeetingNotificationPolicy)")
do {
    func mk(_ title: String, _ status: MeetingStatus, summary: MeetingSummary? = nil) -> Meeting {
        Meeting(title: title, status: status, startedAt: t0, createdAt: t0,
                lastActivityAt: t0, summary: summary)
    }

    let ready = MeetingNotificationPolicy.notification(
        for: mk("All Hands", .summarized, summary: MeetingSummary(overall: "Shipped v1.")),
        errorDescription: nil, settings: AppSettings()
    )
    check(ready?.title == "All Hands", "ready: title is the meeting title")
    check(ready?.body == "Summary ready: Shipped v1.", "ready: body carries the overall line")
    check(ready?.isError == false, "ready: not flagged as an error")

    let readyBlank = MeetingNotificationPolicy.notification(
        for: mk("All Hands", .summarized, summary: MeetingSummary(overall: "   ")),
        errorDescription: nil, settings: AppSettings()
    )
    check(readyBlank?.body == "Summary ready.", "ready: blank overall falls back to a plain note")

    let noTitle = MeetingNotificationPolicy.notification(
        for: mk("", .summarized, summary: MeetingSummary(overall: "ok")),
        errorDescription: nil, settings: AppSettings()
    )
    check(noTitle?.title == "Meeting", "blank meeting title falls back to 'Meeting'")

    let failed = MeetingNotificationPolicy.notification(
        for: mk("Sync", .failed),
        errorDescription: "whisper model not found", settings: AppSettings()
    )
    check(failed?.isError == true, "failed: flagged as an error")
    check(failed?.body.contains("whisper model not found") == true,
          "failed: body carries the reason")
    check(failed?.body.contains("retry") == true, "failed: body points the user to retry")

    let failedNoReason = MeetingNotificationPolicy.notification(
        for: mk("Sync", .failed), errorDescription: nil, settings: AppSettings()
    )
    check(failedNoReason?.body.contains("retry") == true,
          "failed (no reason): still says to retry")

    check(MeetingNotificationPolicy.notification(
        for: mk("Live", .recording), errorDescription: nil, settings: AppSettings()
    ) == nil, "recording: no notification (not terminal)")
    check(MeetingNotificationPolicy.notification(
        for: mk("Busy", .processing), errorDescription: nil, settings: AppSettings()
    ) == nil, "processing: no notification (not terminal)")

    let off = AppSettings(notifyOnSummary: false)
    check(MeetingNotificationPolicy.notification(
        for: mk("All Hands", .summarized, summary: MeetingSummary(overall: "x")),
        errorDescription: nil, settings: off
    ) == nil, "notifyOnSummary off: no notification even when summarized")
}

// MARK: - Phase 7.2: notifications (VM posts on terminal states)
section("notification: VM posts when a meeting finishes or fails")
do {
    final class NotifRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _notes: [MeetingNotification] = []
        var notes: [MeetingNotification] { lock.lock(); defer { lock.unlock() }; return _notes }
        func add(_ n: MeetingNotification) { lock.lock(); _notes.append(n); lock.unlock() }
    }

    // --- success → exactly one "ready" notification ---
    let okDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcriber-notif-ok-\(UUID().uuidString)")
    RecordingsDirectory.baseDirectory = { okDir }
    let okFile = okDir.appendingPathComponent("meetings.json")
    let okRec = NotifRecorder()
    let okVM = TranscriberViewModel(
        capture: RecordingAudioCapture(directory: okDir),
        processor: FakeProcessor(result: ProcessedResult(
            segments: [TranscriptSegment(speaker: "A", text: "hi")],
            summary: MeetingSummary(overall: "Discussed the roadmap.")
        )),
        settings: AppSettings(),
        settingsStore: SettingsStore.inMemory(),
        meetingStore: MeetingStore(url: okFile),
        notifier: { okRec.add($0) }
    )
    let okM = await okVM.startAsync(title: "Notify me")
    await okVM.stopAsync()
    check(okVM.meetings.first(where: { $0.id == okM.id })?.status == .summarized, "success: meeting summarized")
    check(okRec.notes.count == 1, "success: exactly one notification posted")
    check(okRec.notes.first?.isError == false, "success: notification is not an error")
    check(okRec.notes.first?.body.contains("roadmap") == true, "success: body carries the summary line")
    check(okRec.notes.first?.title == "Notify me", "success: notification titled with the meeting")

    // --- failure → exactly one error notification with the reason ---
    let badDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcriber-notif-bad-\(UUID().uuidString)")
    RecordingsDirectory.baseDirectory = { badDir }
    let badFile = badDir.appendingPathComponent("meetings.json")
    let badRec = NotifRecorder()
    let badVM = TranscriberViewModel(
        capture: RecordingAudioCapture(directory: badDir),
        processor: FakeProcessor(shouldThrow: ModelError.notFound("whisper-base")),
        settings: AppSettings(),
        settingsStore: SettingsStore.inMemory(),
        meetingStore: MeetingStore(url: badFile),
        notifier: { badRec.add($0) }
    )
    let badM = await badVM.startAsync(title: "Will break")
    await badVM.stopAsync()
    check(badVM.meetings.first(where: { $0.id == badM.id })?.status == .failed, "failure: meeting failed")
    check(badRec.notes.count == 1, "failure: exactly one notification posted")
    check(badRec.notes.first?.isError == true, "failure: notification flagged as an error")
    check(badRec.notes.first?.body.contains("retry") == true, "failure: body points to retry")

    // --- notifyOnSummary off → no notification even on success ---
    let offDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcriber-notif-off-\(UUID().uuidString)")
    RecordingsDirectory.baseDirectory = { offDir }
    let offFile = offDir.appendingPathComponent("meetings.json")
    let offRec = NotifRecorder()
    let offVM = TranscriberViewModel(
        capture: RecordingAudioCapture(directory: offDir),
        processor: FakeProcessor(),
        settings: AppSettings(notifyOnSummary: false),
        settingsStore: SettingsStore.inMemory(),
        meetingStore: MeetingStore(url: offFile),
        notifier: { offRec.add($0) }
    )
    let offM = await offVM.startAsync(title: "Quiet")
    await offVM.stopAsync()
    check(offVM.meetings.first(where: { $0.id == offM.id })?.status == .summarized, "off: meeting still summarized")
    check(offRec.notes.isEmpty, "off: no notification posted when notifyOnSummary is off")
} catch {
    check(false, "notification: \(error)")
}

// MARK: - Storage directory (pure resolve)
section("storage: StorageDirectory resolves the data root")

// New settings → Documents/Transcriber. Resolve only; never write there.
let sdDefault = AppSettings()
let sdDefaultBase = StorageDirectory.base(settings: sdDefault)
check(
    sdDefaultBase == FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Transcriber", isDirectory: true),
    "default: base is Documents/Transcriber"
)
let sdLegacy = AppSettings(storageDirectory: nil)
check(StorageDirectory.base(settings: sdLegacy) == FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appendingPathComponent("Transcriber", isDirectory: true), "legacy: nil storage keeps Application Support history accessible")
check(
    StorageDirectory.meetingsURL(settings: sdDefault).lastPathComponent == "meetings.json",
    "default: meetingsURL is <base>/meetings.json"
)
check(
    StorageDirectory.recordingsURL(settings: sdDefault).lastPathComponent == "recordings",
    "default: recordingsURL is <base>/recordings"
)
// meetings.json and recordings live under the same base.
check(
    StorageDirectory.meetingsURL(settings: sdDefault).deletingLastPathComponent()
        == StorageDirectory.recordingsURL(settings: sdDefault).deletingLastPathComponent(),
    "default: meetings + recordings share the same base directory"
)

// Custom storageDirectory → that directory is the base verbatim.
let sdCustomDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("transcriber-storage-\(UUID().uuidString)")
let sdCustom = AppSettings(storageDirectory: sdCustomDir)
check(
    StorageDirectory.base(settings: sdCustom) == sdCustomDir,
    "custom: base is the user's directory verbatim"
)
check(
    StorageDirectory.meetingsURL(settings: sdCustom)
        == sdCustomDir.appendingPathComponent("meetings.json"),
    "custom: meetings.json is inside the user's directory"
)
check(
    StorageDirectory.recordingsURL(settings: sdCustom).path
        == sdCustomDir.appendingPathComponent("recordings").path,
    "custom: recordings is inside the user's directory"
)
// Custom base differs from the Documents default.
check(
    StorageDirectory.base(settings: sdCustom) != StorageDirectory.base(settings: sdDefault),
    "custom: base differs from the default"
)

// MARK: - Final review regressions
section("hardening: fresh storage, backup recovery, and old meeting files")
do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcriber-final-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("nested/meetings.json")
    let first = Meeting(title: "First", status: .summarized, startedAt: .distantPast,
                        createdAt: .distantPast, lastActivityAt: .distantPast,
                        summary: MeetingSummary(overall: "Persisted"))
    let store = MeetingStore(url: url)
    check(store.save([first]), "first save creates missing parent directories")
    check(MeetingStore(url: url).load() == [first], "fresh store reads durable summary")
    check(store.save([]), "next save succeeds")
    try Data("broken".utf8).write(to: url)
    check(MeetingStore(url: url).load() == [first], "corrupt live file recovers previous good backup")
    check(MeetingStore(url: url).save([first]), "save repairs corrupt live file")
    check(MeetingStore(url: url.appendingPathExtension("bak")).load() == [first], "repair preserves valid backup")
    let settingsURL = root.appendingPathComponent("new/settings.json")
    SettingsStore(url: settingsURL).save(AppSettings(captureSystem: false))
    check(!SettingsStore(url: settingsURL).load().captureSystem, "settings save creates missing directory")
    let old = try JSONDecoder().decode(Meeting.self, from: Data(#"{"title":"Legacy"}"#.utf8))
    check(old.title == "Legacy" && old.transcript.isEmpty && old.failureReason == nil, "old meeting fields decode with defaults")
    let memoryStore = MeetingStore.inMemory()
    memoryStore.save([first])
    check(!FileManager.default.fileExists(atPath: memoryStore.fileURL.path), "inMemory save never writes a backing file")
} catch { check(false, "storage regressions: \(error)") }

section("hardening: real Deepgram response and endpoint")
do {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("dg-final-\(UUID().uuidString).wav")
    try Data([1, 2]).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let response = Data(#"{"results":{"channels":[{"alternatives":[{"words":[{"word":"hello","punctuated_word":"Hello,","start":0,"end":0.4,"speaker":0},{"word":"yes","start":0.8,"end":1.3,"speaker":1}]}]}]}}"#.utf8)
    let http = FakeHTTP(status: 200, body: response)
    let segments = try await DeepgramTranscriber(apiKey: { "test" }, http: http)
        .transcribe(audio: CapturedAudio(fileURLs: [.mic: file]), language: "en-US")
    check(segments.map(\.speaker) == ["Speaker 1", "Speaker 2"], "numeric speakers remain distinct")
    check(segments.first?.text == "Hello,", "word punctuation preserved")
    check(segments.last?.endOffset == 1.3, "uses real end timestamp")
    check(http.lastRequest?.url.path == "/v1/listen", "posts to the real listen endpoint without extra path")
    check(URLComponents(url: http.lastRequest!.url, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "language", value: "en-US")) == true, "language uses URL query encoding")
} catch { check(false, "Deepgram regressions: \(error)") }

section("hardening: capture settings and artifact failures")
do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcriber-capture-final-\(UUID().uuidString)")
    RecordingsDirectory.baseDirectory = { root }
    defer { RecordingsDirectory.baseDirectory = { suiteRecordings }; try? FileManager.default.removeItem(at: root) }
    let vm = TranscriberViewModel(capture: RecordingAudioCapture(directory: root), processor: FakeProcessor(),
        settings: AppSettings(captureSystem: false, keepAudioAfterSummary: true), meetingStore: .inMemory())
    let meeting = await vm.startAsync(title: "Mic only")
    let duplicate = await vm.startAsync(title: "Must not replace")
    check(duplicate.id == meeting.id && vm.meetings.count == 1, "a second Start keeps the original capture")
    vm.delete(id: meeting.id)
    check(vm.meetings.count == 1, "cannot delete a running capture")
    await vm.stopAsync()
    let stored = vm.meeting(id: meeting.id)!
    check(stored.audioFileURLs[.mic] != nil && stored.audioFileURLs[.system] == nil, "start honors microphone-only settings")
    let micFile = stored.audioFileURLs[.mic]!
    vm.delete(id: meeting.id)
    check(vm.meetings.isEmpty && !FileManager.default.fileExists(atPath: micFile.path), "delete removes retained audio immediately")

    struct FailingArtifacts: MeetingArtifactManaging {
        func sweep(liveIDs: Set<UUID>) -> [URL] { [] }
        func remove(_ urls: [URL]) throws { throw CocoaError(.fileWriteNoPermission) }
        func removeEmptyDirectory(for id: UUID) throws {}
        func discard(_ meeting: Meeting) throws { throw CocoaError(.fileWriteNoPermission) }
    }
    let cleanupStore = MeetingStore.inMemory()
    let failedVM = TranscriberViewModel(capture: RecordingAudioCapture(directory: root), processor: FakeProcessor(),
        meetingStore: cleanupStore, artifacts: FailingArtifacts())
    let failedMeeting = await failedVM.startAsync(title: "Cleanup failure")
    await failedVM.stopAsync()
    let failedRecord = failedVM.meeting(id: failedMeeting.id)!
    check(failedRecord.status == .failed && !failedRecord.audioFileURLs.isEmpty, "cleanup failure retains file references for retry")
    check(failedRecord.failureReason != nil, "failure reason is stored with its meeting")
    failedVM.delete(id: failedMeeting.id)
    check(failedVM.meetings.count == 1, "failed file deletion preserves meeting record")
    let recovered = TranscriberViewModel(capture: RecordingAudioCapture(directory: root),
        settings: AppSettings(keepAudioAfterSummary: true), meetingStore: cleanupStore)
    check(recovered.meeting(id: failedMeeting.id)?.status == .summarized, "startup resumes pending cleanup using the saved summary")
    check(recovered.meeting(id: failedMeeting.id)?.pendingArtifactDeletion.isEmpty == true, "recovered cleanup clears its persisted decision")
    check(failedRecord.audioFileURLs.values.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "recovery honors the original deletion decision after settings change")

    let badStore = root.appendingPathComponent("history")
    let saveVM = TranscriberViewModel(capture: RecordingAudioCapture(directory: root), processor: FakeProcessor(),
        meetingStore: MeetingStore(url: badStore.appendingPathComponent("meetings.json")))
    let saveMeeting = await saveVM.startAsync(title: "Save failure")
    try FileManager.default.removeItem(at: badStore)
    try Data().write(to: badStore)
    await saveVM.stopAsync()
    let saveRecord = saveVM.meeting(id: saveMeeting.id)!
    check(saveRecord.status == .failed, "failed durable save fails the meeting")
    check(saveRecord.audioFileURLs.values.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "failed durable save does not destroy audio")
    let blockedRetry = await saveVM.retry(id: saveMeeting.id)
    check(!blockedRetry && saveRecord.audioFileURLs.values.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "retry cannot delete audio while its summary is still unsaved")
    saveVM.delete(id: saveMeeting.id)
    check(saveVM.meeting(id: saveMeeting.id) != nil, "failed history deletion leaves a visible record to retry")
} catch { check(false, "capture regressions: \(error)") }

section("hardening: search includes decisions and action items")
do {
    let engine = MeetingEngine()
    let m = engine.start(title: "Planning")
    engine.markSummarized(id: m.id, summary: MeetingSummary(overall: "Next week", decisions: ["Use SQLite"], actionItems: ["Alex: prepare budget"]), speakerCount: 1)
    check(engine.search("sqlite").count == 1, "search finds decisions")
    check(engine.search("budget").count == 1, "search finds action items")
}

section("hardening: local summaries cover the middle of long meetings")
do {
    let source = [TranscriptSegment(speaker: "S1", text: String(repeating: "opening ", count: 100)),
                  TranscriptSegment(speaker: "S2", text: "MIDDLE DECISION: launch on Friday."),
                  TranscriptSegment(speaker: "S1", text: String(repeating: "closing ", count: 100))]
    let chunks = ChunkingSummarizer.chunks(source, budget: 256)
    check(chunks.count > 1, "long transcript is split into multiple requests")
    check(chunks.allSatisfy { Summary.transcriptText($0).count <= 256 }, "every chunk fits the local budget")
    check(chunks.flatMap { $0 }.map(\.text).joined() == source.map(\.text).joined(), "chunking preserves all speech, including the middle")
    struct EchoSummary: Summarizer {
        func summarize(segments: [TranscriptSegment], title: String) async throws -> MeetingSummary {
            MeetingSummary(overall: segments.map(\.text).joined(), decisions: ["One shared decision"], model: "test")
        }
    }
    let summary = try await ChunkingSummarizer(inner: EchoSummary(), transcriptBudget: 256).summarize(segments: source, title: "Long meeting")
    check(summary.overall.contains("MIDDLE DECISION"), "long local summary includes the middle section")
    check(summary.decisions == ["One shared decision"], "merging removes repeated decisions")
    check(!summary.transcriptWasCapped, "complete section summaries are not marked truncated")
    let unicode = [TranscriptSegment(speaker: "話者", text: String(repeating: "こんにちは🌍", count: 200))]
    check(ChunkingSummarizer.chunks(unicode, budget: 256).flatMap { $0 }.map(\.text).joined() == unicode[0].text, "Unicode chunking preserves characters")
} catch { check(false, "chunked summary: \(error)") }

section("hardening: empty speech does not proceed to a destructive success")
do {
    struct SilentTranscriber: Transcriber {
        func transcribe(audio: CapturedAudio, language: String) async throws -> [TranscriptSegment] { [] }
    }
    struct UnexpectedSummarizer: Summarizer {
        func summarize(segments: [TranscriptSegment], title: String) async throws -> MeetingSummary {
            check(false, "silent recording must not reach the summarizer")
            return MeetingSummary(overall: "Invented")
        }
    }
    let pipeline = PipelineProcessor(transcriber: SilentTranscriber(), diarizer: IdentityDiarizer(), summarizer: UnexpectedSummarizer())
    let meeting = Meeting(title: "Silent", startedAt: .distantPast, createdAt: .distantPast, lastActivityAt: .distantPast)
    do {
        _ = try await pipeline.process(meeting: meeting, audio: CapturedAudio(), report: { _ in })
        check(false, "empty transcription must fail")
    } catch let error as LLMError {
        check(error.message.contains("No speech"), "empty transcription gives a retryable explanation")
    }
} catch { check(false, "silent pipeline: \(error)") }

section("hardening: cancellation preserves audio for retry")
do {
    struct SlowProcessor: MeetingProcessor {
        func process(meeting: Meeting, audio: CapturedAudio, report: @Sendable (ProcessingProgress) -> Void) async throws -> ProcessedResult {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return ProcessedResult(segments: [], summary: MeetingSummary(overall: "Should not complete"))
        }
    }
    let vm = TranscriberViewModel(capture: RecordingAudioCapture(directory: suiteRecordings), processor: SlowProcessor(), meetingStore: .inMemory())
    let m = await vm.startAsync(title: "Cancel me")
    let task = Task { await vm.stopAsync() }
    while vm.progressByMeeting[m.id] == nil { await Task.yield() }
    vm.cancelProcessing(id: m.id)
    await task.value
    let cancelled = vm.meeting(id: m.id)!
    check(cancelled.status == .failed, "cancelled pipeline becomes retryable")
    check(cancelled.failureReason?.contains("cancelled") == true, "cancelled meeting explains what happened")
    check(!cancelled.audioFileURLs.isEmpty && cancelled.audioFileURLs.values.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "cancellation preserves source audio")
    check(vm.progressByMeeting[m.id] == nil, "cancelled meeting clears its progress")
}

section("hardening: provider defaults and invalid summary responses")
do {
    let vm = TranscriberViewModel(capture: RecordingAudioCapture(directory: suiteRecordings), settingsStore: .inMemory())
    vm.updateSettings { $0.summaryBackend = .anthropic }
    check(vm.settings.summaryModel == "claude-haiku-4-5", "switching providers selects a compatible model")
    vm.updateSettings { $0.summaryBackend = .openai; $0.summaryModel = "custom-model" }
    check(vm.settings.summaryModel == "custom-model", "explicit custom model is preserved")
    for invalid in ["", "{\"overall\":\"truncated", "{}"] {
        do { _ = try Summary.parseResponse(invalid); check(false, "invalid model response must fail") }
        catch { check(true, "invalid model response preserves retry path") }
    }
    let fallback = try Summary.parseResponse("The team agreed to launch Friday.")
    check(fallback.overall.contains("Friday"), "plain-text summary fallback remains supported")
    let store = MeetingStore(url: suiteRoot.appendingPathComponent("backup/meetings.json"))
    let failed = Meeting(title: "Private", status: .failed, startedAt: .distantPast, createdAt: .distantPast, lastActivityAt: .distantPast,
                         transcript: [TranscriptSegment(speaker: "S1", text: "private transcript")])
    store.save([failed])
    store.save([], sanitizeBackup: true)
    let backup = MeetingStore(url: store.fileURL.appendingPathExtension("bak")).load()
    check(backup.isEmpty, "delete also removes retained transcripts from the backup")
} catch { check(false, "final regressions: \(error)") }

try? FileManager.default.removeItem(at: suiteRoot)

section("hardening: local word timing becomes readable utterances")
do {
    let words = [TranscriptSegment(speaker: "S1", text: "Hello", startOffset: 0, endOffset: 0.4),
                 TranscriptSegment(speaker: "S1", text: "there.", startOffset: 0.5, endOffset: 0.9),
                 TranscriptSegment(speaker: "S1", text: "Next", startOffset: 3, endOffset: 3.5)]
    let utterances = TranscriptSegment.utterances(from: words)
    check(utterances.map(\.text) == ["Hello there.", "Next"], "words are grouped into readable utterances")
    check(utterances[0].startOffset == 0 && utterances[0].endOffset == 0.9 && utterances[1].startOffset == 3, "utterances preserve actual timing and pauses")
}

section("hardening: a new capture cannot replace a session being stopped")
actor StopGate {
    var continuation: CheckedContinuation<CapturedAudio, Never>?
    var observers: [CheckedContinuation<Void, Never>] = []
    func stop() async -> CapturedAudio {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for observer in observers { observer.resume() }
            observers = []
        }
    }
    func waitUntilStopping() async {
        if continuation != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func finish() { continuation?.resume(returning: CapturedAudio()); continuation = nil }
}
struct GatedSession: AudioCaptureSession {
    let gate: StopGate
    func stop() async throws -> CapturedAudio { await gate.stop() }
}
struct GatedCapture: AudioCapture {
    let gate: StopGate
    var status: [AudioSource: AudioCaptureError] { [:] }
    func level(_ source: AudioSource) -> Float { 0 }
    func start(sources: Set<AudioSource>, directory: URL) async throws -> AudioCaptureSession { GatedSession(gate: gate) }
}
do {
    let gate = StopGate()
    let vm = TranscriberViewModel(capture: GatedCapture(gate: gate), processor: FakeProcessor(), meetingStore: .inMemory())
    let original = await vm.startAsync(title: "Original")
    let stopping = Task { await vm.stopAsync() }
    await gate.waitUntilStopping()
    check(vm.isStopping, "capture finalization is visible to UI controls")
    let replacement = await vm.startAsync(title: "Must wait")
    check(replacement.id == original.id && vm.meetings.count == 1, "Start during Stop keeps the original session")
    await gate.finish()
    await stopping.value
    check(!vm.isStopping && vm.meeting(id: original.id)?.status == .summarized, "original capture finishes normally and releases the guard")
}

section("hardening: a completed summary cannot release a newer Stop guard")
actor FirstPipelineGate: MeetingProcessor {
    var first = true
    var continuation: CheckedContinuation<ProcessedResult, Never>?
    var observers: [CheckedContinuation<Void, Never>] = []
    let result = ProcessedResult(segments: [], summary: MeetingSummary(overall: "Saved"))
    func process(meeting: Meeting, audio: CapturedAudio, report: @Sendable (ProcessingProgress) -> Void) async throws -> ProcessedResult {
        guard first else { return result }
        first = false
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            for observer in observers { observer.resume() }
            observers = []
        }
    }
    func waitUntilProcessing() async {
        if continuation != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func finish() { continuation?.resume(returning: result); continuation = nil }
}
do {
    let captureGate = StopGate()
    let pipelineGate = FirstPipelineGate()
    let vm = TranscriberViewModel(capture: GatedCapture(gate: captureGate), processor: pipelineGate, meetingStore: .inMemory())
    let first = await vm.startAsync(title: "First")
    let firstStop = Task { await vm.stopAsync() }
    await captureGate.waitUntilStopping()
    await captureGate.finish()
    await pipelineGate.waitUntilProcessing()
    check(!vm.isStopping, "processing releases the capture guard for the next meeting")
    let second = await vm.startAsync(title: "Second")
    let secondStop = Task { await vm.stopAsync() }
    await captureGate.waitUntilStopping()
    await pipelineGate.finish()
    await firstStop.value
    check(vm.isStopping, "finishing an older pipeline cannot clear the newer capture guard")
    let third = await vm.startAsync(title: "Must wait for second")
    check(third.id == second.id && vm.meetings.count == 2, "Start remains blocked even after the older pipeline clears active state")
    await captureGate.finish()
    await secondStop.value
    check(vm.meeting(id: first.id)?.status == .summarized && vm.meeting(id: second.id)?.status == .summarized, "both back-to-back meetings finish without losing a session")
}

// MARK: - Report
print("\n\(passed) passed, \(failed) failed")
if failed > 0 {
    exit(1)
}

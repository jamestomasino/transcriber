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
    var processRan = false
    let vm = TranscriberViewModel(engine: vmEngine, capture: vmCap) { _ in processRan = true }

    let m = await vm.startAsync(title: "VM Meeting")
    check(vm.isRecording, "VM reports recording after start")
    check(vmEngine.active?.id == m.id, "engine has the active meeting")

    await vm.stopAsync()
    check(vmEngine.meeting(id: m.id)!.status == .processing, "meeting is processing after stop")
    let files = vmEngine.meeting(id: m.id)!.audioFileURLs
    check(files.count == 2, "audioFileURLs recorded (mic + system)")
    check(files[.mic] != nil, "mic file URL recorded")
    check(files[.system] != nil, "system file URL recorded")
    check(files[.mic]!.lastPathComponent == "mic.wav", "mic file named correctly")
    check(processRan, "process pipeline was invoked")
} catch {
    check(false, "VM start/stop: \(error)")
}
RecordingsDirectory.baseDirectory = nil
try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
    .appendingPathComponent("transcriber-vm-\(UUID().uuidString)", isDirectory: true))

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
    var status: [AudioSource: AudioCaptureError] { lock.lock(); defer { lock.unlock() }; return _status }
    func level(_ source: AudioSource) -> Float { 0.5 }
    func start(sources: Set<AudioSource>, directory: URL) async throws -> AudioCaptureSession {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if sources.contains(.system) {
            lock.lock(); _status[.system] = .screenRecordingNotAuthorized; lock.unlock()
        }
        return PartialSession(directory: directory, sources: sources)
    }
}

final class PartialSession: AudioCaptureSession, @unchecked Sendable {
    private let directory: URL
    private let sources: Set<AudioSource>
    private var stopped = false
    init(directory: URL, sources: Set<AudioSource>) { self.directory = directory; self.sources = sources }
    func stop() async throws -> CapturedAudio {
        if stopped { return CapturedAudio() }
        stopped = true
        var urls: [AudioSource: URL] = [:]
        for source in sources where source == .mic {
            let url = directory.appendingPathComponent("mic.wav")
            try Data().write(to: url)
            urls[.mic] = url
        }
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
    let pvm = TranscriberViewModel(engine: pEngine, capture: pCap) { _ in }

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

    // Stopping still finalizes the mic file.
    await pvm.stopAsync()
    check(pEngine.meeting(id: pm.id)!.audioFileURLs[.mic] != nil, "mic file still recorded on stop")
    check(pEngine.meeting(id: pm.id)!.audioFileURLs[.system] == nil, "no system file (it failed)")
} catch {
    check(false, "partial-failure VM: \(error)")
}
RecordingsDirectory.baseDirectory = nil

// MARK: - Report
print("\n\(passed) passed, \(failed) failed")
if failed > 0 {
    exit(1)
}

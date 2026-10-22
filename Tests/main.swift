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

// MARK: - Report
print("\n\(passed) passed, \(failed) failed")
if failed > 0 {
    exit(1)
}

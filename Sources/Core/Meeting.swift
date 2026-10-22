import Foundation

// MARK: - Domain model (pure, no I/O)
//
// This is the shared vocabulary for the app. It stays in Core so it is
// deterministic and unit-testable, exactly like the base repo's `TimeEntry`.
// Nothing here imports AVFoundation, CoreAudio, Speech, or the network.

/// Where a captured audio sample came from.
public enum AudioSource: String, Codable, CaseIterable, Sendable {
    case mic
    case system
}

/// Lifecycle of a single meeting.
public enum MeetingStatus: String, Codable, Sendable {
    case recording
    case processing
    case summarized
    case failed
}

/// One attributed utterance in a transcript.
public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var speaker: String
    public var text: String
    public var startOffset: TimeInterval
    public var endOffset: TimeInterval

    public init(
        speaker: String,
        text: String,
        startOffset: TimeInterval = 0,
        endOffset: TimeInterval = 0
    ) {
        self.speaker = speaker
        self.text = text
        self.startOffset = startOffset
        self.endOffset = endOffset
    }
}

/// The structured summary of a meeting — the only artifact we keep by default.
public struct MeetingSummary: Codable, Equatable, Sendable {
    public var overall: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [String]
    public var generatedAt: Date
    public var model: String

    public init(
        overall: String,
        keyPoints: [String] = [],
        decisions: [String] = [],
        actionItems: [String] = [],
        generatedAt: Date = Date(timeIntervalSince1970: 0),
        model: String = ""
    ) {
        self.overall = overall
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.generatedAt = generatedAt
        self.model = model
    }
}

/// A meeting: the recording, its (transient) transcript, and its (retained)
/// summary. Decodable with lenient defaults so files written by older builds
/// still load (mirrors the base repo's `TimeEntry` decoding strategy).
public struct Meeting: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var status: MeetingStatus
    public var startedAt: Date
    public var stoppedAt: Date?
    public var duration: TimeInterval
    public var createdAt: Date
    public var lastActivityAt: Date

    // Transient until summarized (cleared after a successful summary).
    public var audioFileURLs: [AudioSource: URL]
    public var transcript: [TranscriptSegment]
    public var speakerCount: Int

    // Retained.
    public var summary: MeetingSummary?

    public init(
        id: UUID = UUID(),
        title: String,
        status: MeetingStatus = .recording,
        startedAt: Date,
        stoppedAt: Date? = nil,
        duration: TimeInterval = 0,
        createdAt: Date,
        lastActivityAt: Date,
        audioFileURLs: [AudioSource: URL] = [:],
        transcript: [TranscriptSegment] = [],
        speakerCount: Int = 0,
        summary: MeetingSummary? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.duration = duration
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.audioFileURLs = audioFileURLs
        self.transcript = transcript
        self.speakerCount = speakerCount
        self.summary = summary
    }
}

// MARK: - Clock (determinism under test)
//
// Same shape as the base repo: a protocol the engine depends on, a
// `SystemClock` for production, and a hand-advanceable `ManualClock` in tests.

public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

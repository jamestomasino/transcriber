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
    /// True when the transcript was so long it was capped before the LLM call,
    /// so this summary reflects only the opening + closing (the middle was
    /// omitted). Persisted with the summary because the transcript itself is
    /// deleted by default — this is the durable record that the view is partial.
    public var transcriptWasCapped: Bool

    public init(
        overall: String,
        keyPoints: [String] = [],
        decisions: [String] = [],
        actionItems: [String] = [],
        generatedAt: Date = Date(timeIntervalSince1970: 0),
        model: String = "",
        transcriptWasCapped: Bool = false
    ) {
        self.overall = overall
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.generatedAt = generatedAt
        self.model = model
        self.transcriptWasCapped = transcriptWasCapped
    }

    // Lenient decoding: a file written by an older build (without
    // transcriptWasCapped) still loads, defaulting to false.
    private enum CodingKeys: String, CodingKey {
        case overall, keyPoints, decisions, actionItems, generatedAt, model
        case transcriptWasCapped
    }

    public init(from decoder: Decoder) throws {
        let d = try decoder.container(keyedBy: CodingKeys.self)
        overall = try d.decode(String.self, forKey: .overall)
        keyPoints = try d.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        decisions = try d.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actionItems = try d.decodeIfPresent([String].self, forKey: .actionItems) ?? []
        generatedAt = try d.decodeIfPresent(Date.self, forKey: .generatedAt) ?? Date(timeIntervalSince1970: 0)
        model = try d.decodeIfPresent(String.self, forKey: .model) ?? ""
        transcriptWasCapped = try d.decodeIfPresent(Bool.self, forKey: .transcriptWasCapped) ?? false
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

// MARK: - Pure text rendering (Core)
//
// Plain-text renderings of a meeting's artifacts. Kept in Core (pure, no I/O)
// so the "Copy" button and the detail view share one deterministic source, and
// so the formatting is unit-testable without SwiftUI or AppKit.

public extension Meeting {
    /// A plain-text rendering of the structured summary (overall + key points +
    /// decisions + action items). Empty string when there is no summary. When
    /// the transcript was capped (very long recording), a note is prepended so
    /// the copied text carries the caveat that this is a partial view.
    func summaryText() -> String {
        guard let s = summary else { return "" }
        var lines: [String] = []
        if s.transcriptWasCapped {
            lines.append("Note: this meeting was long, so the summary reflects only the opening and closing of the transcript (the middle was omitted).")
            lines.append("")
        }
        lines.append(s.overall)
        if !s.keyPoints.isEmpty {
            lines.append("")
            lines.append("Key points:")
            lines += s.keyPoints.map { "• \($0)" }
        }
        if !s.decisions.isEmpty {
            lines.append("")
            lines.append("Decisions:")
            lines += s.decisions.map { "• \($0)" }
        }
        if !s.actionItems.isEmpty {
            lines.append("")
            lines.append("Action items:")
            lines += s.actionItems.map { "• \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    /// A plain-text rendering of the transcript ("Speaker: text" per segment).
    /// Empty string when there is no transcript (e.g. it was deleted by
    /// retention).
    func transcriptText() -> String {
        transcript.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")
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

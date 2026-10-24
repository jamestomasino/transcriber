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

public extension TranscriptSegment {
    /// Turn word timestamps into readable utterances without erasing the
    /// pauses used by the local diarizer to estimate speaker changes.
    static func utterances(from words: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for word in words.sorted(by: { $0.startOffset < $1.startOffset }) {
            guard let previous = result.last,
                  previous.speaker == word.speaker,
                  word.startOffset - previous.endOffset <= 1.5,
                  previous.text.count + word.text.count < 600,
                  !previous.text.hasSuffix("."), !previous.text.hasSuffix("?"), !previous.text.hasSuffix("!") else {
                result.append(word)
                continue
            }
            result[result.count - 1].text += " " + word.text
            result[result.count - 1].endOffset = max(previous.endOffset, word.endOffset)
        }
        return result
    }
}

/// Accumulate recognition snapshots whose timestamps are relative to the same
/// audio request. A recognizer can revise the current utterance or start a new
/// one; the final callback is not necessarily a transcript of the entire file.
public struct TranscriptAccumulator: Sendable {
    public private(set) var words: [TranscriptSegment] = []
    private var snapshotStart: TimeInterval?
    public init() {}

    public mutating func update(_ snapshot: [TranscriptSegment]) {
        let ordered = snapshot.sorted { $0.startOffset < $1.startOffset }
        guard let first = ordered.first else { return }
        // Partial hypotheses can shift their first word's timestamp slightly.
        // Treat nearby starts as revisions, preventing duplicated initial words.
        let cutoff = snapshotStart.map { abs($0 - first.startOffset) < 0.25 ? min($0, first.startOffset) : first.startOffset } ?? first.startOffset
        words = words.filter { $0.startOffset < cutoff && $0.endOffset <= cutoff } + ordered
        snapshotStart = cutoff
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
    public var audioStartOffsets: [AudioSource: TimeInterval]
    public var transcript: [TranscriptSegment]
    public var speakerCount: Int

    // Retained.
    public var summary: MeetingSummary?
    public var failureReason: String?
    public var pendingArtifactDeletion: [URL]

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
        audioStartOffsets: [AudioSource: TimeInterval] = [:],
        transcript: [TranscriptSegment] = [],
        speakerCount: Int = 0,
        summary: MeetingSummary? = nil,
        failureReason: String? = nil,
        pendingArtifactDeletion: [URL] = []
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
        self.audioStartOffsets = audioStartOffsets
        self.transcript = transcript
        self.speakerCount = speakerCount
        self.summary = summary
        self.failureReason = failureReason
        self.pendingArtifactDeletion = pendingArtifactDeletion
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, status, startedAt, stoppedAt, duration, createdAt, lastActivityAt
        case audioFileURLs, audioStartOffsets, transcript, speakerCount, summary, failureReason, pendingArtifactDeletion
    }

    public init(from decoder: Decoder) throws {
        let d = try decoder.container(keyedBy: CodingKeys.self)
        id = try d.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try d.decodeIfPresent(String.self, forKey: .title) ?? "Meeting"
        status = try d.decodeIfPresent(MeetingStatus.self, forKey: .status) ?? .failed
        startedAt = try d.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date(timeIntervalSince1970: 0)
        stoppedAt = try d.decodeIfPresent(Date.self, forKey: .stoppedAt)
        duration = try d.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        createdAt = try d.decodeIfPresent(Date.self, forKey: .createdAt) ?? startedAt
        lastActivityAt = try d.decodeIfPresent(Date.self, forKey: .lastActivityAt) ?? startedAt
        audioFileURLs = try d.decodeIfPresent([AudioSource: URL].self, forKey: .audioFileURLs) ?? [:]
        audioStartOffsets = try d.decodeIfPresent([AudioSource: TimeInterval].self, forKey: .audioStartOffsets) ?? [:]
        transcript = try d.decodeIfPresent([TranscriptSegment].self, forKey: .transcript) ?? []
        speakerCount = try d.decodeIfPresent(Int.self, forKey: .speakerCount) ?? 0
        summary = try d.decodeIfPresent(MeetingSummary.self, forKey: .summary)
        failureReason = try d.decodeIfPresent(String.self, forKey: .failureReason)
        pendingArtifactDeletion = try d.decodeIfPresent([URL].self, forKey: .pendingArtifactDeletion) ?? []
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

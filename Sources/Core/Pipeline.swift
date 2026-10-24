import Foundation

// MARK: - Processing pipeline (Core contracts)
//
// This is the seam the view model depends on for the post-stop pipeline:
// transcribe → (diarize) → summarize. Core defines the *abstractions* and the
// data that flows through them so the whole flow is deterministic and
// unit-testable. The *concrete* backends (Apple Speech, Deepgram, OpenAI,
// Anthropic, whisper.cpp) live in the App layer and are injected in, so Core
// stays pure — it imports nothing but Foundation here.
//
// Three interchangeable seams, composed by `PipelineProcessor`:
//
//   Transcriber  audio → speaker-labeled transcript segments
//   Diarizer     raw segments → speaker-labeled segments (identity if already)
//   Summarizer   segments → structured MeetingSummary
//
// A backend is any of these, or a `MeetingProcessor` directly (e.g. a cloud
// provider that does transcribe+diarize in one call). Tests use `FakeProcessor`
// and the composable pieces; the app uses the App-layer implementations.

/// Which stage of the pipeline is running, for progress UI.
public enum ProcessingStage: String, Codable, CaseIterable, Sendable {
    case transcribing
    case diarizing
    case summarizing
}

/// Progress within the pipeline, reported to the UI while processing.
public struct ProcessingProgress: Equatable, Sendable {
    public var stage: ProcessingStage
    /// 0...1 within the current stage.
    public var fraction: Double

    public init(stage: ProcessingStage, fraction: Double = 0) {
        self.stage = stage
        self.fraction = min(1, max(0, fraction))
    }
}

/// The output of the pipeline: a speaker-labeled transcript and a summary.
public struct ProcessedResult: Equatable, Sendable {
    public var segments: [TranscriptSegment]
    public var summary: MeetingSummary
    public var speakerAttribution: SpeakerAttribution

    public init(segments: [TranscriptSegment], summary: MeetingSummary, speakerAttribution: SpeakerAttribution = .unverified) {
        self.segments = segments
        self.summary = summary
        self.speakerAttribution = speakerAttribution
    }

    /// Number of distinct speakers in the transcript.
    public var speakerCount: Int {
        Set(segments.map { $0.speaker }.filter { $0 != SpeakerAlignment.unknownSpeaker }).count
    }
}

/// The single seam the view model calls. A backend is anything that can turn
/// captured audio into a speaker-labeled transcript + summary, reporting
/// progress as it goes.
public protocol MeetingProcessor: Sendable {
    func process(
        meeting: Meeting,
        audio: CapturedAudio,
        report: @escaping @Sendable (ProcessingProgress) -> Void
    ) async throws -> ProcessedResult
}

/// Pipelines can durably checkpoint an opted-in transcript before summarization.
/// The async acknowledgement prevents a summary failure from losing completed work.
public protocol TranscriptCheckpointingProcessor: MeetingProcessor {
    var speakerAttribution: SpeakerAttribution { get }
    func process(
        meeting: Meeting,
        audio: CapturedAudio,
        report: @escaping @Sendable (ProcessingProgress) -> Void,
        checkpoint: @Sendable ([TranscriptSegment]) async throws -> Void
    ) async throws -> ProcessedResult
}

extension TranscriptCheckpointingProcessor {
    public var speakerAttribution: SpeakerAttribution { .unverified }
}

// MARK: - Component seams

/// Turn captured audio into transcript segments (with speaker labels if the
/// backend can do that).
public protocol Transcriber: Sendable {
    func transcribe(audio: CapturedAudio, language: String) async throws -> [TranscriptSegment]
}

/// Refine raw transcript segments into speaker-labeled ones. A backend that
/// already labels speakers can be the identity diarizer.
public protocol Diarizer: Sendable {
    func diarize(_ segments: [TranscriptSegment]) async throws -> [TranscriptSegment]
}

/// Audio stays behind this injected seam; Core only passes managed source URLs.
public protocol AudioDiarizer: Diarizer {
    func diarize(_ segments: [TranscriptSegment], audio: CapturedAudio,
                 report: @escaping @Sendable (ProcessingProgress) -> Void) async throws -> [TranscriptSegment]
}

public protocol SpeakerReprocessing: MeetingProcessor {
    func reprocessSpeakers(meeting: Meeting, audio: CapturedAudio,
                          report: @escaping @Sendable (ProcessingProgress) -> Void) async throws -> ProcessedResult
}

/// Turn a speaker-labeled transcript into a structured summary.
public protocol Summarizer: Sendable {
    func summarize(segments: [TranscriptSegment], title: String) async throws -> MeetingSummary
}

/// Preparation ownership spans transcription and acoustic matching, then ends
/// before summarization. Platform I/O stays behind these injected operations.
public struct PreparedMeetingAudio: Sendable {
    public let audio: CapturedAudio
    public let cleanup: @Sendable () throws -> Void
    public init(audio: CapturedAudio, cleanup: @escaping @Sendable () throws -> Void = {}) {
        self.audio = audio; self.cleanup = cleanup
    }
}
public protocol PipelineAudioPreparing: Sendable {
    func prepare(_ audio: CapturedAudio) async throws -> PreparedMeetingAudio
}
public protocol MeetingSummarizer: Summarizer {
    func summarize(segments: [TranscriptSegment], title: String, meeting: Meeting) async throws -> MeetingSummary
}

// MARK: - Composable pipeline processor
//
// Runs transcribe → diarize → summarize, reporting progress at each stage.
// This is the default `MeetingProcessor`: it composes the three seams so a
// local backend (Apple Speech + heuristic diarizer + LLM summarizer) and a
// cloud backend (provider transcriber that already diarizes + LLM summarizer)
// both fit the same contract.

public struct PipelineProcessor: TranscriptCheckpointingProcessor, SpeakerReprocessing {
    public let transcriber: any Transcriber
    public let diarizer: any Diarizer
    public let summarizer: any Summarizer
    public let language: String
    public let speakerAttribution: SpeakerAttribution
    public let audioPreparer: (any PipelineAudioPreparing)?
    public let stageAdmission: @Sendable () async throws -> Void

    public init(
        transcriber: any Transcriber,
        diarizer: any Diarizer,
        summarizer: any Summarizer,
        language: String = "",
        speakerAttribution: SpeakerAttribution = .unverified,
        audioPreparer: (any PipelineAudioPreparing)? = nil,
        stageAdmission: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.summarizer = summarizer
        self.language = language
        self.speakerAttribution = speakerAttribution
        self.audioPreparer = audioPreparer
        self.stageAdmission = stageAdmission
    }

    public func process(
        meeting: Meeting,
        audio: CapturedAudio,
        report: @escaping @Sendable (ProcessingProgress) -> Void
    ) async throws -> ProcessedResult {
        try await process(meeting: meeting, audio: audio, report: report, checkpoint: { _ in })
    }

    public func process(
        meeting: Meeting,
        audio: CapturedAudio,
        report: @escaping @Sendable (ProcessingProgress) -> Void,
        checkpoint: @Sendable ([TranscriptSegment]) async throws -> Void
    ) async throws -> ProcessedResult {
        let segments: [TranscriptSegment]
        if !meeting.transcript.isEmpty {
            // Retained transcripts are already diarized. Retry only the failed
            // summary stage rather than repeat a lengthy transcription.
            segments = meeting.transcript
        } else {
            try await stageAdmission()
            let prepared = try await ProcessingMeasurements.measure("audio.preparation") {
                try await audioPreparer?.prepare(audio) ?? PreparedMeetingAudio(audio: audio)
            }
            do {
                // A new capture can begin while preparation is in flight.
                try await stageAdmission()
                report(ProcessingProgress(stage: .transcribing, fraction: 0))
                let raw = try await ProcessingMeasurements.measure("transcription") {
                    try await transcriber.transcribe(audio: prepared.audio, language: language)
                }

                guard raw.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw LLMError("No speech was recognized. Audio was kept; check the sources and language in Settings, then retry.")
                }
                // A recognizer can finish successfully after capturing only a fragment.
                // Do not turn a few words from a long recording into a destructive success.
                let wordCount = raw.reduce(0) { $0 + $1.text.split(whereSeparator: { $0.isWhitespace }).count }
                if meeting.duration >= 15 * 60 && wordCount < 100 {
                    throw LLMError("Very little speech was recognized for this long recording. Audio was kept; check your audio sources and transcription backend in Settings, then retry.")
                }
                try await stageAdmission()
                report(ProcessingProgress(stage: .diarizing, fraction: 0))
                segments = try await ProcessingMeasurements.measure("speaker.analysis") {
                    if let acoustic = diarizer as? any AudioDiarizer {
                        return try await acoustic.diarize(raw, audio: prepared.audio, report: report)
                    }
                    return try await diarizer.diarize(raw)
                }
                try prepared.cleanup()
            } catch { try? prepared.cleanup(); throw error }
        }
        try Task.checkCancellation()
        let cleaned = TranscriptCleanup.deduplicated(segments)
        try await checkpoint(cleaned)
        try await stageAdmission()
        report(ProcessingProgress(stage: .summarizing, fraction: 0))
        let summary = try await ProcessingMeasurements.measure("summary.total") {
            let paragraphs = TranscriptCleanup.paragraphs(cleaned)
            if let contextual = summarizer as? any MeetingSummarizer {
                return try await contextual.summarize(segments: paragraphs, title: meeting.title, meeting: meeting)
            }
            return try await summarizer.summarize(segments: paragraphs, title: meeting.title)
        }

        guard !summary.overall.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              summary.overall != "(no summary produced)" else {
            throw LLMError("The model returned no summary. Audio was kept so you can retry.")
        }
        try Summary.validateDetail(summary, segments: cleaned)
        report(ProcessingProgress(stage: .summarizing, fraction: 1))
        return ProcessedResult(segments: cleaned, summary: summary,
                               speakerAttribution: meeting.transcript.isEmpty ? speakerAttribution : meeting.speakerAttribution)
    }

    public func reprocessSpeakers(meeting: Meeting, audio: CapturedAudio,
                                 report: @escaping @Sendable (ProcessingProgress) -> Void) async throws -> ProcessedResult {
        guard let acoustic = diarizer as? any AudioDiarizer, let summary = meeting.summary else {
            throw LLMError("Speaker-only updates require a local audio diarizer and a saved summary.")
        }
        try await stageAdmission()
        let prepared = try await audioPreparer?.prepare(audio) ?? PreparedMeetingAudio(audio: audio)
        do {
            let segments = try await acoustic.diarize(meeting.transcript, audio: prepared.audio, report: report)
            try prepared.cleanup()
            return ProcessedResult(segments: segments, summary: summary, speakerAttribution: speakerAttribution)
        } catch { try? prepared.cleanup(); throw error }
    }
}

/// Match whole transcript segments by total overlap with acoustic speaker turns.
/// Preserve every word and timestamp; a pause alone never creates an identity.
public struct SpeakerTurn: Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let speaker: Int
    public init(start: TimeInterval, end: TimeInterval, speaker: Int) {
        self.start = start; self.end = end; self.speaker = speaker
    }
}

public enum SpeakerAlignment {
    public static let unknownSpeaker = "Unknown speaker"
    public static func label(_ segments: [TranscriptSegment], turns: [SpeakerTurn]) -> [TranscriptSegment] {
        let valid = turns.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.speaker >= 0 }
            .sorted { $0.start == $1.start ? $0.speaker < $1.speaker : $0.start < $1.start }
        var identities: [Int: Int] = [:]
        for turn in valid where identities[turn.speaker] == nil { identities[turn.speaker] = identities.count + 1 }
        return segments.map { segment in
            var weights: [Int: Double] = [:]
            for turn in valid where turn.start < segment.endOffset && turn.end > segment.startOffset {
                weights[turn.speaker, default: 0] += max(0, min(turn.end, segment.endOffset) - max(turn.start, segment.startOffset))
            }
            let best = weights.keys.sorted {
                weights[$0] == weights[$1] ? identities[$0]! < identities[$1]! : weights[$0]! > weights[$1]!
            }.first
            var copy = segment
            copy.speaker = best.map { "Speaker \(identities[$0]!)" } ?? unknownSpeaker
            return copy
        }
    }
}

// MARK: - Identity diarizer
//
// For backends that already return speaker-labeled segments (most cloud
// providers), diarization is a no-op.

public struct IdentityDiarizer: Diarizer {
    public init() {}
    public func diarize(_ segments: [TranscriptSegment]) async throws -> [TranscriptSegment] {
        segments
    }
}

// MARK: - Heuristic diarizer
//
// Legacy pause grouping, retained for compatibility/testing. These labels
// describe turn groups, not measured speaker identities. Production local
// pipelines use an injected AudioDiarizer with acoustic models instead.
//
// Pure and deterministic, so it is unit-testable in Core.

public struct HeuristicDiarizer: Diarizer {
    /// Segments closer in time than this (seconds) are treated as the same
    /// speaker continuing; a larger gap starts a new speaker.
    public let gapThreshold: TimeInterval

    public init(gapThreshold: TimeInterval = 1.5) {
        self.gapThreshold = gapThreshold
    }

    public func diarize(_ segments: [TranscriptSegment]) async throws -> [TranscriptSegment] {
        guard !segments.isEmpty else { return segments }

        let ordered = segments.sorted { $0.startOffset < $1.startOffset }
        var result: [TranscriptSegment] = []
        var currentSpeaker = 1
        var lastEnd = ordered[0].startOffset

        for seg in ordered {
            // A gap beyond the threshold means (heuristically) a different speaker.
            if seg.startOffset - lastEnd > gapThreshold {
                currentSpeaker += 1
            }
            var labeled = seg
            labeled.speaker = "Speaker \(currentSpeaker)"
            result.append(labeled)
            lastEnd = max(lastEnd, seg.endOffset)
        }
        return result
    }
}

// MARK: - No-op processor
//
// The default processor until the app wires a real one: it does nothing and
// returns an empty result. Keeps the view model's pipeline seam satisfied and
// lets the app start/stop flow work before a backend is chosen.

public struct NoopProcessor: MeetingProcessor {
    public init() {}
    public func process(
        meeting: Meeting,
        audio: CapturedAudio,
        report: @Sendable (ProcessingProgress) -> Void
    ) async throws -> ProcessedResult {
        report(ProcessingProgress(stage: .transcribing, fraction: 0))
        return ProcessedResult(segments: [], summary: MeetingSummary(overall: ""))
    }
}

/// Local models have small context windows. Summarize every section in a fresh
/// session and merge the structured results so the middle of a meeting isn't
/// silently omitted. The section gists stay in chronological order.
public struct ChunkingSummarizer: Summarizer {
    public let inner: any Summarizer
    public let transcriptBudget: Int

    public init(inner: any Summarizer, transcriptBudget: Int = 6_000) {
        self.inner = inner
        self.transcriptBudget = max(256, transcriptBudget)
    }

    public func summarize(segments: [TranscriptSegment], title: String) async throws -> MeetingSummary {
        let chunks = Self.chunks(segments, budget: transcriptBudget)
        var results: [MeetingSummary] = []
        for chunk in chunks {
            try Task.checkCancellation()
            results.append(try await inner.summarize(segments: chunk, title: title))
        }
        guard results.count > 1 else {
            return results.first ?? MeetingSummary(overall: "")
        }
        func unique(_ values: [String]) -> [String] {
            var seen: Set<String> = []
            return values.filter { seen.insert($0).inserted }
        }
        return MeetingSummary(
            overall: results.enumerated().map { "Part \($0.offset + 1): \($0.element.overall)" }.joined(separator: "\n\n"),
            keyPoints: unique(results.flatMap(\.keyPoints)),
            decisions: unique(results.flatMap(\.decisions)),
            actionItems: unique(results.flatMap(\.actionItems)),
            model: unique(results.map(\.model)).joined(separator: ", "),
            transcriptWasCapped: results.contains(where: \.transcriptWasCapped)
        )
    }

    public static func chunks(_ segments: [TranscriptSegment], budget: Int) -> [[TranscriptSegment]] {
        let limit = max(256, budget)
        var chunks: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var size = 0
        for segment in segments {
            // Bound even unusually large speaker labels, preserving the speech.
            var segment = segment
            segment.speaker = String(segment.speaker.prefix(80))
            let overhead = segment.speaker.count + 3
            var remaining = segment.text[...]
            repeat {
                let part = remaining.prefix(limit - overhead)
                var piece = segment
                piece.text = String(part)
                let cost = overhead + part.count
                if !current.isEmpty && size + cost > limit {
                    chunks.append(current); current = []; size = 0
                }
                current.append(piece)
                size += cost
                remaining = remaining.dropFirst(part.count)
            } while !remaining.isEmpty
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

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

    public init(segments: [TranscriptSegment], summary: MeetingSummary) {
        self.segments = segments
        self.summary = summary
    }

    /// Number of distinct speakers in the transcript.
    public var speakerCount: Int {
        Set(segments.map { $0.speaker }).count
    }
}

/// The single seam the view model calls. A backend is anything that can turn
/// captured audio into a speaker-labeled transcript + summary, reporting
/// progress as it goes.
public protocol MeetingProcessor: Sendable {
    func process(
        meeting: Meeting,
        audio: CapturedAudio,
        report: @Sendable (ProcessingProgress) -> Void
    ) async throws -> ProcessedResult
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

/// Turn a speaker-labeled transcript into a structured summary.
public protocol Summarizer: Sendable {
    func summarize(segments: [TranscriptSegment], title: String) async throws -> MeetingSummary
}

// MARK: - Composable pipeline processor
//
// Runs transcribe → diarize → summarize, reporting progress at each stage.
// This is the default `MeetingProcessor`: it composes the three seams so a
// local backend (Apple Speech + heuristic diarizer + LLM summarizer) and a
// cloud backend (provider transcriber that already diarizes + LLM summarizer)
// both fit the same contract.

public struct PipelineProcessor: MeetingProcessor {
    public let transcriber: any Transcriber
    public let diarizer: any Diarizer
    public let summarizer: any Summarizer
    public let language: String

    public init(
        transcriber: any Transcriber,
        diarizer: any Diarizer,
        summarizer: any Summarizer,
        language: String = ""
    ) {
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.summarizer = summarizer
        self.language = language
    }

    public func process(
        meeting: Meeting,
        audio: CapturedAudio,
        report: @Sendable (ProcessingProgress) -> Void
    ) async throws -> ProcessedResult {
        report(ProcessingProgress(stage: .transcribing, fraction: 0))
        let raw = try await transcriber.transcribe(audio: audio, language: language)

        guard raw.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw LLMError("No speech was recognized. Audio was kept; check the sources and language in Settings, then retry.")
        }
        report(ProcessingProgress(stage: .diarizing, fraction: 0))
        let segments = try await diarizer.diarize(raw)

        report(ProcessingProgress(stage: .summarizing, fraction: 0))
        let summary = try await summarizer.summarize(segments: segments, title: meeting.title)

        guard !summary.overall.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              summary.overall != "(no summary produced)" else {
            throw LLMError("The model returned no summary. Audio was kept so you can retry.")
        }
        report(ProcessingProgress(stage: .summarizing, fraction: 1))
        return ProcessedResult(segments: segments, summary: summary)
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
// Apple Speech does not separate speakers. This is the documented local
// fallback: it assigns "Speaker N" labels by grouping consecutive segments
// that are close in time into one speaker and starting a new speaker after a
// gap. It is *best-effort* — accurate speaker ID is a cloud-provider feature —
// but it gives the local path a sane, labeled transcript instead of one blob.
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

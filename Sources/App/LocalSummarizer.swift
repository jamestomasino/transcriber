import Foundation
import FoundationModels

#if canImport(TranscriberCore)
import TranscriberCore
#endif

// MARK: - Local summarizer (on-device Apple Intelligence)
//
// The private, fully-offline summary path. Uses Apple's on-device
// `SystemLanguageModel` (Apple Intelligence) — no API key, no network, no
// model download: the model ships with the OS and runs on the Mac's own
// silicon. This is the summary-side counterpart to `LocalSpeechTranscriber`,
// so a user can run the *entire* app locally (local transcription + local
// summary) with zero cloud dependency.
//
// It reuses the shared Core `Summary.prompt` / `Summary.parse`, so it emits
// exactly the same JSON contract as the OpenAI / Anthropic backends and the
// rest of the pipeline (detail pane, copy, retention) is unchanged.
//
// Lives in the App layer (not Core) because it imports `FoundationModels` —
// Core stays pure Foundation. The framework is gated to macOS 26.0+, so the
// call is wrapped in a `#available` guard and the summarizer degrades to a
// clear, actionable error on older systems (the app still builds and runs on
// macOS 14+; the local option is simply unavailable there).

public struct LocalSummaryError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public final class LocalSummarizer: Summarizer, @unchecked Sendable {
    public init() {}

    public func summarize(segments: [TranscriptSegment], title: String) async throws -> MeetingSummary {
        guard #available(macOS 26.0, *) else {
            throw LocalSummaryError(
                "The local (on-device) summary model needs macOS 26 or later. "
                + "This Mac is on an older system — use the OpenAI or Anthropic backend instead."
            )
        }

        // Build the prompt exactly like the cloud backends (shared prompt + cap),
        // so the model sees the same instructions and the same JSON contract.
        let rawTranscript = Summary.transcriptText(segments)
        let prompt = Summary.prompt(
            title: title,
            transcript: Summary.fitTranscript(rawTranscript)
        )

        let model = SystemLanguageModel()
        guard model.isAvailable else {
            throw LocalSummaryError(
                "Apple Intelligence is not available on this Mac. Enable it in "
                + "System Settings → Apple Intelligence & Siri, or use the OpenAI / Anthropic backend."
            )
        }

        let session = LanguageModelSession(model: model)
        // `GenerationOptions(temperature:)` keeps the summary focused, matching
        // the low temperature the cloud backends use.
        let stream = session.streamResponse(
            to: FoundationModels.Prompt(prompt),
            options: FoundationModels.GenerationOptions(temperature: 0.3)
        )
        let response = try await stream.collect()

        // Parse through the shared lenient parser so a slightly-off local
        // response still yields a usable summary, and carry the "transcript was
        // capped" caveat exactly like the cloud paths.
        return Summary.parse(response.content, transcriptWasCapped: !Summary.transcriptFits(rawTranscript))
    }
}

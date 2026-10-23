import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

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

public struct LocalSummaryError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

public final class LocalSummarizer: Summarizer, @unchecked Sendable {
    public init() {}

    public func summarize(segments: [TranscriptSegment], title: String) async throws -> MeetingSummary {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw LocalSummaryError(
                "The local (on-device) summary model needs macOS 26 or later. "
                + "This Mac is on an older system — use the OpenAI or Anthropic backend instead."
            )
        }

        // Build the prompt exactly like the cloud backends (shared prompt + cap),
        // so the model sees the same instructions and the same JSON contract.
        let rawTranscript = Summary.transcriptText(segments)
        var budget = 8_000
        var fitted = Summary.fitTranscript(rawTranscript, budget: budget)
        var prompt = Summary.prompt(title: String(title.prefix(200)), transcript: fitted)

        let model = SystemLanguageModel()
        guard model.isAvailable else {
            throw LocalSummaryError(
                "Apple Intelligence is not available on this Mac. Enable it in "
                + "System Settings → Apple Intelligence & Siri, or use the OpenAI / Anthropic backend."
            )
        }

        // Retry an overflowing request with a smaller view and a fresh session.
        // Use the original macOS 26 API surface so a 26.0 SDK can still build
        // this path; newer tokenizer APIs aren't present in every usable SDK.
        var content: String
        while true {
            try Task.checkCancellation()
            let session = LanguageModelSession(model: model)
            do {
                let stream = session.streamResponse(
                    to: FoundationModels.Prompt(prompt),
                    options: FoundationModels.GenerationOptions(temperature: 0.3, maximumResponseTokens: 1_024)
                )
                content = try await stream.collect().content
                break
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                guard budget > 256 else {
                    throw LocalSummaryError("This transcript could not fit the local model. Use a cloud summary backend and retry.")
                }
                budget /= 2
                fitted = Summary.fitTranscript(rawTranscript, budget: budget)
                prompt = Summary.prompt(title: String(title.prefix(200)), transcript: fitted)
            }
        }

        // Parse through the shared lenient parser so a slightly-off local
        // response still yields a usable summary, and carry the "transcript was
        // capped" caveat exactly like the cloud paths.
        var summary = try Summary.parseResponse(content, transcriptWasCapped: fitted != rawTranscript)
        summary.model = "Apple Intelligence"
        return summary
        #else
        throw LocalSummaryError("This build does not include Apple Intelligence support. Use OpenAI or Anthropic, or build with a macOS 26 SDK.")
        #endif
    }
}

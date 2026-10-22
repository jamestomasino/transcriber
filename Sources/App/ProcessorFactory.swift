import Foundation

// MARK: - Real model downloader (App)
//
// The App-side `ModelDownloader`: streams a model from its URL to disk. Kept in
// the App layer (not Core) because it uses URLSession. Injected into the Core
// `ModelStore`, which owns the cache/verification logic.

public struct URLSessionModelDownloader: ModelDownloader {
    public init() {}

    public func download(spec: ModelSpec, to destination: URL, report: @Sendable (Double) -> Void) async throws {
        let (tempURL, response) = try await URLSession.shared.download(from: spec.url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelError.downloadFailed(spec.id, "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        report(1.0)
    }
}

// MARK: - Processor factory (App)
//
// The single decision point that turns `AppSettings` into a concrete
// `MeetingProcessor`. This is where the pluggability lives:
//
//   .local     → Apple Speech (on-device, private, no key) + heuristic diarizer
//   .deepgram  → Deepgram Nova (accurate speaker ID, needs a key) + identity diarizer
//
// The summarizer is always an LLM (OpenAI or Anthropic per settings), so the
// summary quality is the same regardless of the transcription backend.
//
// API keys are read lazily from the Keychain through the injected closures, so
// the Core components stay pure and unit-testable.

public enum ProcessorFactory {
    public static func make(settings: AppSettings, http: (any HTTPClient)? = nil) -> any MeetingProcessor {
        // The real pipeline client: the URLSession client (generous timeout so
        // long meetings don't fail mid-upload) wrapped in the retrying
        // decorator, so a transient 429/5xx/network hiccup is retried instead
        // of failing the meeting outright.
        let http = http ?? RetryingHTTPClient(inner: URLSessionHTTPClient())
        let transcriber: any Transcriber
        let diarizer: any Diarizer
        switch settings.transcriptionBackend {
        case .local:
            transcriber = LocalSpeechTranscriber()
            diarizer = HeuristicDiarizer()
        case .deepgram:
            transcriber = DeepgramTranscriber(apiKey: { Keychain.get("deepgram_api_key") }, http: http)
            diarizer = IdentityDiarizer()
        }
        let summarizer: any Summarizer = makeSummarizer(settings: settings, http: http)
        return PipelineProcessor(
            transcriber: transcriber,
            diarizer: diarizer,
            summarizer: summarizer,
            language: settings.language
        )
    }

    public static func makeSummarizer(settings: AppSettings, http: (any HTTPClient)? = nil) -> any Summarizer {
        let http = http ?? RetryingHTTPClient(inner: URLSessionHTTPClient())
        switch settings.summaryBackend {
        case .openai:
            return OpenAISummarizer(model: settings.summaryModel, apiKey: { Keychain.get("openai_api_key") }, http: http)
        case .anthropic:
            return AnthropicSummarizer(model: settings.summaryModel, apiKey: { Keychain.get("anthropic_api_key") }, http: http)
        }
    }
}

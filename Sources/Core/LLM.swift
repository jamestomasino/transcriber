import Foundation

// MARK: - LLM summarizers (Core)
//
// Two interchangeable `Summarizer` backends (OpenAI, Anthropic), both built on
// the Core `HTTPClient` seam + the shared `Summary` prompt/parser. Pure: they
// only import Foundation. The API key is read through an *injected* closure —
// the App wires it to the Keychain, and tests inject a constant — so these are
// unit-testable with a fake HTTP client and no real key.
//
// This is the "summary" half of the pipeline: the LLM does the summarization,
// the transcriber (local Speech or cloud) does the speech-to-text + speaker ID.

public struct LLMError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - OpenAI (chat completions)

public struct OpenAISummarizer: Summarizer {
    public let model: String
    public let apiKey: () -> String?
    public let http: any HTTPClient
    public let baseURL: URL

    public init(
        model: String = "gpt-4o-mini",
        apiKey: @escaping () -> String?,
        http: any HTTPClient,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!
    ) {
        self.model = model
        self.apiKey = apiKey
        self.http = http
        self.baseURL = baseURL
    }

    public func summarize(segments: [TranscriptSegment], title: String) async throws -> MeetingSummary {
        guard let key = apiKey(), !key.isEmpty else {
            throw LLMError("No OpenAI API key set. Add one in Settings → Summary.")
        }
        let rawTranscript = Summary.transcriptText(segments)
        let prompt = Summary.prompt(
            title: title,
            transcript: Summary.fitTranscript(rawTranscript)
        )
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.3,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let resp = try await http.send(HTTPRequest(
            url: baseURL.appendingPathComponent("chat/completions"),
            method: "POST",
            headers: ["Authorization": "Bearer \(key)", "Content-Type": "application/json"],
            body: data
        ))
        guard let obj = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw LLMError("Unexpected OpenAI response shape.")
        }
        return Summary.parse(content, transcriptWasCapped: !Summary.transcriptFits(rawTranscript))
    }
}

// MARK: - Anthropic (messages)

public struct AnthropicSummarizer: Summarizer {
    public let model: String
    public let apiKey: () -> String?
    public let http: any HTTPClient
    public let baseURL: URL

    public init(
        model: String = "claude-3-5-haiku-latest",
        apiKey: @escaping () -> String?,
        http: any HTTPClient,
        baseURL: URL = URL(string: "https://api.anthropic.com/v1")!
    ) {
        self.model = model
        self.apiKey = apiKey
        self.http = http
        self.baseURL = baseURL
    }

    public func summarize(segments: [TranscriptSegment], title: String) async throws -> MeetingSummary {
        guard let key = apiKey(), !key.isEmpty else {
            throw LLMError("No Anthropic API key set. Add one in Settings → Summary.")
        }
        let rawTranscript = Summary.transcriptText(segments)
        let prompt = Summary.prompt(
            title: title,
            transcript: Summary.fitTranscript(rawTranscript)
        )
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [["role": "user", "content": prompt]],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let resp = try await http.send(HTTPRequest(
            url: baseURL.appendingPathComponent("messages"),
            method: "POST",
            headers: [
                "x-api-key": key,
                "anthropic-version": "2023-06-01",
                "Content-Type": "application/json",
            ],
            body: data
        ))
        guard let obj = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              let content = obj["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String
        else {
            throw LLMError("Unexpected Anthropic response shape.")
        }
        return Summary.parse(text, transcriptWasCapped: !Summary.transcriptFits(rawTranscript))
    }
}

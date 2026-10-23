import Foundation

// MARK: - Cloud transcriber (Deepgram Nova, Core)
//
// The accurate-speaker-ID path. Deepgram Nova returns per-channel results with
// speaker labels and word-level timestamps in one call (transcribe + diarize),
// so the pipeline's diarizer is the identity for this backend. Pure: imports
// only Foundation. The API key is read through an *injected* closure (the App
// wires it to the Keychain; tests inject a constant) and HTTP goes through the
// Core `HTTPClient` seam, so it's unit-testable with a fake and no real key.
//
// Swappable for any other provider (AssemblyAI, etc.) behind the same
// `Transcriber` protocol without touching the rest of the app.

public struct DeepgramError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

public struct DeepgramTranscriber: Transcriber {
    public let apiKey: () -> String?
    public let http: any HTTPClient
    public let model: String
    public let baseURL: URL

    public init(
        apiKey: @escaping () -> String?,
        http: any HTTPClient,
        model: String = "nova-2",
        baseURL: URL = URL(string: "https://api.deepgram.com/v1/listen")!
    ) {
        self.apiKey = apiKey
        self.http = http
        self.model = model
        self.baseURL = baseURL
    }

    public func transcribe(audio: CapturedAudio, language: String) async throws -> [TranscriptSegment] {
        guard let key = apiKey(), !key.isEmpty else {
            throw DeepgramError("No Deepgram API key set. Add one in Settings → Transcription (cloud).")
        }
        guard let file = audio.mic ?? audio.system,
              FileManager.default.fileExists(atPath: file.path)
        else {
            return []
        }

        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw DeepgramError("Bad API URL.")
        }
        comps.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "diarize", value: "true"),
        ]
        if !language.isEmpty { comps.queryItems?.append(URLQueryItem(name: "language", value: language)) }
        guard let finalURL = comps.url else { throw DeepgramError("Bad API URL.") }

        // Deepgram accepts a raw audio body. We send the raw file bytes with
        // the right content type — simplest and widely used.
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let resp = try await http.send(HTTPRequest(
            url: finalURL,
            method: "POST",
            headers: [
                "Authorization": "Token \(key)",
                "Content-Type": "application/octet-stream",
                "Accept": "application/json",
            ],
            body: data
        ))

        return try Self.parse(resp.body)
    }

    /// Parse Deepgram's JSON response into speaker-labeled segments.
    /// Shape: { results: { channels: [ { alternatives: [ { transcript,
    ///   words: [ {word, start, dur, speaker} ] } ] } ] } }
    private static func parse(_ body: Data) throws -> [TranscriptSegment] {
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let results = root["results"] as? [String: Any],
              let channels = results["channels"] as? [[String: Any]]
        else {
            throw DeepgramError("Unexpected Deepgram response shape.")
        }

        var segments: [TranscriptSegment] = []
        for channel in channels {
            guard let alts = channel["alternatives"] as? [[String: Any]],
                  let alt = alts.first
            else { continue }

            // Prefer word-level timing + speaker if present.
            if let words = alt["words"] as? [[String: Any]], !words.isEmpty {
                // Group consecutive words that share a speaker into a segment.
                var currentSpeaker: String?
                var currentStart = 0.0
                var currentEnd = 0.0
                var currentText: [String] = []

                func flush() {
                    if let s = currentSpeaker, !currentText.isEmpty {
                        segments.append(TranscriptSegment(
                            speaker: s,
                            text: currentText.joined(separator: " "),
                            startOffset: currentStart,
                            endOffset: currentEnd
                        ))
                    }
                    currentText = []
                }

                for w in words {
                    let word = (w["punctuated_word"] as? String) ?? (w["word"] as? String) ?? ""
                    let start = (w["start"] as? Double) ?? 0.0
                    let dur = (w["dur"] as? Double) ?? 0.0
                    let speaker = (w["speaker"] as? Int).map { "Speaker \($0 + 1)" }
                        ?? (w["speaker"] as? String) ?? "Speaker 1"
                    if speaker != currentSpeaker {
                        flush()
                        currentSpeaker = speaker
                        currentStart = start
                    }
                    currentText.append(word)
                    currentEnd = (w["end"] as? Double) ?? (start + dur)
                }
                flush()
            } else if let transcript = alt["transcript"] as? String,
                      !transcript.trimmingCharacters(in: .whitespaces).isEmpty {
                // No word timing: one segment for the whole channel.
                segments.append(TranscriptSegment(
                    speaker: "Speaker 1",
                    text: transcript,
                    startOffset: 0,
                    endOffset: 0
                ))
            }
        }
        return segments.sorted { $0.startOffset < $1.startOffset }
    }
}

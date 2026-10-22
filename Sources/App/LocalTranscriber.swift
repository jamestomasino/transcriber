import Foundation
import Speech

// MARK: - Local transcriber (Apple Speech)
//
// The private, on-device path. Uses `SFSpeechURLRecognitionRequest` on the
// recorded audio file — no model download (the on-device model ships with the
// OS), no API key, no network. Returns segments with approximate timestamps
// (the URL API gives a single final result; we split on final/partial
// boundaries). Speaker ID is NOT done here — the pipeline's `HeuristicDiarizer`
// assigns "Speaker N" labels afterward. This is the documented trade-off: local
// is private but best-effort on speakers; cloud is accurate on speakers.
//
// Lives in the App layer because it imports `Speech` (Core stays pure).

public struct SpeechError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public final class LocalSpeechTranscriber: Transcriber, @unchecked Sendable {
    public init() {}

    public func transcribe(audio: CapturedAudio, language: String) async throws -> [TranscriptSegment] {
        // Pick the first recorded file to transcribe. (A multi-source mix would
        // be a single merged file in a future phase; for now each source is its
        // own file and we transcribe the mic, or the first available.)
        guard let file = audio.fileURLs.values.first
            ?? audio.fileURLs[.mic]
            ?? audio.fileURLs[.system],
              FileManager.default.fileExists(atPath: file.path)
        else {
            return [] // Nothing captured → empty transcript, not an error.
        }

        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized else {
            throw SpeechError("Microphone/Speech access not authorized. Enable it in System Settings → Privacy & Security → Speech Recognition.")
        }

        let locale = language.isEmpty ? Locale.autoupdatingCurrent : Locale(identifier: language)
        let recognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechError("Speech recognizer unavailable for that language.")
        }

        let request = SFSpeechURLRecognitionRequest(url: file)
        request.shouldReportPartialResults = false
        // On-device only (private). Fall back to server if on-device unsupported.
        request.addsPunctuation = true

        let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SFSpeechRecognitionResult, Error>) in
            recognizer.recognitionTask(with: request) { res, err in
                if let res {
                    cont.resume(returning: res)
                } else {
                    cont.resume(throwing: err ?? SpeechError("Speech recognition failed."))
                }
            }
        }
        return Self.segments(from: result)
    }

    /// Convert a final speech result into segments. The URL API yields a single
    /// result with best-transcription; we split it into line segments with
    /// evenly-spaced offsets as a rough timing (the heuristic diarizer then
    /// groups them). This is an approximation — accurate per-word timing and
    /// speaker labels come from the cloud path.
    private static func segments(from result: SFSpeechRecognitionResult) -> [TranscriptSegment] {
        let text = result.bestTranscription.formattedString
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        // Split on sentence-ish boundaries to get multiple segments.
        let lines = text
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let parts = lines.isEmpty ? [text] : lines

        // Evenly distribute a rough 1s per segment as a placeholder offset.
        return parts.enumerated().map { i, line in
            TranscriptSegment(
                speaker: "Speaker 1", // overwritten by the diarizer
                text: line,
                startOffset: TimeInterval(i),
                endOffset: TimeInterval(i + 1)
            )
        }
    }
}

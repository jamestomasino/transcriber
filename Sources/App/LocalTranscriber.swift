import Foundation
import Speech

#if canImport(TranscriberCore)
import TranscriberCore
#endif

// Apple Speech is strictly on-device. Never fall back to sending local audio
// to Apple's servers when the requested language model is unavailable.

public struct SpeechError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

public final class LocalSpeechTranscriber: Transcriber, @unchecked Sendable {
    public init() {}

    public func transcribe(audio: CapturedAudio, language: String) async throws -> [TranscriptSegment] {
        guard let file = audio.mic ?? audio.system,
              FileManager.default.fileExists(atPath: file.path) else {
            throw SpeechError("No recorded audio is available. Start a new meeting.")
        }
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard status == .authorized else {
            throw SpeechError("Speech access is off. Enable Transcriber in System Settings → Privacy & Security → Speech Recognition, then retry.")
        }

        let locale = language.isEmpty ? Locale.autoupdatingCurrent : Locale(identifier: language)
        let recognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechError("Speech recognizer unavailable for that language.")
        }

        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechError("On-device speech recognition is unavailable for this language. Choose another language or use Deepgram in Settings.")
        }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true

        // Speech can deliver more than one callback even when partial results
        // are disabled. Hold the task and resume the continuation exactly once.
        let state = SpeechRecognitionState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.begin(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        let segments = result.bestTranscription.segments.map { word in
                            TranscriptSegment(speaker: "Speaker 1", text: word.substring,
                                              startOffset: word.timestamp,
                                              endOffset: word.timestamp + word.duration)
                        }
                        state.finish(.success(TranscriptSegment.utterances(from: segments)))
                    } else if let error {
                        state.finish(.failure(error))
                    }
                }
                state.setTask(task)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

private final class SpeechRecognitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[TranscriptSegment], Error>?
    private var task: SFSpeechRecognitionTask?
    private var finished = false

    func begin(_ continuation: CheckedContinuation<[TranscriptSegment], Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func setTask(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        if finished { lock.unlock(); task.cancel() }
        else { self.task = task; lock.unlock() }
    }

    func finish(_ result: Result<[TranscriptSegment], Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        let task = self.task
        self.continuation = nil
        self.task = nil
        lock.unlock()
        continuation?.resume(with: result)
        task?.cancel()
    }

    func cancel() { finish(.failure(CancellationError())) }
}

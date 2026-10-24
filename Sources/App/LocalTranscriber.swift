import Foundation
import Speech
import AVFoundation

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

        let locale = language.isEmpty ? Locale.autoupdatingCurrent : Locale(identifier: language == "en" ? "en-US" : language)
        if #available(macOS 26, *), Speech.SpeechTranscriber.isAvailable {
            guard let supported = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: locale),
                  await Speech.SpeechTranscriber.installedLocales.contains(where: { $0.identifier == supported.identifier }) else {
                throw SpeechError("The long-form on-device speech model is not installed for this language. Choose an installed language or another transcription backend in Settings. Original audio was kept.")
            }
            return try await transcribeWithAnalyzer(file: file, locale: supported)
        }
        let recognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechError("Speech recognizer unavailable for that language.")
        }

        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechError("On-device speech recognition is unavailable for this language. Choose another language or use Deepgram in Settings.")
        }
        return try await Self.transcribeSections(file: file) { section in
            try await self.recognize(file: section, recognizer: recognizer)
        }
    }

    /// The modern file API emits every finalized utterance. The legacy URL
    /// recognizer can report only its last utterance on current macOS releases.
    @available(macOS 26, *)
    private func transcribeWithAnalyzer(file: URL, locale: Locale) async throws -> [TranscriptSegment] {
        let transcriber = Speech.SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                try Task.checkCancellation()
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(TranscriptSegment(speaker: "Speaker 1", text: text,
                    startOffset: result.range.start.seconds,
                    endOffset: (result.range.start + result.range.duration).seconds))
            }
            return segments
        }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let input = try AVAudioFile(forReading: file)
                if let end = try await analyzer.analyzeSequence(from: input) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                let result = try await collector.value
                try Task.checkCancellation()
                return result
            } catch {
                collector.cancel()
                await analyzer.cancelAndFinishNow()
                _ = try? await collector.value
                throw error
            }
        } onCancel: {
            collector.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// Keep each Speech request below its one-minute audio limit. The seam also
    /// lets media checks verify full coverage and cleanup without Speech access.
    static func transcribeSections(
        file: URL,
        recognize: (URL) async throws -> [TranscriptSegment]
    ) async throws -> [TranscriptSegment] {
        let audio = try AVAudioFile(forReading: file)
        let format = audio.processingFormat
        let sectionFrames = AVAudioFramePosition(format.sampleRate * 50)
        if audio.length <= sectionFrames { return try await recognize(file) }
        let sectionURL = file.deletingLastPathComponent().appendingPathComponent(CapturedAudio.speechSectionFileName)
        if FileManager.default.fileExists(atPath: sectionURL.path) { try FileManager.default.removeItem(at: sectionURL) }
        defer { try? FileManager.default.removeItem(at: sectionURL) }
        var segments: [TranscriptSegment] = []
        while audio.framePosition < audio.length {
            try Task.checkCancellation()
            let offset = Double(audio.framePosition) / format.sampleRate
            let count = AVAudioFrameCount(min(sectionFrames, audio.length - audio.framePosition))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                throw SpeechError("Could not prepare audio for speech recognition. Original audio was kept.")
            }
            try audio.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { throw SpeechError("Could not read the complete recording. Original audio was kept.") }
            // Close the writer before handing the section to Speech.
            try writeSection(buffer, to: sectionURL)
            let result = try await recognize(sectionURL)
            segments += result.map { segment in
                var shifted = segment
                shifted.startOffset += offset
                shifted.endOffset += offset
                return shifted
            }
            try FileManager.default.removeItem(at: sectionURL)
        }
        return segments
    }

    private static func writeSection(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let output = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        try output.write(from: buffer)
        if #available(macOS 15, *) { output.close() }
    }

    private func recognize(file: URL, recognizer: SFSpeechRecognizer) async throws -> [TranscriptSegment] {
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true

        // Keep every utterance, including revised hypotheses, and complete only
        // when the delegate reports that the whole recognition task finished.
        let state = SpeechRecognitionState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.begin(continuation)
                let task = recognizer.recognitionTask(with: request, delegate: state)
                state.setTask(task)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

private final class SpeechRecognitionState: NSObject, SFSpeechRecognitionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[TranscriptSegment], Error>?
    private var task: SFSpeechRecognitionTask?
    private var finished = false
    private var transcript = TranscriptAccumulator()

    private func record(_ transcription: SFTranscription) {
        let words = transcription.segments.map {
            TranscriptSegment(speaker: "Speaker 1", text: $0.substring,
                              startOffset: $0.timestamp, endOffset: $0.timestamp + $0.duration)
        }
        lock.lock()
        if !finished { transcript.update(words) }
        lock.unlock()
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didHypothesizeTranscription transcription: SFTranscription) {
        record(transcription)
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition result: SFSpeechRecognitionResult) {
        record(result.bestTranscription)
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
        if successfully {
            lock.lock()
            let words = transcript.words
            lock.unlock()
            finish(.success(TranscriptSegment.utterances(from: words)))
        } else {
            finish(.failure(task.error ?? SpeechError("Speech recognition did not finish. Original audio was kept; retry.")))
        }
    }

    func speechRecognitionTaskWasCancelled(_ task: SFSpeechRecognitionTask) {
        cancel()
    }

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

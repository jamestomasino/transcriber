import Foundation
import AVFoundation

/// Opt-in model validation. Only --meeting reads a real retained recording.
/// Synthetic audio is isolated; real excerpts use the managed transient path.
@main
struct LocalInferenceChecks {
    static func main() async {
        setbuf(stdout, nil)
        do { try await run() } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
    static func run() async throws {
        let arguments = CommandLine.arguments
        let skipWhisper = arguments.contains("--summary-only")
        let skipSummary = arguments.contains("--whisper-only")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcriber-local-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let terms = "pembrolizumab, pharmacokinetics, pharmacovigilance, oncology, phase 3 clinical trial"
        let sentences = [
            "Alex will check the pharmacokinetics data for pembrolizumab by Friday.",
            "Blair will review the phase three oncology trial by Tuesday.",
            "Casey will prepare the pharmacovigilance report by Thursday."
        ]
        var segments = [TranscriptSegment(speaker: "Speaker 1", text: sentences.joined(separator: " "))]
        if !skipWhisper {
            let transcriber = WhisperTranscriber(modelID: WhisperCatalog.defaultID, vocabulary: terms)
            let started = Date()
            if let index = arguments.firstIndex(of: "--meeting"), arguments.indices.contains(index + 1), let id = UUID(uuidString: arguments[index + 1]) {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                let settings = SettingsStore(url: support.appendingPathComponent("Transcriber/settings.json")).load()
                guard let meeting = MeetingStore(url: StorageDirectory.meetingsURL(settings: settings)).load().first(where: { $0.id == id }) else {
                    throw LocalInferenceError("The requested recording was not found.")
                }
                let realTranscriber = WhisperTranscriber(modelID: WhisperCatalog.defaultID, vocabulary: settings.transcriptionVocabulary)
                segments = try await PreparingTranscriber(inner: FirstMinuteTranscriber(inner: realTranscriber))
                    .transcribe(audio: CapturedAudio(fileURLs: meeting.audioFileURLs, startOffsets: meeting.audioStartOffsets), language: settings.language)
                guard segments.reduce(0, { $0 + $1.text.split(separator: " ").count }) >= 20 else { throw LocalInferenceError("The real excerpt produced too little speech") }
                print("✓ Whisper processes a retained meeting excerpt locally without changing the meeting")
            } else {
                let audio = root.appendingPathComponent("pharma.aiff")
                let say = Process()
                say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                say.arguments = ["-o", audio.path, sentences.joined(separator: " [[slnc 1800]] ")]
                try say.run(); say.waitUntilExit()
                guard say.terminationStatus == 0 else { throw LocalInferenceError("Could not generate the pharma fixture") }
                segments = try await transcriber.transcribe(audio: CapturedAudio(fileURLs: [.mic: audio]), language: "en")
                let text = segments.map(\.text).joined(separator: " ").lowercased()
                for term in ["pembrolizumab", "pharmacokinetics", "pharmacovigilance", "friday", "tuesday", "thursday"] {
                    guard text.contains(term) else { throw LocalInferenceError("Whisper fixture did not preserve term: \(term)") }
                }
                print("✓ Whisper Large v3 preserves the fixture's three pharma terms and three deadlines")
            }
            print("Whisper seconds: \(Int(Date().timeIntervalSince(started))); words: \(segments.reduce(0) { $0 + $1.text.split(separator: " ").count })")
        }
        if !skipSummary {
            // Validate known source facts, independent of ASR spelling variance.
            let source = sentences.joined(separator: " ") + " The missing pharmacokinetics dataset is priority P0 because the phase 3 submission depends on it. We agreed to freeze the dataset until quality control is complete. The protocol lists a 50 mg vial. No dosing change was approved."
            let started = Date()
            let summary = try await DownloadedModelSummarizer(modelID: SummaryModelCatalog.defaultID)
                .summarize(segments: [TranscriptSegment(speaker: "Reviewer", text: source)], title: "Pharma review fixture")
            let actions = summary.actionItems.joined(separator: " ").lowercased()
            let notes = ([summary.overall] + summary.keyPoints + summary.decisions + summary.actionItems).joined(separator: " ").lowercased()
            for term in ["alex", "blair", "casey", "friday", "tuesday", "thursday"] {
                guard actions.contains(term) else { throw LocalInferenceError("Local summary lost action detail: \(term)") }
            }
            for term in ["pembrolizumab", "p0", "50 mg"] {
                guard notes.contains(term) else { throw LocalInferenceError("Local summary lost source detail: \(term)") }
            }
            guard !summary.decisions.isEmpty else { throw LocalInferenceError("Local summary lost the explicit decision") }
            print("✓ Local 4B summary preserves actions, owners, dates, priority, drug name, units and decision")
            print("Summary seconds: \(Int(Date().timeIntervalSince(started))); actions: \(summary.actionItems.count); findings: \(summary.keyPoints.count)")
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("Host peak resident memory MB: \(usage.ru_maxrss / 1_048_576)")
    }
}

private struct FirstMinuteTranscriber: Transcriber {
    let inner: any Transcriber
    func transcribe(audio: CapturedAudio, language: String) async throws -> [TranscriptSegment] {
        guard let file = audio.mic ?? audio.system else { throw LocalInferenceError("No audio excerpt is available") }
        let source = try AVAudioFile(forReading: file)
        let samples = try WhisperAudio.readSection(source, seconds: 60)
        guard !samples.isEmpty else { throw LocalInferenceError("The recording contains no audio frames") }
        let temporary = file.deletingLastPathComponent().appendingPathComponent(CapturedAudio.speechSectionFileName)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try write(samples, to: temporary)
        return try await inner.transcribe(audio: CapturedAudio(fileURLs: [.mic: temporary]), language: language)
    }
    private func write(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        let output = try AVAudioFile(forWriting: url, settings: format.settings)
        try output.write(from: buffer)
        if #available(macOS 15, *) { output.close() }
    }
}

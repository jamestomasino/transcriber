import Foundation
import AVFoundation
import Speech
import CoreGraphics

/// Opt-in checks against this Mac's audio capture and on-device model. They
/// request audio permission only with --system-audio and never use cloud keys.
/// All audio stays in a temporary
/// managed recording directory and is removed even if validation throws.
@main
struct LiveChecks {
    static func main() async {
        setbuf(stdout, nil)
        do { try await run() }
        catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcriber-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let speech = root.appendingPathComponent("speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", speech.path, "We agreed to launch the project on Friday. Alex will write the release notes by Thursday."]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw SpeechError("Could not create the spoken fixture") }

        if #available(macOS 14.2, *) {
            if CommandLine.arguments.contains("--system-audio") {
                try await checkSystem(root: root, speech: speech)
            } else {
                print("SKIP live system capture: use --system-audio to opt into audio-only permission and recording")
            }
        } else if CGPreflightScreenCaptureAccess() {
            try await checkSystem(root: root, speech: speech)
        } else {
            print("SKIP live system capture: Screen Recording permission is not granted")
        }

        var segments = [TranscriptSegment(speaker: "Speaker 1", text: "We agreed to launch the project on Friday. Alex will write the release notes by Thursday.")]
        if SFSpeechRecognizer.authorizationStatus() == .authorized {
            segments = try await LocalSpeechTranscriber().transcribe(audio: CapturedAudio(fileURLs: [.mic: speech]), language: "en-US")
            guard !segments.isEmpty else { throw SpeechError("Live Speech produced no transcript") }
            print("✓ Live on-device Speech transcribes the spoken fixture")
        } else {
            print("SKIP live transcription: Speech Recognition permission is not granted; using the known fixture text for summary validation")
        }
        let summary = try await ChunkingSummarizer(inner: LocalSummarizer()).summarize(segments: segments, title: "Release planning")
        print("Fixture notes: \(summary.overall); decisions=\(summary.decisions); actions=\(summary.actionItems)")
        guard !summary.overall.isEmpty, !summary.actionItems.isEmpty else {
            throw SpeechError("Live local model did not return the expected summary and action item")
        }
        print("✓ Live Apple Intelligence returns a structured summary and action item")
        print("Summary: \(summary.overall)")
        if CommandLine.arguments.contains("--detailed-summary") { try await checkDetailedSummary() }
    }
    /// A multi-section audit, with commitments at the start, middle and end.
    /// Opt in separately because local generation can take several minutes.
    static func checkDetailedSummary() async throws {
        let commitments = [
            "We agreed that fixing broken redirects is P0, our highest priority. Alex will repair redirects by Friday because 42 landing pages return errors.",
            "We decided to consolidate duplicate guides rather than publish more pages. Blair will map duplicate guides by Tuesday. This is P1 and depends on the redirect repair.",
            "Casey will add conversion tracking by Thursday. Tracking is P2. The proposed paid campaign was deferred until attribution works. No budget was approved."
        ]
        let segments = commitments.enumerated().map { index, commitment in
            let findings = (1...18).map { page in
                "Audit group \(index + 1), page \(page): the guide has an outdated headline, lacks internal links to its product page, and needs a specific customer example to explain the service."
            }.joined(separator: " ")
            return TranscriptSegment(speaker: "Auditor", text: commitment + " " + findings)
        }
        let summary = try await ChunkingSummarizer(inner: LocalSummarizer()).summarize(segments: segments, title: "LEO SEO ecosystem audit")
        try Summary.validateDetail(summary, segments: segments)
        let actions = summary.actionItems.joined(separator: " ").lowercased()
        for owner in ["alex", "blair", "casey"] {
            guard actions.contains(owner) else { throw SpeechError("Detailed summary lost action owner: \(owner)") }
        }
        let notes = ([summary.overall] + summary.keyPoints + summary.decisions + summary.actionItems).joined(separator: " ").lowercased()
        for detail in ["friday", "tuesday", "thursday", "p0", "p1", "p2", "42"] {
            guard notes.contains(detail) else { throw SpeechError("Detailed summary lost audit detail: \(detail)") }
        }
        guard !summary.transcriptWasCapped else { throw SpeechError("Detailed summary omitted source text") }
        print("✓ Live multi-section audit preserves all three action owners, deadlines, priorities and the page count")
    }

    static func checkSystem(root: URL, speech: URL) async throws {
        let capture = AVAudioCapture()
        let session: any AudioCaptureSession
        do { session = try await capture.start(sources: [.system], directory: root.appendingPathComponent("recordings")) }
        catch {
            if capture.status[.system] == .noDisplayAvailable {
                print("SKIP live system capture: ScreenCaptureKit reports no available display (wake and unlock the display, then retry)")
                return
            }
            throw error
        }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [speech.path]
        try player.run()
        while player.isRunning { try await Task.sleep(nanoseconds: 200_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let audio = try await session.stop()
        guard let file = audio.system else { throw SpeechError("System audio produced no file") }
        let recorded = try AVAudioFile(forReading: file)
        guard recorded.length > 0 else { throw SpeechError("System audio is empty") }
        let buffer = AVAudioPCMBuffer(pcmFormat: recorded.processingFormat, frameCapacity: AVAudioFrameCount(recorded.length))!
        try recorded.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        let audible = (0..<Int(buffer.frameLength)).contains { abs(samples[$0]) > 0.001 }
        guard audible else { throw SpeechError("System recording contains only silence") }
        print("✓ Live system capture records audible system output")
    }

}

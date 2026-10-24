import SwiftUI
import AppKit

/// Explicit AppKit ownership gives snapshots a concrete, laid-out window.
/// Every view uses sample data; no user meeting store or account is opened.
@main
struct PreviewApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = PreviewDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model: TranscriberViewModel?

    private func makeModel() -> TranscriberViewModel {
        let now = Date()
        let meeting = Meeting(title: "Release planning", status: .summarized,
            startedAt: now.addingTimeInterval(-1800), stoppedAt: now, duration: 1800,
            createdAt: now, lastActivityAt: now, speakerCount: 2,
            summary: MeetingSummary(overall: "The team agreed to launch on Friday after completing the release checklist.",
                keyPoints: ["The build is ready for final validation."], decisions: ["Launch on Friday."],
                actionItems: ["Alex: finish release notes by Thursday."], model: "Qwen 3.5 4B"))
        var fixtures = (CommandLine.arguments.contains("--queue") || CommandLine.arguments.contains("--waiting")) ? ["Weekly planning", "Customer check-in", "Project review"].enumerated().map { index, title in
            Meeting(title: title, status: .failed, startedAt: now.addingTimeInterval(Double(-index * 1800)), createdAt: now, lastActivityAt: now.addingTimeInterval(Double(-index)))
        } : (CommandLine.arguments.contains("--empty") ? [] : [meeting])
        if CommandLine.arguments.contains("--failed") || CommandLine.arguments.contains("--resume") {
            var unfinished = meeting
            unfinished.status = .failed; unfinished.summary = nil
            unfinished.transcript = [TranscriptSegment(speaker: "Alex", text: "I’ll finish the release notes by Thursday.")]
            unfinished.failureReason = "The summary service is temporarily unavailable."
            if CommandLine.arguments.contains("--resume") {
                unfinished.processingRequest = ProcessingRequest(settings: AppSettings(), reuseTranscript: true)
            }
            fixtures = [unfinished]
        }
        var settings = AppSettings(storageDirectory: URL(fileURLWithPath: "/Users/example/Documents/Transcriber"))
        if CommandLine.arguments.contains("--cloud") {
            settings.transcriptionBackend = .deepgram; settings.summaryBackend = .openai; settings.summaryModel = ""
        }
        return TranscriberViewModel(capture: PreviewCapture(), processor: QueuePreviewProcessor(),
            settings: settings, settingsStore: .inMemory(), meetingStore: .inMemory(initial: fixtures), artifacts: NoArtifacts())
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = makeModel()
        self.model = model
        let settings = CommandLine.arguments.contains("--settings")
        let content: AnyView = settings ? AnyView(SettingsView(vm: model)) : AnyView(ContentView(vm: model))
        let root = VStack(spacing: 0) {
            HStack {
                Image(systemName: "eye")
                Text("UI preview · sample meetings").bold()
                Text("Nothing is saved. Recording, downloads, and account changes are disabled.")
            }
            .font(.caption).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.15))
            content
        }
        .environment(\.localModelDownloadsEnabled, false)
        .environment(\.externalActionsEnabled, false)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: settings ? 760 : 1000, height: settings ? 900 : 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Transcriber — UI Preview"
        window.contentView = NSHostingView(rootView: root)
        window.contentMinSize = NSSize(width: settings ? 520 : 800, height: 500)
        self.window = window
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            if CommandLine.arguments.contains("--queue") || CommandLine.arguments.contains("--waiting") {
                if CommandLine.arguments.contains("--waiting") {
                    await model.scheduling.updateConditions(BackgroundConditions(memory: .warning))
                }
                for meeting in model.meetings { Task { await model.retry(id: meeting.id) } }
            }
            if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.indices.contains(i + 1) {
                let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
                for _ in 0..<5 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if saveSnapshot(window: window, to: url) { break }
                }
                NSApp.terminate(nil)
            }
        }
    }

    private func saveSnapshot(window: NSWindow, to url: URL) -> Bool {
        guard let view = window.contentView else { return false }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { return false }
        do { try bytes.write(to: url, options: .atomic); return true } catch { return false }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private struct NoArtifacts: MeetingArtifactManaging {
    func sweep(liveIDs: Set<UUID>) -> [URL] { [] }
    func remove(_ urls: [URL]) throws {}
    func removeEmptyDirectory(for id: UUID) throws {}
    func discard(_ meeting: Meeting) throws {}
}

private struct PreviewCapture: AudioCapture {
    var status: [AudioSource: AudioCaptureError] { [:] }
    func level(_ source: AudioSource) -> Float { 0 }
    func start(sources: Set<AudioSource>, directory: URL) async throws -> AudioCaptureSession {
        throw LLMError("Recording is unavailable in this preview.")
    }
}

private struct QueuePreviewProcessor: MeetingProcessor {
    func process(meeting: Meeting, audio: CapturedAudio, report: @escaping @Sendable (ProcessingProgress) -> Void) async throws -> ProcessedResult {
        report(ProcessingProgress(stage: .summarizing))
        try await Task.sleep(nanoseconds: 600_000_000_000)
        return ProcessedResult(segments: [], summary: MeetingSummary(overall: "Meeting notes are ready."))
    }
}

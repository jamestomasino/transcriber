import SwiftUI
import AppKit

/// An isolated UI fixture; it never loads or saves the user's meetings.
@main
struct PreviewApp: App {
    @StateObject private var vm: TranscriberViewModel
    init() {
        let now = Date()
        let meeting = Meeting(title: "Release planning", status: .summarized,
            startedAt: now.addingTimeInterval(-1800), stoppedAt: now, duration: 1800,
            createdAt: now, lastActivityAt: now, speakerCount: 2,
            summary: MeetingSummary(overall: "The team agreed to launch on Friday after completing the release checklist.",
                keyPoints: ["The build is ready for final validation."], decisions: ["Launch on Friday."],
                actionItems: ["Alex: finish release notes by Thursday."], model: "Validation fixture"))
        _vm = StateObject(wrappedValue: TranscriberViewModel(capture: PreviewCapture(),
            settingsStore: .inMemory(), meetingStore: .inMemory(initial: CommandLine.arguments.contains("--empty") ? [] : [meeting]),
            artifacts: NoArtifacts()))
    }
    var body: some Scene {
        WindowGroup("Transcriber Validation") {
            ContentView(vm: vm).environment(\.localModelDownloadsEnabled, false).onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        Settings {
            Text("This is an isolated UI fixture. Use the normal Transcriber app to configure recording and provider keys.")
                .padding().frame(width: 400)
        }
    }
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
        throw LLMError("Recording is disabled in this isolated UI fixture. Use the normal Transcriber app.")
    }
}

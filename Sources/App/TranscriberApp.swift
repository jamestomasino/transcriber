import SwiftUI
import AppKit

#if canImport(TranscriberCore)
import TranscriberCore
#endif

@main
struct TranscriberApp: App {
    /// Single shared view model so the main window and menu-bar item agree. Wired to the real AVFoundation +
    /// Core Audio system capture and the real pipeline processor (chosen from
    /// the user's settings).
    @StateObject private var vm: TranscriberViewModel
    @Environment(\.openWindow) private var openWindow

    init() {
        let settingsStore = SettingsStore(url: Self.settingsURL)
        let settings = settingsStore.load()
        let storageError: String?
        do {
            try AppStorage.prepare(settings: settings)
            storageError = nil
        } catch {
            storageError = "Could not create the data folder at \(StorageDirectory.base(settings: settings).path). \(error.localizedDescription) Choose an accessible folder in Settings → Storage, then restart Transcriber."
        }
        // The data directory (meetings.json + recordings/) is resolved from
        // settings: Documents/Transcriber on first startup, a chosen folder,
        // or Application Support for saved settings with the legacy nil path.
        // settings.json itself always lives in Application Support so the app
        // can find it on launch regardless of the data location.
        let meetingStore = MeetingStore(url: StorageDirectory.meetingsURL(settings: settings))
        // Keep recordings and history on the same root for the whole session.
        // A location change in Settings takes effect on the next launch.
        RecordingsDirectory.baseDirectory = { StorageDirectory.recordingsURL(settings: settings) }
        let scheduling = BackgroundProcessingScheduler()
        BackgroundResourceMonitor.shared.start(scheduling: scheduling)
        let model = TranscriberViewModel(
            capture: AVAudioCapture(inputDeviceUID: { settingsStore.load().inputDeviceID }),
            processor: ProcessorFactory.make(settings: settings, scheduling: scheduling),
            settings: settings,
            settingsStore: settingsStore,
            meetingStore: meetingStore,
            startupError: storageError,
            // Rebuild the pipeline from the *current* settings at run time so
            // switching backend / model in Settings takes effect on the next
            // meeting without a relaunch. Keys are read lazily from the Keychain
            // inside the factory, so Core stays pure.
            processorFactory: { ProcessorFactory.make(settings: $0, scheduling: scheduling) },
            // A meeting started from the menu bar runs headless: post a banner
            // when it finishes (or fails) so the user knows the summary is
            // ready. The *decision* is pure Core; this poster owns the
            // platform call.
            notifier: { note in MeetingNotifications.post(note) },
            scheduling: scheduling
        )
        _vm = StateObject(wrappedValue: model)
        // Explicit recovery invocation; normal launches never retry automatically.
        let arguments = CommandLine.arguments
        if arguments.contains("--use-local-models") {
            model.updateSettings {
                $0.transcriptionBackend = .whisper; $0.whisperModel = WhisperCatalog.defaultID
                $0.summaryBackend = .localModel; $0.summaryModel = SummaryModelCatalog.defaultID
            }
        }
        if let index = arguments.firstIndex(where: { $0 == "--retry-meeting" || $0 == "--retranscribe-meeting" }),
           arguments.indices.contains(index + 1),
           let id = UUID(uuidString: arguments[index + 1]) {
            Task { @MainActor in _ = await model.retry(id: id, reuseTranscript: arguments[index] != "--retranscribe-meeting") }
        }
        if arguments.contains("--validate-local-speech") {
            Task { await Self.validateLocalSpeech() }
        }
        if let index = arguments.firstIndex(of: "--relabel-speakers"), arguments.indices.contains(index + 1),
           let id = UUID(uuidString: arguments[index + 1]) {
            Task { @MainActor in _ = await model.reprocessSpeakers(id: id) }
        }
        // Ask for the banner permission once, on launch, so the first finished
        // meeting can actually post. Idempotent — macOS won't re-prompt after
        // the user has decided.
        MeetingNotifications.requestAuthorization()
    }

    /// Run inside the app's existing Speech authorization, using only synthetic
    /// audio in an isolated temporary folder. Does not create or retry meetings.
    private static func validateLocalSpeech() async {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("transcriber-hosted-speech-check.json")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcriber-speech-check-\(UUID().uuidString)")
        var result: [String: Any] = [:]
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let audio = root.appendingPathComponent("fixture.aiff")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", audio.path,
                "First item. Alex will write release notes by Friday. [[slnc 3000]] Second item. Blair will review the budget by Tuesday. [[slnc 3000]] Third item. Casey will update the website by Thursday."]
            try say.run()
            say.waitUntilExit()
            guard say.terminationStatus == 0 else { throw SpeechError("Could not create Speech fixture") }
            let segments = try await LocalSpeechTranscriber().transcribe(audio: CapturedAudio(fileURLs: [.mic: audio]), language: "en-US")
            let text = segments.map(\.text).joined(separator: " ").lowercased()
            let checks = Dictionary(uniqueKeysWithValues: ["release", "budget", "website", "friday", "tuesday", "thursday"].map { ($0, text.contains($0)) })
            result = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "words": text.split(separator: " ").count]
        } catch { result = ["passed": false, "error": error.localizedDescription] }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) { try? data.write(to: output, options: .atomic) }
    }

    var body: some Scene {
        Window("Transcriber", id: "main") {
            ContentView(vm: vm)
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Transcriber") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }

        // The settings window (⌘, / Transcriber ▸ Settings): the only place a
        // user configures backends, models, retention, and API keys.
        Settings {
            SettingsView(vm: vm)
        }

        // A menu-bar item with a live Start/Stop so a meeting can be started or
        // stopped without the main window focused. macOS 13+, target is 14.
        MenuBarExtra {
            if vm.isRecording || vm.isStopping {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(vm.activeMeeting?.startedAt ?? context.date)))
                    Label(vm.isStopping ? "Finishing recording…" : String(format: "Recording %d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60), systemImage: "record.circle.fill")
                }
                    .foregroundStyle(.red)
                    .disabled(true)
                Divider()
                Button("Stop") { vm.stop() }
                    .disabled(vm.isStarting || vm.isStopping)
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button("Start meeting") { vm.start(title: nil) }
                    .disabled(vm.settings.requestedSources.isEmpty || vm.isStarting || vm.isStopping)
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
            Divider()
            SettingsLink { Text("Settings…") }
            Button("Open Transcriber") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: vm.isRecording ? "record.circle" : "waveform.circle")
        }
        .menuBarExtraStyle(.menu)
    }

    static var settingsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("Transcriber", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// Where meeting summaries (the only durable artifact) are persisted,
    /// alongside settings.json.
    static var meetingsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("Transcriber", isDirectory: true)
            .appendingPathComponent("meetings.json")
    }
}

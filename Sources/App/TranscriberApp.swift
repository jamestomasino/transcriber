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
        _vm = StateObject(wrappedValue: TranscriberViewModel(
            capture: AVAudioCapture(inputDeviceUID: { settingsStore.load().inputDeviceID }),
            processor: ProcessorFactory.make(settings: settings),
            settings: settings,
            settingsStore: settingsStore,
            meetingStore: meetingStore,
            startupError: storageError,
            // Rebuild the pipeline from the *current* settings at run time so
            // switching backend / model in Settings takes effect on the next
            // meeting without a relaunch. Keys are read lazily from the Keychain
            // inside the factory, so Core stays pure.
            processorFactory: { ProcessorFactory.make(settings: $0) },
            // A meeting started from the menu bar runs headless: post a banner
            // when it finishes (or fails) so the user knows the summary is
            // ready. The *decision* is pure Core; this poster owns the
            // platform call.
            notifier: { note in MeetingNotifications.post(note) }
        ))
        // Ask for the banner permission once, on launch, so the first finished
        // meeting can actually post. Idempotent — macOS won't re-prompt after
        // the user has decided.
        MeetingNotifications.requestAuthorization()
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

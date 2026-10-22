import SwiftUI
import AppKit

@main
struct TranscriberApp: App {
    /// Single shared view model so the main window and the (future) menu-bar
    /// item always agree on state. Wired to the real AVFoundation +
    /// ScreenCaptureKit capture and the real pipeline processor (chosen from
    /// the user's settings).
    @StateObject private var vm: TranscriberViewModel

    init() {
        let settingsStore = SettingsStore(url: Self.settingsURL)
        let settings = settingsStore.load()
        let meetingStore = MeetingStore(url: Self.meetingsURL)
        _vm = StateObject(wrappedValue: TranscriberViewModel(
            capture: AVAudioCapture(),
            processor: ProcessorFactory.make(settings: settings),
            settings: settings,
            settingsStore: settingsStore,
            meetingStore: meetingStore,
            // Rebuild the pipeline from the *current* settings at run time so
            // switching backend / model in Settings takes effect on the next
            // meeting without a relaunch. Keys are read lazily from the Keychain
            // inside the factory, so Core stays pure.
            processorFactory: { ProcessorFactory.make(settings: $0) }
        ))
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(vm: vm)
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .appInfo) {
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
            if vm.isRecording {
                Label("Recording…", systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
                    .disabled(true)
                Divider()
                Button("Stop") { vm.stop() }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button("Start meeting") { vm.start(title: nil) }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
            Divider()
            Button("Open Transcriber") {
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

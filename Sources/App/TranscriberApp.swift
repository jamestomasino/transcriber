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
            meetingStore: meetingStore
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

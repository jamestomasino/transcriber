import SwiftUI
import AppKit

@main
struct TranscriberApp: App {
    /// Single shared view model so the main window and the (future) menu-bar
    /// item always agree on state. Wired to the real AVFoundation +
    /// ScreenCaptureKit capture.
    @StateObject private var vm = TranscriberViewModel(capture: AVAudioCapture())

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
}

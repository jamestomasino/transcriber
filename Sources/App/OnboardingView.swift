import SwiftUI
import AppKit
import AVFoundation
import Speech
import CoreGraphics

#if canImport(TranscriberCore)
import TranscriberCore
#endif

/// Permission checks and Settings links belong to App; capture still requests
/// access on first use. Recheck when the user returns from System Settings.
struct OnboardingView: View {
    @ObservedObject var vm: TranscriberViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var micAllowed = false
    @State private var systemAllowed = false
    @State private var speechAllowed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Before your first meeting").font(.headline)
            Text("Choose your audio sources and backends in Settings. Access is requested when you first use a source; you can record with just one source enabled.")
                .foregroundStyle(.secondary)
            if vm.settings.captureMic {
                permission("Microphone", detail: "Records your voice.", allowed: micAllowed, pane: "Microphone")
            }
            if vm.settings.captureSystem {
                permission("Screen Recording", detail: "Captures other people’s voices from apps. No video is saved.", allowed: systemAllowed, pane: "ScreenCapture")
            }
            if vm.settings.transcriptionBackend == .local {
                permission("Speech Recognition", detail: "Turns audio into text on this Mac. Local speaker labels are approximate.", allowed: speechAllowed, pane: "SpeechRecognition")
                if !speechAllowed {
                    Button("Allow Speech Recognition") {
                        SFSpeechRecognizer.requestAuthorization { _ in Task { @MainActor in refresh() } }
                    }
                }
            } else {
                Text("Deepgram receives the recorded audio for transcription and speaker identification.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if vm.settings.summaryBackend == .local {
                Text("Local summaries require macOS 26 or later with Apple Intelligence enabled.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("The transcript is sent to \(vm.settings.summaryBackend == .openai ? "OpenAI" : "Anthropic") for summarization. Add its API key in Settings before recording.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text(vm.settings.keepAudioAfterSummary || vm.settings.keepTranscriptAfterSummary
                 ? "You have opted to retain audio or transcripts. Review retention in Settings → Storage."
                 : "After a successful summary, audio and transcript are deleted. Failed meetings keep audio so you can retry.")
                .font(.callout)
            SettingsLink { Label("Open Settings", systemImage: "gearshape") }
        }
        .padding(16)
        .frame(maxWidth: 540, alignment: .leading)
        .onAppear { refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
    }

    private func permission(_ name: String, detail: String, allowed: Bool, pane: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: allowed ? "checkmark.circle.fill" : "lock.circle")
                .foregroundStyle(allowed ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !allowed {
                Button("System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func refresh() {
        micAllowed = AVAudioApplication.shared.recordPermission == .granted
        systemAllowed = CGPreflightScreenCaptureAccess()
        speechAllowed = SFSpeechRecognizer.authorizationStatus() == .authorized
    }
}

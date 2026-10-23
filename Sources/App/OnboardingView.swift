import SwiftUI
import AppKit
import AVFoundation
import Speech
import CoreGraphics

#if canImport(TranscriberCore)
import TranscriberCore
#endif

/// Request access before recording, without starting capture or creating files.
/// Recheck when the user returns from System Settings.
struct OnboardingView: View {
    private enum PermissionStatus {
        case notRequested, denied, allowed
    }

    @ObservedObject var vm: TranscriberViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var micStatus = PermissionStatus.notRequested
    @State private var systemStatus = PermissionStatus.notRequested
    @State private var speechStatus = PermissionStatus.notRequested
    @State private var pendingPermission: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Before your first meeting").font(.headline)
            Text("Choose your audio sources and backends in Settings, then use the Allow buttons below to grant access before recording. You can record with just one source enabled.")
                .foregroundStyle(.secondary)
            if vm.settings.captureMic {
                permission("Microphone", detail: "Records your voice.", status: micStatus, pane: "Microphone", request: requestMicrophone)
            }
            if vm.settings.captureSystem {
                permission("Screen Recording", detail: "Captures other people’s voices from apps. No video is saved.", status: systemStatus, pane: "ScreenCapture") {
                    // Unlike mic and Speech, CoreGraphics exposes no separate
                    // not-determined status. Try the prompt once; if access is
                    // still unavailable, offer Settings (also handles an earlier denial).
                    systemStatus = CGRequestScreenCaptureAccess() ? .allowed : .denied
                    refresh()
                }
                if systemStatus == .denied {
                    Text("Enable Transcriber under Privacy & Security → Screen & System Audio Recording (Screen Recording on older macOS). If macOS asks, quit and reopen Transcriber to apply access.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if vm.settings.transcriptionBackend == .local {
                permission("Speech Recognition", detail: "Turns audio into text on this Mac. Local speaker labels are approximate.", status: speechStatus, pane: "SpeechRecognition", request: requestSpeech)
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func permission(_ name: String, detail: String, status: PermissionStatus, pane: String, request: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: status == .allowed ? "checkmark.circle.fill" : "lock.circle")
                .foregroundStyle(status == .allowed ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if status == .notRequested {
                Button(pendingPermission == name ? "Requesting…" : "Allow…", action: request)
                    .accessibilityLabel("Allow \(name)")
                    .disabled(pendingPermission != nil)
            } else if status == .denied {
                Button("System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func requestMicrophone() {
        pendingPermission = "Microphone"
        AVAudioApplication.requestRecordPermission { _ in
            Task { @MainActor in
                pendingPermission = nil
                refresh()
            }
        }
    }

    private func requestSpeech() {
        pendingPermission = "Speech Recognition"
        SFSpeechRecognizer.requestAuthorization { _ in
            Task { @MainActor in
                pendingPermission = nil
                refresh()
            }
        }
    }

    private func refresh() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: micStatus = .allowed
        case .undetermined: micStatus = .notRequested
        default: micStatus = .denied
        }
        if CGPreflightScreenCaptureAccess() {
            systemStatus = .allowed
        } else if systemStatus == .allowed {
            systemStatus = .denied
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speechStatus = .allowed
        case .notDetermined: speechStatus = .notRequested
        default: speechStatus = .denied
        }
    }
}

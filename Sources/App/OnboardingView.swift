import SwiftUI
import AppKit
import AVFoundation
import Speech
import CoreGraphics
import ScreenCaptureKit

#if canImport(TranscriberCore)
import TranscriberCore
#endif

/// Request access before recording, without starting capture or creating files.
/// Recheck when the user returns from System Settings.
struct OnboardingView: View {
    private enum PermissionStatus {
        case notRequested, denied, allowed, unverified
    }

    @ObservedObject var vm: TranscriberViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var micStatus = PermissionStatus.notRequested
    @State private var systemStatus = PermissionStatus.notRequested
    @State private var speechStatus = PermissionStatus.notRequested
    @State private var pendingPermission: String?
    @SwiftUI.AppStorage("systemAudioAccessRequested") private var hasRequestedAudioAccess = false
    @SwiftUI.AppStorage("screenAccessRequested") private var hasRequestedScreenAccess = false
    @State private var systemAccessDetail: String?
    @State private var checkingScreenAccess = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Before your first meeting").font(.headline)
            Text("Choose your audio sources and backends in Settings, then use the Allow buttons below to grant access before recording. You can record with just one source enabled.")
                .foregroundStyle(.secondary)
            if vm.settings.captureMic {
                permission("Microphone", detail: "Records your voice.", status: micStatus, pane: "Microphone", request: requestMicrophone)
            }
            if vm.settings.captureSystem {
                permission(systemPermissionName, detail: "Captures other people’s voices from apps. No video is captured or saved.", status: systemStatus, pane: "ScreenCapture", request: requestSystemAccess)
                if let systemAccessDetail {
                    Text(systemAccessDetail).font(.caption).foregroundStyle(.secondary)
                }
                if systemStatus != .notRequested {
                    Button(checkingScreenAccess ? "Checking audio…" : "Check audio again", action: requestSystemAccess)
                        .disabled(checkingScreenAccess || vm.isRecording || vm.isStarting)
                }
                if systemStatus == .denied {
                    Text("Enable Transcriber’s system audio access under Privacy & Security → Screen & System Audio Recording (Screen Recording on older macOS). If macOS asks, quit and reopen Transcriber to apply access.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if vm.settings.transcriptionBackend == .local {
                permission("Speech Recognition", detail: "Turns audio into text on this Mac. Local speaker labels are approximate.", status: speechStatus, pane: "SpeechRecognition", request: requestSpeech)
            } else if vm.settings.transcriptionBackend == .deepgram {
                Text("Deepgram receives the recorded audio for transcription and speaker identification.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Whisper transcribes on this Mac using downloaded weights. Local speaker labels are approximate.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if vm.settings.summaryBackend == .local {
                Text("Local summaries require macOS 26 or later with Apple Intelligence enabled.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if vm.settings.summaryBackend == .localModel {
                Text("Downloaded local summaries run on this Mac. Only public model downloads use the network; your transcript stays local.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("The transcript is sent to \(vm.settings.summaryBackend == .openai ? "OpenAI" : "Anthropic") for summarization. Add its API key in Settings before recording.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if vm.settings.transcriptionBackend == .whisper || vm.settings.summaryBackend == .localModel {
                LocalModelSetupView(vm: vm)
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
            } else if status == .denied || status == .unverified {
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

    private var systemPermissionName: String {
        if #available(macOS 14.2, *) { return "System Audio Recording" }
        return "Screen Recording"
    }

    private func requestSystemAccess() {
        if #available(macOS 14.2, *) {
            hasRequestedAudioAccess = true
            refreshSystemAccess()
        } else {
            hasRequestedScreenAccess = true
            systemStatus = CGRequestScreenCaptureAccess() ? .allowed : .denied
            refreshScreenAccess()
        }
    }

    private func refreshSystemAccess() {
        guard !vm.isRecording, !vm.isStarting else { return }
        if #available(macOS 14.2, *) {
            // Remember the request across the restart required by System Settings.
            // Never use screen preflight for the independent audio-only permission.
            guard hasRequestedAudioAccess, !checkingScreenAccess else { return }
            checkingScreenAccess = true
            pendingPermission = systemPermissionName
            systemAccessDetail = "Play sound in another app while access is checked. This check saves no audio."
            Task { @MainActor in
                defer { checkingScreenAccess = false; pendingPermission = nil }
                do {
                    if try await SystemAudioTap.checkAccess() {
                        systemStatus = .allowed
                        systemAccessDetail = "System audio received successfully."
                    } else {
                        systemStatus = .unverified
                        systemAccessDetail = "No sound detected. Play audio in another app and check again. If it stays silent, enable System Audio Recording in System Settings, then quit and reopen Transcriber if macOS asks."
                    }
                } catch {
                    systemStatus = .unverified
                    systemAccessDetail = error.localizedDescription
                }
            }
        } else {
            refreshScreenAccess()
        }
    }

    private func refreshScreenAccess() {
        let preflightAllowed = CGPreflightScreenCaptureAccess()
        // CoreGraphics can retain a stale denial after access changes in
        // System Settings. Once access has been requested, check the same
        // ScreenCaptureKit API used by recording, without starting a stream.
        // Do not run this on a fresh install: enumeration can prompt for access.
        guard hasRequestedScreenAccess else {
            if preflightAllowed { systemStatus = .allowed }
            else if systemStatus == .allowed { systemStatus = .denied }
            return
        }
        guard !checkingScreenAccess, pendingPermission != systemPermissionName else { return }
        checkingScreenAccess = true
        Task { @MainActor in
            defer { checkingScreenAccess = false }
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                systemStatus = .allowed
            } catch {
                let error = error as NSError
                if error.domain == SCStreamErrorDomain,
                   error.code == SCStreamError.Code.userDeclined.rawValue {
                    systemStatus = .denied
                } else if preflightAllowed {
                    systemStatus = .allowed
                }
            }
        }
    }

    private func refresh() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: micStatus = .allowed
        case .undetermined: micStatus = .notRequested
        default: micStatus = .denied
        }
        refreshSystemAccess()
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speechStatus = .allowed
        case .notDetermined: speechStatus = .notRequested
        default: speechStatus = .denied
        }
    }
}

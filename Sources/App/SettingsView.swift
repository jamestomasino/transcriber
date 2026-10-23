import SwiftUI
import AppKit

#if canImport(TranscriberCore)
import TranscriberCore
#endif

// MARK: - Settings (App)
//
// The settings window: the last mile that makes the app usable with a real
// backend. Bound to the view model's `settings` through `updateSettings`, so
// every change is persisted to settings.json (and reflected live, since
// `settings` is `@Published`). API keys are the one thing that must NOT go
// into settings.json — they are routed through the Keychain (`Keychain.set`),
// matching how `ProcessorFactory` reads them at run time.
//
// This lives in the App layer (not Core) because it touches the Keychain and
// SwiftUI; the underlying `AppSettings` + persistence stay pure in Core.
struct SettingsView: View {
    @ObservedObject var vm: TranscriberViewModel
    @State private var inputDevices: [AudioInputDevice] = []

    /// A `Binding` that reads from `vm.settings` and writes through
    /// `updateSettings` (which persists). Using `updateSettings` for every
    /// write means a change is saved immediately and the `@Published` settings
    /// re-render the whole window.
    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { vm.settings[keyPath: keyPath] },
            set: { newValue in vm.updateSettings { $0[keyPath: keyPath] = newValue } }
        )
    }

    var body: some View {
        Form {
            Section("Audio") {
                Toggle("Capture microphone", isOn: binding(\.captureMic))
                Toggle("Capture system audio", isOn: binding(\.captureSystem))
                Picker("Microphone", selection: Binding(
                    get: { vm.settings.inputDeviceID ?? "" },
                    set: { uid in vm.updateSettings {
                        $0.inputDeviceID = uid.isEmpty ? nil : uid
                        $0.inputDeviceName = inputDevices.first(where: { $0.id == uid })?.name
                    } }
                )) {
                    Text("System default").tag("")
                    ForEach(inputDevices) { device in Text(device.name).tag(device.id) }
                    if let uid = vm.settings.inputDeviceID, !inputDevices.contains(where: { $0.id == uid }) {
                        Text("\(vm.settings.inputDeviceName ?? "Selected microphone") (disconnected)").tag(uid)
                    }
                }
                .disabled(!vm.settings.captureMic || vm.isRecording)
                Button("Refresh microphones") { inputDevices = AudioDevices.inputs() }
                if vm.settings.requestedSources.isEmpty {
                    Text("Enable at least one audio source to start a meeting.").foregroundStyle(.orange)
                }
            }

            Section {
                Toggle("Keep transcript after summary", isOn: binding(\.keepTranscriptAfterSummary))
                Toggle("Keep audio after summary", isOn: binding(\.keepAudioAfterSummary))
                Text("By default the app deletes the audio and transcript right after the summary is written, keeping only the summary. Flip these to retain them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StorageDirectoryRow(vm: vm)
            } header: {
                Text("Storage")
            }

            Section("Transcription") {
                Picker("Backend", selection: binding(\.transcriptionBackend)) {
                    Text("Local — Apple Speech (private, no key)").tag(TranscriptionBackend.local)
                    Text("Deepgram — accurate speaker ID").tag(TranscriptionBackend.deepgram)
                }
                TextField("Language code (e.g. en)", text: binding(\.language))
                if vm.settings.transcriptionBackend == .local {
                    Text("Runs on this Mac with Apple Speech — private, offline, no model to download.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if vm.settings.transcriptionBackend == .deepgram {
                    APIKeyRow(title: "Deepgram API key", keyID: "deepgram_api_key")
                }
            }

            Section("Summary") {
                Picker("Backend", selection: binding(\.summaryBackend)) {
                    Text("Local — on-device Apple Intelligence (offline, no key)").tag(SummaryBackend.local)
                    Text("OpenAI").tag(SummaryBackend.openai)
                    Text("Anthropic").tag(SummaryBackend.anthropic)
                }
                if vm.settings.summaryBackend == .local {
                    Text("Runs on this Mac with Apple Intelligence — no account, no key, no network. Requires macOS 26+ with Apple Intelligence enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Model identifier", text: binding(\.summaryModel))
                }
                if vm.settings.summaryBackend == .openai {
                    APIKeyRow(title: "OpenAI API key", keyID: "openai_api_key")
                }
                if vm.settings.summaryBackend == .anthropic {
                    APIKeyRow(title: "Anthropic API key", keyID: "anthropic_api_key")
                }
            }

            Section("General") {
                Toggle("Show toasts", isOn: binding(\.showToasts))
                Toggle("Notify when a summary is ready", isOn: binding(\.notifyOnSummary))
            }
        }
        .onAppear { inputDevices = AudioDevices.inputs() }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 520)
    }
}

// MARK: - Storage directory row
//
// Lets the user pick a custom directory for Transcriber data (meetings.json
// + recordings/). New installations default to Documents/Transcriber. Uses NSOpenPanel
// (AppKit) for the directory chooser — the only place in the app that needs
// AppKit for a file dialog.
private struct StorageDirectoryRow: View {
    @ObservedObject var vm: TranscriberViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
        HStack {
            Text("Data location")
                .font(.subheadline)
            Spacer()
            Text(displayPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Choose…") { chooseDirectory() }
            if vm.settings.storageDirectory != StorageDirectory.defaultDirectory {
                Button("Reset", role: .destructive) {
                    vm.updateSettings { $0.storageDirectory = StorageDirectory.defaultDirectory }
                }
            }
        }
        Text("Location changes take effect after restarting Transcriber. Existing meetings stay in their original folder.")
            .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(vm.isRecording)
    }

    private var displayPath: String {
        StorageDirectory.base(settings: vm.settings).path
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where Transcriber stores its data (meetings + recordings)."
        panel.directoryURL = StorageDirectory.base(settings: vm.settings)
        if panel.runModal() == .OK, let url = panel.url {
            vm.updateSettings { $0.storageDirectory = url }
        }
    }
}

// MARK: - API key row
//
// A SecureField + Save/Clear that routes through the Keychain. The key is
// never written to settings.json and never echoed back into the field (so the
// UI shows a "stored" indicator instead of the secret).
private struct APIKeyRow: View {
    let title: String
    let keyID: String

    @State private var value: String = ""
    @State private var hasStored: Bool = false
    @State private var justSaved: Bool = false
    @State private var failed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                if hasStored {
                    Label("stored", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            HStack {
                SecureField(hasStored ? "Enter new \(title)" : "Enter \(title)", text: $value)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { save() }
                    .disabled(value.isEmpty)
                if hasStored {
                    Button("Clear", role: .destructive) { clear() }
                }
            }
            if justSaved {
                Text("Saved to the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if failed {
                Text("Couldn't update the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { hasStored = (Keychain.get(keyID)?.isEmpty == false) }
    }

    private func save() {
        guard !value.isEmpty else { return }
        do {
            try Keychain.set(value, for: keyID)
            hasStored = true
            value = ""
            justSaved = true
            failed = false
        } catch {
            failed = true
            justSaved = false
        }
    }

    private func clear() {
        do {
            try Keychain.delete(keyID)
            hasStored = false
            value = ""
            justSaved = false
            failed = false
        } catch { failed = true }
    }
}

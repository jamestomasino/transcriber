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
// Validation previews can exercise the views without reading credentials or
// changing operating-system permissions. Normal app interactions stay enabled.
private struct ExternalActionsEnabledKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var externalActionsEnabled: Bool {
        get { self[ExternalActionsEnabledKey.self] }
        set { self[ExternalActionsEnabledKey.self] = newValue }
    }
}

struct SettingsView: View {
    @Environment(\.externalActionsEnabled) private var externalActionsEnabled
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
                Toggle("Record microphone", isOn: binding(\.captureMic))
                Toggle("Record audio from other apps", isOn: binding(\.captureSystem))
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
                    .disabled(!externalActionsEnabled)
                if vm.settings.requestedSources.isEmpty {
                    Text("Enable at least one audio source to start a meeting.").foregroundStyle(.orange)
                }
            }

            .disabled(vm.isRecording || vm.isStarting || vm.isStopping)

            Section {
                Toggle("Keep transcripts", isOn: binding(\.keepTranscriptAfterSummary))
                Toggle("Keep recordings", isOn: binding(\.keepAudioAfterSummary))
                Text("Summaries are always saved. Recordings and transcripts are deleted after a successful summary unless you choose to keep them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if vm.meetings.contains(where: { $0.processingRequest != nil }) {
                    Text("Meetings already waiting or being prepared keep their earlier choices. Cancel their current attempt and try again to apply changes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                StorageDirectoryRow(vm: vm)
            } header: {
                Text("Storage")
            }

            Section("Transcription") {
                Picker("Transcribe with", selection: binding(\.transcriptionBackend)) {
                    Text("Whisper · on this Mac").tag(TranscriptionBackend.whisper)
                    Text("Apple Speech · on this Mac").tag(TranscriptionBackend.local)
                    Text("Deepgram · cloud").tag(TranscriptionBackend.deepgram)
                }
                Picker("Language", selection: binding(\.language)) {
                    ForEach(["en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh", "ar", "hi"], id: \.self) { code in
                        Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                    }
                    if !["en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh", "ar", "hi"].contains(vm.settings.language) {
                        Text(Locale.current.localizedString(forIdentifier: vm.settings.language) ?? vm.settings.language).tag(vm.settings.language)
                    }
                }
                DisclosureGroup("Other languages") {
                    TextField("Language code", text: binding(\.language))
                    Text("For another language or region, enter its language code, such as en-US.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if vm.settings.transcriptionBackend == .whisper {
                    Picker("Whisper model", selection: binding(\.whisperModel)) {
                        ForEach(WhisperCatalog.selectable, id: \.id) { Text($0.displayName).tag($0.id) }
                    }
                    Text("Large v3 prioritizes detail; Turbo finishes faster. Speaker labels are estimates.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if vm.settings.transcriptionBackend == .local {
                    Text("Uses Apple Speech on this Mac. Language support depends on the speech models installed in macOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if vm.settings.transcriptionBackend == .deepgram {
                    Text("Audio is sent to Deepgram to create the transcript and speaker labels.")
                        .font(.caption).foregroundStyle(.secondary)
                    APIKeyRow(title: "Deepgram API key", keyID: "deepgram_api_key")
                }
            }

            Section("Local vocabulary") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Names, organizations, products, projects and acronyms")
                    ZStack(alignment: .topLeading) {
                        if vm.settings.transcriptionVocabulary.isEmpty {
                            Text("Acme\nProject Atlas\nNorthstar")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5).padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: binding(\.transcriptionVocabulary))
                            .scrollContentBackground(.hidden)
                            .frame(height: 110)
                            .accessibilityLabel("Local vocabulary words")
                    }
                    .background(.background)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                    Text("Add names and terms you use often, one per line. Your changes are saved automatically and help Whisper recognize their spelling.")
                        .font(.caption).foregroundStyle(.secondary)
                    let vocabulary = TranscriptionVocabulary(vm.settings.transcriptionVocabulary)
                    Text("\(vocabulary.terms.count) saved · \(vocabulary.includedTerms.count) used for transcription")
                        .font(.caption).foregroundStyle(.secondary)
                    if vocabulary.omittedCount > 0 {
                        Text("\(vocabulary.omittedCount) terms do not fit. Put the most important names first or shorten the list.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if vm.settings.transcriptionBackend != .whisper {
                        Text("These terms are used with Whisper. They stay saved when you choose another transcription service.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Applies to new transcripts. To use updated spellings for an earlier meeting, choose Transcribe again when its recording is saved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Summary") {
                Picker("Summarize with", selection: binding(\.summaryBackend)) {
                    Text("Downloaded model · on this Mac").tag(SummaryBackend.localModel)
                    Text("Apple Intelligence · on this Mac").tag(SummaryBackend.local)
                    Text("OpenAI · cloud").tag(SummaryBackend.openai)
                    Text("Anthropic · cloud").tag(SummaryBackend.anthropic)
                }
                if vm.settings.summaryBackend == .local {
                    Text("Uses Apple Intelligence on this Mac. Requires macOS 26 or later with Apple Intelligence enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if vm.settings.summaryBackend == .localModel {
                    SummaryModelSelectionView(vm: vm)
                    Text("Requires at least 8 GB of memory. Allow extra time for longer meetings and when other apps are busy.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Transcripts are sent to \(vm.settings.summaryBackend == .openai ? "OpenAI" : "Anthropic") to create summaries.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Model name", text: binding(\.summaryModel))
                }
                if vm.settings.summaryBackend == .openai {
                    APIKeyRow(title: "OpenAI API key", keyID: "openai_api_key")
                }
                if vm.settings.summaryBackend == .anthropic {
                    APIKeyRow(title: "Anthropic API key", keyID: "anthropic_api_key")
                }
            }

            if vm.settings.transcriptionBackend != .deepgram || vm.settings.summaryBackend == .localModel {
                Section("On-device downloads") { LocalModelSetupView(vm: vm) }
            }

            Section("General") {
                Toggle("Show brief status messages", isOn: binding(\.showToasts))
                Toggle("Notify when a summary is ready", isOn: binding(\.notifyOnSummary))
            }
        }
        .onAppear { if externalActionsEnabled { inputDevices = AudioDevices.inputs() } }
        .onChange(of: vm.settings.notifyOnSummary) { _, enabled in
            if enabled && externalActionsEnabled { MeetingNotifications.requestAuthorization() }
        }
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
    @Environment(\.externalActionsEnabled) private var externalActionsEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
        HStack {
            Text("Meeting folder")
                .font(.subheadline)
            Spacer()
            Text(displayPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Choose…") { chooseDirectory() }
            if vm.settings.storageDirectory != StorageDirectory.defaultDirectory {
                Button("Use default folder") {
                    vm.updateSettings { $0.storageDirectory = StorageDirectory.defaultDirectory }
                }
            }
        }
        Text("After restarting, Transcriber opens the selected folder. Existing meetings are not moved.")
            .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!externalActionsEnabled || vm.isRecording || vm.isStarting || vm.isStopping)
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
        panel.message = "Choose a folder for your summaries, recordings, and transcripts."
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
    @Environment(\.externalActionsEnabled) private var enabled
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
                    Label("Saved", systemImage: "checkmark.circle.fill")
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
                    Button("Remove key", role: .destructive) { clear() }
                }
            }
            if justSaved {
                Text("Saved securely in Keychain.")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if failed {
                Text("Couldn't update the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .disabled(!enabled)
        .onAppear { if enabled { hasStored = (Keychain.get(keyID)?.isEmpty == false) } }
    }

    private func save() {
        guard enabled, !value.isEmpty else { return }
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
        guard enabled else { return }
        do {
            try Keychain.delete(keyID)
            hasStored = false
            value = ""
            justSaved = false
            failed = false
        } catch { failed = true }
    }
}

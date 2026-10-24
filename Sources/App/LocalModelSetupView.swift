import SwiftUI
#if canImport(TranscriberCore)
import TranscriberCore
#endif

private struct LocalModelDownloadsEnabledKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var localModelDownloadsEnabled: Bool {
        get { self[LocalModelDownloadsEnabledKey.self] }
        set { self[LocalModelDownloadsEnabledKey.self] = newValue }
    }
}

private func displayModelText(_ value: String) -> String {
    value.replacingOccurrences(of: "Q4_K_M", with: "4-bit").replacingOccurrences(of: "-GGUF", with: "")
        .replacingOccurrences(of: "Whisper runtime", with: "transcription tools")
        .replacingOccurrences(of: "Summary runtime", with: "summary tools")
        .replacingOccurrences(of: "Speaker analysis runtime", with: "speaker identification tools")
        .replacingOccurrences(of: "Speaker segmentation", with: "speaker identification model")
        .replacingOccurrences(of: "Speaker voice embeddings", with: "voice matching model")
}

struct LocalModelDownloadBanner: View {
    @ObservedObject private var status = LocalModelStatus.shared
    var body: some View {
        if let activity = status.activity {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayModelText(activity)).font(.callout)
                ProgressView(value: status.fraction)
                Text("These downloads do not include your recordings or transcripts.").font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
    }
}

struct LocalModelSetupView: View {
    @ObservedObject var vm: TranscriberViewModel
    @ObservedObject private var status = LocalModelStatus.shared
    @Environment(\.localModelDownloadsEnabled) private var enabled
    @State private var downloading = false
    @State private var message: String?
    @State private var task: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(vm.settings.transcriptionBackend == .local && vm.settings.summaryBackend != .localModel
                 ? "Download speaker identification tools once to label voices on this Mac."
                 : "Download the models needed for your on-device options. Once downloaded, they work offline.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(downloading ? "Downloading…" : "Download selected models") {
                    let requested = vm.settings
                    downloading = true; message = nil
                    task = Task {
                        do {
                            if requested.transcriptionBackend == .whisper {
                                guard let spec = WhisperCatalog.spec(id: requested.whisperModel), spec.sha256 != nil else { throw LocalInferenceError("Select a supported Whisper model.") }
                                _ = try await LocalModelAssets.shared.ensure(spec)
                                _ = try await LocalModelAssets.shared.runtime(whisper: true)
                            }
                            if requested.transcriptionBackend != .deepgram { _ = try await SpeakerAssets.prepare() }
                            if requested.summaryBackend == .localModel {
                                let option = try await SummaryModelRegistry.shared.option(id: requested.summaryModel)
                                guard SummaryModelFit.fits(option, memoryBytes: ProcessInfo.processInfo.physicalMemory) else { throw LocalInferenceError("Choose a smaller summary model for this Mac.") }
                                _ = try await LocalModelAssets.shared.ensure(option.asset)
                                _ = try await LocalModelAssets.shared.runtime(whisper: false)
                            }
                            message = "Your selected models are ready to use offline."
                        } catch { message = error is CancellationError ? "Download cancelled. You can retry it later." : error.localizedDescription }
                        downloading = false; task = nil
                    }
                }.disabled(downloading || !enabled)
                if downloading { Button("Cancel") { task?.cancel() } }
            }
            if let activity = status.activity { Text(displayModelText(activity)).font(.caption); ProgressView(value: status.fraction) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("Download details") {
            HStack {
                Link("Whisper model source", destination: URL(string: "https://huggingface.co/ggerganov/whisper.cpp")!)
                Link("Qwen model and license", destination: URL(string: "https://huggingface.co/Qwen/Qwen3.5-4B")!)
            }.font(.caption)
            Text(vm.settings.transcriptionBackend == .local && vm.settings.summaryBackend != .localModel
                 ? "Speaker identification needs about 65 MB. It also downloads automatically the first time you process a meeting."
                 : "The standard Whisper and Qwen models together need about 4.2 GB, plus supporting files. Other choices may need more space. Missing downloads also start when you first process a meeting with these options.")
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct SummaryModelSelectionView: View {
    @ObservedObject var vm: TranscriberViewModel
    @StateObject private var manager = SummaryModelManager()
    @Environment(\.localModelDownloadsEnabled) private var enabled
    @State private var choice = ""
    private var choiceID: String { choice.isEmpty ? vm.settings.summaryModel : choice }
    private var selected: SummaryModelOption? { manager.models.first { $0.id == choiceID } }
    private func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
    private var memoryDescription: String { ByteCountFormatter.string(fromByteCount: Int64(manager.memoryBytes), countStyle: .memory) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected: \(displayModelText(manager.models.first { $0.id == vm.settings.summaryModel }?.asset.displayName ?? "Selected local model"))")
                .font(.callout)
            Picker("Available summary models", selection: Binding(get: { choiceID }, set: { choice = $0 })) {
                ForEach(manager.models) { model in
                    Text(displayModelText(model.asset.displayName) + (model.id == manager.recommendedID ? " · Suggested for this Mac" : "")).tag(model.id)
                }
                if !manager.models.contains(where: { $0.id == vm.settings.summaryModel }) {
                    Text("Selected model · check available models for details").tag(vm.settings.summaryModel)
                }
            }.disabled(manager.busy)
            if let option = selected {
                Text("\(size(option.asset.sizeBytes)) download · \(option.license)")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Model details and source", destination: option.sourceURL).font(.caption)
                if !SummaryModelFit.fits(option, memoryBytes: manager.memoryBytes) {
                    Text("This model needs more memory. Choose a smaller model for this Mac.").font(.caption).foregroundStyle(.secondary)
                }
                if !SummaryModelFit.knownArchitectures.contains(option.architecture) {
                    Text("This model may require a newer version of Transcriber. Compatibility is checked before switching.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if manager.checked.contains(option.id) { Text("Previously checked for compatibility on this Mac.").font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Button("Check available models") { manager.scan() }.disabled(manager.busy || !enabled)
                Button("Download and use") { if let selected { manager.install(selected, vm: vm) } }
                    .disabled(!enabled || manager.busy || !vm.canReplaceLocalModel || choiceID == vm.settings.summaryModel || selected.map { !SummaryModelFit.fits($0, memoryBytes: manager.memoryBytes) } != false)
                if manager.busy { Button("Cancel") { manager.cancel() } }
            }
            Text("Suggestions are based on this Mac’s \(memoryDescription) of memory. Your current model stays available until its replacement is ready. Allow space for both downloads while switching.")
                .font(.caption).foregroundStyle(.secondary)
            if !vm.canReplaceLocalModel { Text("Finish or cancel pending meetings before changing the downloaded summary model.").font(.caption).foregroundStyle(.secondary) }
            if let phase = manager.phase { ProgressView(); Text(displayModelText(phase)).font(.caption) }
            if let message = manager.message { Text(displayModelText(message)).font(.caption).foregroundStyle(.secondary) }
        }
        .task { if enabled { await manager.load(selectedID: vm.settings.summaryModel) } }
    }
}

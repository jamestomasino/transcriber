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

struct LocalModelDownloadBanner: View {
    @ObservedObject private var status = LocalModelStatus.shared
    var body: some View {
        if let activity = status.activity {
            VStack(alignment: .leading, spacing: 4) {
                Text(activity).font(.callout)
                ProgressView(value: status.fraction)
                Text("Model downloads contain no meeting data. Processing stays on this Mac.").font(.caption).foregroundStyle(.secondary)
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
            Text("Download once, then use offline. Local models run one at a time. Check available summary models in Settings for choices suited to this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(downloading ? "Downloading…" : "Download selected local models") {
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
                            message = "Requested models are ready for offline use."
                        } catch { message = error is CancellationError ? "Download cancelled. You can retry it later." : error.localizedDescription }
                        downloading = false; task = nil
                    }
                }.disabled(downloading || !enabled)
                if downloading { Button("Cancel") { task?.cancel() } }
            }
            if let activity = status.activity { Text(activity).font(.caption); ProgressView(value: status.fraction) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if !enabled { Text("Model downloads are disabled in this isolated preview.").font(.caption) }
            HStack {
                Link("Whisper model source", destination: URL(string: "https://huggingface.co/ggerganov/whisper.cpp")!)
                Link("Qwen model and license", destination: URL(string: "https://huggingface.co/Qwen/Qwen3.5-4B")!)
            }.font(.caption)
            Text("Missing models also download on first use. Leave space for about 4.2 GB with Large v3 and the 4B summarizer, plus runtime files. Local speaker matching adds about 65 MB of downloads.")
                .font(.caption).foregroundStyle(.secondary)
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
            Text("Current: \(manager.models.first { $0.id == vm.settings.summaryModel }?.asset.displayName ?? "Selected local model")")
                .font(.callout)
            Picker("Available summary models", selection: Binding(get: { choiceID }, set: { choice = $0 })) {
                ForEach(manager.models) { model in
                    Text(model.asset.displayName + (model.id == manager.recommendedID ? " · Recommended fit" : "")).tag(model.id)
                }
                if !manager.models.contains(where: { $0.id == vm.settings.summaryModel }) {
                    Text("Selected model — check catalog to restore details").tag(vm.settings.summaryModel)
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
                    Text("This newer model may need an updated runtime. It must pass a local check before replacing the current model.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if manager.checked.contains(option.id) { Text("Previously passed the local check on this Mac.").font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Button("Check available models") { manager.scan() }.disabled(manager.busy || !enabled)
                Button("Download & switch") { if let selected { manager.install(selected, vm: vm) } }
                    .disabled(!enabled || manager.busy || !vm.canReplaceLocalModel || choiceID == vm.settings.summaryModel || selected.map { !SummaryModelFit.fits($0, memoryBytes: manager.memoryBytes) } != false)
                if manager.busy { Button("Cancel") { manager.cancel() } }
            }
            Text("Fit estimates use this Mac's \(memoryDescription) of shared memory. A local notes check runs before switching. The previous weights are deleted only after the new model and selection are safely saved. Leave room for both during the download.")
                .font(.caption).foregroundStyle(.secondary)
            if !vm.canReplaceLocalModel { Text("Finish recording or processing before switching models.").font(.caption).foregroundStyle(.secondary) }
            if let phase = manager.phase { ProgressView(); Text(phase).font(.caption) }
            if let message = manager.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .task { if enabled { await manager.load(selectedID: vm.settings.summaryModel) } }
    }
}

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
            Text("Download once, then use offline. Whisper and the summary model run one at a time. The 4B summary model targets Macs with 8 GB or more; larger models are not selected automatically.")
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
                            if requested.summaryBackend == .localModel {
                                guard let spec = SummaryModelCatalog.spec(id: requested.summaryModel) else { throw LocalInferenceError("Select a supported summary model.") }
                                _ = try await LocalModelAssets.shared.ensure(spec)
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
            Text("Missing models also download on first use. Leave space for about 4.2 GB with Large v3 and the 4B summarizer, plus runtime files.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

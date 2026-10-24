import Foundation
import Combine
#if canImport(TranscriberCore)
import TranscriberCore
#endif

/// Catalog metadata is public. This file never contains meeting content or keys.
actor SummaryModelRegistry {
    static let shared = SummaryModelRegistry(root: ModelsDirectory.base())
    let root: URL
    struct Check: Codable, Sendable { let runtime: String; let sha256: String; let date: Date }
    private struct Snapshot: Codable { var models: [SummaryModelOption]; var checks: [String: Check] }
    init(root: URL) { self.root = root }
    private func snapshot() -> Snapshot {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("summary-catalog.json")),
              let saved = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return Snapshot(models: [.current], checks: [:])
        }
        return Snapshot(models: saved.models.filter(\.isTrusted), checks: saved.checks)
    }
    func models() -> [SummaryModelOption] {
        var models = snapshot().models.filter { $0.id != SummaryModelCatalog.defaultID }
        models.insert(.current, at: 0)
        return models
    }
    func option(id: String) throws -> SummaryModelOption {
        guard let option = models().first(where: { $0.id == id }), option.isTrusted else {
            throw LocalInferenceError("The selected model's catalog entry is unavailable. Check available models in Settings to restore it.")
        }
        return option
    }
    func merge(_ options: [SummaryModelOption]) throws {
        var saved = snapshot()
        var map = Dictionary(saved.models.filter(\.isTrusted).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for option in options where option.isTrusted { map[option.id] = option }
        map[SummaryModelCatalog.defaultID] = .current
        saved.models = map.values.sorted { $0.id < $1.id }
        try write(saved)
    }
    func recordCheck(_ option: SummaryModelOption) throws {
        var saved = snapshot()
        guard option.isTrusted, saved.models.contains(where: { $0.id == option.id }) else {
            throw LocalInferenceError("The model catalog entry could not be verified.")
        }
        saved.checks[option.id] = Check(runtime: LocalModelAssets.llamaRuntime.id, sha256: option.asset.sha256!, date: Date())
        try write(saved)
    }
    func checkedIDs() -> Set<String> {
        let saved = snapshot()
        return Set(saved.models.filter { model in
            saved.checks[model.id]?.runtime == LocalModelAssets.llamaRuntime.id && saved.checks[model.id]?.sha256 == model.asset.sha256
        }.map(\.id))
    }
    private func write(_ saved: Snapshot) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: root.appendingPathComponent("summary-catalog.json"), options: .atomic)
    }
}

struct SummaryModelScanner: Sendable {
    let http: any HTTPClient
    init(http: any HTTPClient = URLSessionHTTPClient(requestTimeout: 30)) { self.http = http }
    private func fetch(_ url: URL) async throws -> Data {
        let response = try await http.send(HTTPRequest(url: url, method: "GET", headers: ["Accept": "application/json"]))
        guard response.statusCode == 200, response.body.count <= 4 * 1_024 * 1_024 else {
            throw LocalInferenceError("The model catalog could not be read. Your current model is unchanged.")
        }
        return response.body
    }
    func scan(memoryBytes: UInt64) async throws -> [SummaryModelOption] {
        var repositories: [String] = []
        // Direct Qwen releases and direct Qwen conversions only; unrelated
        // fine-tunes, code/reasoning-only models and arbitrary publishers are omitted.
        for (author, search) in [("Qwen", "Qwen"), ("bartowski", "Qwen_Qwen"), ("bartowski", "Qwen")] {
            var url = URLComponents(string: "https://huggingface.co/api/models")!
            url.queryItems = [URLQueryItem(name: "author", value: author), URLQueryItem(name: "search", value: search),
                URLQueryItem(name: "filter", value: "gguf"), URLQueryItem(name: "sort", value: "lastModified"),
                URLQueryItem(name: "direction", value: "-1"), URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "full", value: "true")]
            repositories += try SummaryModelDiscovery.repositories(await fetch(url.url!), author: author, memoryBytes: memoryBytes)
        }
        var seen: Set<String> = [], found: [SummaryModelOption] = [.current]
        var payloads: Set<String> = [SummaryModelOption.current.id]
        for repository in repositories where seen.insert(repository).inserted {
            try Task.checkCancellation()
            // Each detail response supplies the immutable commit, exact LFS
            // length and SHA256. Split GGUFs/projectors are not selectable.
            let url = URL(string: "https://huggingface.co/api/models/\(repository)?blobs=true")!
            let data = try await fetch(url)
            if let option = try SummaryModelDiscovery.option(data), SummaryModelFit.fits(option, memoryBytes: memoryBytes), payloads.insert(option.id).inserted {
                found.append(option)
            }
            if seen.count >= 36 { break }
        }
        return SummaryModelFit.ranked(SummaryModelDiscovery.uniqueModels(found), memoryBytes: memoryBytes)
    }
}

/// Called only while holding the shared inference queue. The test uses synthetic
/// public text, never a real transcript, and leaves the current model untouched.
enum SummaryModelProbe {
    static func check(option: SummaryModelOption, model: URL, runtime: URL) async throws {
        try await LocalSummaryServer.withServer(executable: runtime, model: model) { server in
            try await server.waitUntilReady()
            let summary = try await LocalJSONSummarizer(model: option.id, http: UnixModelHTTPClient(socket: server.socketURL), maximumOutputTokens: 512)
                .summarize(segments: [TranscriptSegment(speaker: "Alex", text: "Alex will send the release checklist by Friday. The team agreed to launch on Monday after testing.")], title: "Local model check")
            let actions = summary.actionItems.joined(separator: " ").lowercased()
            guard !summary.overall.isEmpty, actions.contains("alex"), actions.contains("friday") else {
                throw LocalInferenceError("This model did not pass the local meeting-notes check. Your current model was kept.")
            }
        }
    }
}

@MainActor
final class SummaryModelManager: ObservableObject {
    @Published private(set) var models: [SummaryModelOption] = [.current]
    @Published private(set) var checked: Set<String> = []
    @Published private(set) var busy = false
    @Published private(set) var phase: String?
    @Published private(set) var message: String?
    let memoryBytes = ProcessInfo.processInfo.physicalMemory
    private let registry: SummaryModelRegistry
    private let assets: LocalModelAssets
    private var job: Task<Void, Never>?
    private var activeModelID = SummaryModelCatalog.defaultID
    init(registry: SummaryModelRegistry = .shared, assets: LocalModelAssets = .shared) {
        self.registry = registry; self.assets = assets
    }
    var recommendedID: String? {
        SummaryModelFit.ranked(models.filter { SummaryModelFit.fits($0, memoryBytes: memoryBytes) && SummaryModelFit.knownArchitectures.contains($0.architecture) }, memoryBytes: memoryBytes).first?.id
    }
    func load(selectedID: String? = nil) async {
        if let selectedID { activeModelID = selectedID }
        models = SummaryModelFit.ranked(SummaryModelDiscovery.uniqueModels(await registry.models(), selectedID: activeModelID), memoryBytes: memoryBytes)
        checked = await registry.checkedIDs()
    }
    func scan() {
        guard !busy else { return }
        busy = true; phase = "Checking available summary models…"; message = nil
        job = Task {
            defer { busy = false; phase = nil; job = nil }
            do {
                let found = try await SummaryModelScanner().scan(memoryBytes: memoryBytes)
                try Task.checkCancellation()
                try await registry.merge(found)
                await load()
                message = "Found \(found.count) models suited to this Mac. Compatibility is checked before switching."
            } catch { message = error is CancellationError ? "Model check cancelled. Your current model is unchanged." : error.localizedDescription }
        }
    }
    func cancel() { job?.cancel() }
    func install(_ option: SummaryModelOption, vm: TranscriberViewModel) {
        guard !busy, option.isTrusted, SummaryModelFit.fits(option, memoryBytes: memoryBytes), vm.canReplaceLocalModel,
              option.id != vm.settings.summaryModel, vm.settings.summaryBackend == .localModel else { return }
        let previousID = vm.settings.summaryModel
        busy = true; phase = "Preparing \(option.asset.displayName)…"; message = nil
        job = Task {
            defer { busy = false; phase = nil; job = nil }
            do {
                let previous = try await registry.option(id: previousID)
                let warning = try await LocalInferenceQueue.shared.run { [registry, assets] in
                    let alreadyCached = await assets.isDownloaded(option.asset)
                    return try await ModelReplacement.perform(
                        prepare: {
                            try await assets.checkSpace(for: option.asset)
                            let model = try await assets.ensure(option.asset)
                            let runtime = try await assets.runtime(whisper: false)
                            await MainActor.run { self.phase = "Checking the new model on this Mac…" }
                            try await SummaryModelProbe.check(option: option, model: model, runtime: runtime)
                            try Task.checkCancellation()
                            try await registry.merge([option])
                            try await registry.recordCheck(option)
                        },
                        activate: { try await MainActor.run { try vm.activateLocalSummaryModel(option.id, replacing: previousID) } },
                        removePrevious: {
                            // The queue is still held, and activation checks that
                            // no meeting/recording started during preparation.
                            if previous.asset.sha256 != option.asset.sha256 { _ = try await assets.removeSummaryWeights(previous.asset) }
                        },
                        discardNew: { if !alreadyCached { _ = try? await assets.removeSummaryWeights(option.asset) } }
                    )
                }
                await load(selectedID: option.id)
                message = warning.map { "The new model is ready. The previous download could not be removed: \($0)" }
                    ?? "Using \(option.asset.displayName). The previous model download was removed."
            } catch { message = error is CancellationError ? "Switch cancelled. Your current model was kept." : error.localizedDescription }
        }
    }
}

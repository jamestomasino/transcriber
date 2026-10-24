import Foundation

// MARK: - Model management (download-on-demand, not bundle)
//
// This is the answer to "does the app bundle the models, or download them?"
// It **downloads on demand and caches locally** — it does not bundle them.
// Bundling a Whisper model would bloat the app and the swiftc build (base ≈
// 150 MB, small ≈ 500 MB, medium ≈ 1.5 GB). Instead:
//
//   1. A `ModelSpec` describes a model (id, size, download URL).
//   2. `WhisperCatalog` lists the known sizes with their canonical URLs.
//   3. `ModelDownloader` is a *seam* (an injected closure) so Core stays
//      pure — the real download uses URLSession in the App layer, and tests
//      inject a fake that "downloads" instantly.
//   4. `ModelStore` decides: is the model already cached? If yes, reuse it
//      (offline, no re-download). If no, download it once, verify, and cache.
//
// The App validates pinned hashes for production assets. ModelStore below
// remains a small injected persistence seam for legacy callers and Core tests.

/// A downloadable model. `id` is a stable key (e.g. "whisper-base") used to
/// name the cache file; `sizeBytes` is the expected download size (for UI
/// "downloading 150 MB" and for verifying integrity); `url` is where it comes
/// from.
public struct ModelSpec: Equatable, Sendable, Codable {
    public var id: String
    public var displayName: String
    public var sizeBytes: Int
    public var url: URL
    public var sha256: String?

    public init(id: String, displayName: String, sizeBytes: Int, url: URL, sha256: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.url = url
        self.sha256 = sha256
    }
}

/// Pinned ggml files supported by the bundled-ABI whisper.cpp runtime.
public enum WhisperCatalog {
    public static let defaultID = "whisper-large-v3-q5_0"
    private static let base = "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/"
    public static let all: [ModelSpec] = [
        ModelSpec(id: "whisper-tiny", displayName: "Tiny", sizeBytes: 75_000_000, url: URL(string: base + "ggml-tiny.bin")!),
        ModelSpec(id: "whisper-base", displayName: "Base", sizeBytes: 150_000_000, url: URL(string: base + "ggml-base.bin")!),
        ModelSpec(id: "whisper-small", displayName: "Small", sizeBytes: 500_000_000, url: URL(string: base + "ggml-small.bin")!),
        ModelSpec(id: "whisper-medium", displayName: "Medium", sizeBytes: 1_500_000_000, url: URL(string: base + "ggml-medium.bin")!),
        ModelSpec(id: defaultID, displayName: "Large v3 · accuracy · 1.08 GB", sizeBytes: 1_081_140_203,
                  url: URL(string: base + "ggml-large-v3-q5_0.bin")!, sha256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1"),
        ModelSpec(id: "whisper-large-v3-turbo-q5_0", displayName: "Large v3 Turbo · faster · 574 MB", sizeBytes: 574_041_195,
                  url: URL(string: base + "ggml-large-v3-turbo-q5_0.bin")!, sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2")
    ]
    public static var selectable: [ModelSpec] { all.filter { $0.sha256 != nil } }
    public static func spec(id: String) -> ModelSpec? { all.first { $0.id == id } }
}

/// 4-bit weights keep the baseline useful on 8 GB machines. Larger models
/// require a separate measured profile; do not select one from RAM alone.
public enum SummaryModelCatalog {
    public static let defaultID = "qwen3.5-4b-q4_k_m"
    public static let all = [ModelSpec(
        id: defaultID, displayName: "Qwen 3.5 4B · 4-bit · 3.01 GB", sizeBytes: 3_013_027_808,
        url: URL(string: "https://huggingface.co/bartowski/Qwen_Qwen3.5-4B-GGUF/resolve/4168f45a16a1290d65a4ec0fa312ae917a4c15d6/Qwen_Qwen3.5-4B-Q4_K_M.gguf")!,
        sha256: "13c16f426047e2de38cd075bdade4a7bcbc8c774384876f677740cda65f8a983"
    )]
    public static func spec(id: String) -> ModelSpec? { all.first { $0.id == id } }
    public static let minimumMemoryBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    public static let contextTokens = 8_192
    public static let transcriptBudget = 10_000
}

/// Public model metadata, kept separate from user settings and meeting data.
public struct SummaryModelOption: Codable, Equatable, Identifiable, Sendable {
    public var asset: ModelSpec
    public var repository: String
    public var revision: String
    public var filename: String
    public var architecture: String
    public var parameterBillions: Double
    public var version: String
    public var updatedAt: String
    public var license: String
    public var id: String { asset.id }
    public var sourceURL: URL { URL(string: "https://huggingface.co/\(repository)")! }
    public var isTrusted: Bool {
        let parts = repository.split(separator: "/")
        guard parts.count == 2, ["Qwen", "bartowski"].contains(String(parts[0])),
              Self.matches(String(parts[1]), #"^[A-Za-z0-9][A-Za-z0-9._-]{0,180}$"#),
              Self.matches(revision, #"^[0-9a-f]{40}$"#),
              let hash = asset.sha256, Self.matches(hash, #"^[0-9a-f]{64}$"#),
              Self.matches(filename, #"^[A-Za-z0-9][A-Za-z0-9._-]+\.gguf$"#),
              filename.lowercased().contains("q4_k_m"),
              asset.sizeBytes > 0, asset.sizeBytes < 128 * 1_024 * 1_024 * 1_024,
              parameterBillions.isFinite, parameterBillions >= 1.5, parameterBillions <= 40,
              id == SummaryModelCatalog.defaultID || id == "summary-" + hash else { return false }
        if id == SummaryModelCatalog.defaultID && hash != SummaryModelCatalog.all[0].sha256 { return false }
        return asset.url.absoluteString == "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)"
    }
    private static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
    public static var current: SummaryModelOption {
        let asset = SummaryModelCatalog.all[0]
        return SummaryModelOption(asset: asset, repository: "bartowski/Qwen_Qwen3.5-4B-GGUF",
            revision: "4168f45a16a1290d65a4ec0fa312ae917a4c15d6", filename: "Qwen_Qwen3.5-4B-Q4_K_M.gguf",
            architecture: "qwen35", parameterBillions: 4.326, version: "3.5", updatedAt: "2026-05-19", license: "apache-2.0")
    }
}

/// Decode public Hub metadata without performing any network work in Core.
public enum SummaryModelDiscovery {
    /// Different publishers can quantize the same base model. Keep one clear
    /// choice per model/architecture, preferring the active download, then the
    /// official publisher, then the latest conversion. The registry still keeps
    /// every pinned descriptor so saved selections resolve offline.
    public static func uniqueModels(_ models: [SummaryModelOption], selectedID: String = SummaryModelCatalog.defaultID) -> [SummaryModelOption] {
        var best: [String: SummaryModelOption] = [:]
        for model in models {
            let key = model.architecture + ":" + model.filename.lowercased()
                .replacingOccurrences(of: "qwen_qwen", with: "qwen")
                .replacingOccurrences(of: #"[-_]q4_k_m\.gguf$"#, with: "", options: .regularExpression)
            guard let old = best[key] else { best[key] = model; continue }
            if old.id == selectedID { continue }
            if model.id == selectedID ||
                (model.repository.hasPrefix("Qwen/") && !old.repository.hasPrefix("Qwen/")) ||
                (model.repository.hasPrefix("Qwen/") == old.repository.hasPrefix("Qwen/") && model.updatedAt > old.updatedAt) {
                best[key] = model
            }
        }
        return best.values.sorted { $0.id < $1.id }
    }
    public static func repositories(_ data: Data, author: String, memoryBytes: UInt64) throws -> [String] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw HTTPError.decoding("Invalid model listing") }
        return list.compactMap { item in
            guard let id = item["id"] as? String, id.hasPrefix(author + "/"), eligibleName(id) else { return nil }
            if let match = id.range(of: #"-([0-9]+(?:\.[0-9]+)?)B(?:-|$)"#, options: .regularExpression),
               let size = Double(id[match].dropFirst().split(separator: "B")[0]),
               size > Double(memoryBytes) / 1_073_741_824 { return nil }
            return id
        }
    }
    public static func option(_ data: Data) throws -> SummaryModelOption? {
        guard let info = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let repository = info["id"] as? String, eligibleName(repository),
              let revision = info["sha"] as? String,
              info["private"] as? Bool != true,
              (info["gated"] as? String).map({ $0 == "false" }) ?? (info["gated"] as? Bool != true),
              let gguf = info["gguf"] as? [String: Any], let total = gguf["total"] as? Double,
              let architecture = gguf["architecture"] as? String,
              (gguf["context_length"] as? Int ?? 0) >= SummaryModelCatalog.contextTokens,
              let template = gguf["chat_template"] as? String, !template.isEmpty,
              let siblings = info["siblings"] as? [[String: Any]] else { return nil }
        let card = info["cardData"] as? [String: Any] ?? [:]
        let baseName = (card["base_model"] as? String) ?? (card["base_model"] as? [String]).flatMap { $0.count == 1 ? $0[0] : nil }
            ?? (repository.hasPrefix("Qwen/") ? repository.replacingOccurrences(of: "-GGUF", with: "") : nil)
        guard let base = baseName, base.hasPrefix("Qwen/Qwen"), eligibleName(base) else { return nil }
        for file in siblings {
            guard let name = file["rfilename"] as? String, name.lowercased().hasSuffix("q4_k_m.gguf"),
                  !name.lowercased().contains("mmproj"), !name.contains("/"),
                  let lfs = file["lfs"] as? [String: Any], let hash = lfs["sha256"] as? String,
                  let size = lfs["size"] as? Int, (file["size"] as? Int) == size else { continue }
            if hash == SummaryModelCatalog.all[0].sha256 { return .current }
            let asset = ModelSpec(id: "summary-" + hash, displayName: String(base.split(separator: "/").last ?? "Qwen") + " · Q4_K_M",
                sizeBytes: size, url: URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(name)") ?? URL(string: "about:blank")!, sha256: hash)
            let versionMatch = base.range(of: #"Qwen[0-9]+(?:\.[0-9]+)*"#, options: .regularExpression)
            let version = versionMatch.map { String(base[$0].dropFirst(4)) } ?? "0"
            let option = SummaryModelOption(asset: asset, repository: repository, revision: revision, filename: name,
                architecture: architecture, parameterBillions: total / 1_000_000_000, version: version,
                updatedAt: info["lastModified"] as? String ?? "", license: card["license"] as? String ?? "See model card")
            if option.isTrusted { return option }
        }
        return nil
    }
    private static func eligibleName(_ repository: String) -> Bool {
        let name = repository.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        guard name.hasPrefix("qwen") else { return false }
        return !["coder", "thinking", "-vl", "omni", "embedding", "reranker", "reward", "tts", "asr"].contains { name.contains($0) }
    }
}

public enum SummaryModelFit {
    public static let knownArchitectures: Set<String> = ["qwen2", "qwen3", "qwen3next", "qwen35", "qwen35moe"]
    public static func estimatedMemoryBytes(_ model: SummaryModelOption) -> Double {
        // Weights, bounded inference overhead, and room for macOS/applications.
        // This is an admission estimate, never a measured accuracy/speed claim.
        Double(model.asset.sizeBytes) * 1.2 + 4 * 1_024 * 1_024 * 1_024
    }
    public static func fits(_ model: SummaryModelOption, memoryBytes: UInt64) -> Bool {
        memoryBytes >= SummaryModelCatalog.minimumMemoryBytes && estimatedMemoryBytes(model) <= Double(memoryBytes) * 0.95
    }
    public static func ranked(_ models: [SummaryModelOption], memoryBytes: UInt64) -> [SummaryModelOption] {
        let target = memoryBytes < 16 * 1_024 * 1_024 * 1_024 ? 4.0 :
            (memoryBytes < 24 * 1_024 * 1_024 * 1_024 ? 8.0 : 14.0)
        func preferred(_ model: SummaryModelOption) -> Bool {
            fits(model, memoryBytes: memoryBytes) && knownArchitectures.contains(model.architecture) &&
                model.parameterBillions >= target * 0.6 && model.parameterBillions <= target * 1.35
        }
        return models.sorted { a, b in
            if preferred(a) != preferred(b) { return preferred(a) }
            let version = a.version.compare(b.version, options: .numeric)
            if version != .orderedSame { return version == .orderedDescending }
            let distanceA = abs(a.parameterBillions - target), distanceB = abs(b.parameterBillions - target)
            if distanceA != distanceB { return distanceA < distanceB }
            return a.updatedAt == b.updatedAt ? a.id < b.id : a.updatedAt > b.updatedAt
        }
    }
}

/// The activation boundary is explicit: never remove old bytes before a tested
/// replacement and its selected ID are durable. Cleanup failure keeps the new
/// selection valid and is reported separately, rather than rolling it back.
public enum ModelReplacement {
    public static func perform(
        prepare: () async throws -> Void,
        activate: () async throws -> Void,
        removePrevious: () async throws -> Void,
        discardNew: () async -> Void
    ) async throws -> String? {
        do {
            try await prepare()
            try Task.checkCancellation()
            try await activate()
        } catch {
            await discardNew()
            throw error
        }
        do { try await removePrevious(); return nil }
        catch { return error.localizedDescription }
    }
}

/// Small, separately cached assets for local acoustic speaker matching.
public enum SpeakerModelCatalog {
    public static let segmentation = ModelSpec(id: "speaker-pyannote-3.0", displayName: "Speaker segmentation", sizeBytes: 6_958_444,
        url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2")!,
        sha256: "24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488")
    public static let embedding = ModelSpec(id: "speaker-titanet-small", displayName: "Speaker voice embeddings", sizeBytes: 40_257_283,
        url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/nemo_en_titanet_small.onnx")!,
        sha256: "ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e")
}

/// A download seam so Core stays pure. The App layer supplies a real one
/// (URLSession); tests supply a fake that writes a file instantly.
public protocol ModelDownloader: Sendable {
    /// Download `spec` into `destination`, reporting progress 0...1.
    /// Must not throw if the file already exists and is valid.
    func download(spec: ModelSpec, to destination: URL, report: @Sendable (Double) -> Void) async throws
}

/// Where cached models live: `…/Transcriber/models/<id>.bin`.
public enum ModelsDirectory {
    /// Injectable for tests (points at a temp dir).
    public static var baseDirectory: (() -> URL)?

    public static func base() -> URL {
        if let override = baseDirectory { return override() }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("Transcriber", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    public static func forModel(_ id: String) -> URL {
        base().appendingPathComponent("\(id).bin")
    }
}

/// The download-on-demand model manager. Decides, for a requested model:
///
///   - already cached? → return its URL immediately (offline reuse, no
///     re-download). This is the "use it as needed" part.
///   - not cached?     → download it once via the injected `ModelDownloader`,
///     verify the size, then cache. Subsequent calls hit the cache.
///
/// Pure decision logic (cache hit/miss) is unit-testable in Core; the actual
/// bytes move through the injected downloader.
public final class ModelStore: @unchecked Sendable {
    private let downloader: any ModelDownloader
    private let lock = NSLock()
    /// Models known to be fully downloaded (in-memory, avoids a stat per call).
    private var cached: Set<String> = []

    public init(downloader: any ModelDownloader) {
        self.downloader = downloader
    }

    /// True if the model is already on disk (or known-cached this session).
    public func isCached(_ spec: ModelSpec) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cached.contains(spec.id) { return true }
        let url = ModelsDirectory.forModel(spec.id)
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Ensure the model is available, downloading on first use. Returns the
    /// local URL to load it from.
    @discardableResult
    public func ensure(spec: ModelSpec, report: @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        if isCached(spec) { return ModelsDirectory.forModel(spec.id) }

        let dest = ModelsDirectory.forModel(spec.id)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Download to a temp file, then rename into place atomically, so a
        // partial download is never mistaken for a valid cached model.
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(spec.id).part")
        try? FileManager.default.removeItem(at: tmp)

        do {
            try await downloader.download(spec: spec, to: tmp, report: report)
            // Verify size if the downloader left a file.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: tmp.path),
               let size = attrs[.size] as? Int,
               size < spec.sizeBytes / 4 {
                // Far smaller than expected → almost certainly truncated.
                try? FileManager.default.removeItem(at: tmp)
                throw ModelError.incompleteDownload(spec.id, expected: spec.sizeBytes, got: size)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)
            lock.lock(); cached.insert(spec.id); lock.unlock()
            return dest
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Remove a cached model (e.g. the user frees space).
    public func remove(_ spec: ModelSpec) {
        let url = ModelsDirectory.forModel(spec.id)
        try? FileManager.default.removeItem(at: url)
        lock.lock(); cached.remove(spec.id); lock.unlock()
    }
}

/// Errors from model management.
public enum ModelError: Error, Equatable, Sendable {
    case incompleteDownload(String, expected: Int, got: Int)
    case notFound(String)
    case downloadFailed(String, String)

    public var description: String {
        switch self {
        case .incompleteDownload(let id, let expected, let got):
            return "The \(id) model download was incomplete (\(got) of ~\(expected) bytes). Check your connection and try again."
        case .notFound(let id):
            return "The \(id) model is not available."
        case .downloadFailed(let id, let reason):
            return "The \(id) model download failed: \(reason)"
        }
    }
}

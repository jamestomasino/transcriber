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

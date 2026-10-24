import Foundation
import Combine
import CryptoKit

#if canImport(TranscriberCore)
import TranscriberCore
#endif

struct LocalInferenceError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
final class LocalModelStatus: ObservableObject {
    static let shared = LocalModelStatus()
    @Published var activity: String?
    @Published var fraction: Double = 0
    @Published var error: String?
}

/// Network is used only for pinned public assets. Meeting content never enters
/// this downloader. A temp-root initializer keeps asset tests isolated.
actor LocalModelAssets {
    static let shared = LocalModelAssets(root: ModelsDirectory.base())
    let root: URL
    private let downloader: (any ModelDownloader)?
    private var verified: [String: Date] = [:]
    private var pending: [String: Task<URL, Error>] = [:]
    init(root: URL, downloader: (any ModelDownloader)? = nil) { self.root = root; self.downloader = downloader }

    static let whisperRuntime = ModelSpec(id: "runtime-whisper-b5454", displayName: "Whisper runtime", sizeBytes: 65_816_082,
        url: URL(string: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip")!,
        sha256: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b")
    #if arch(arm64)
    static let llamaRuntime = ModelSpec(id: "runtime-llama-b11840-arm64", displayName: "Summary runtime", sizeBytes: 16_236_017,
        url: URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/b11840/llama-b11840-bin-macos-arm64.tar.gz")!,
        sha256: "f24acd73f63f6c54b02dcee483c6d30d71b7b732e216c9215a932268e5c7d6f4")
    #else
    static let llamaRuntime = ModelSpec(id: "runtime-llama-b11840-x64", displayName: "Summary runtime", sizeBytes: 11_968_728,
        url: URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/b11840/llama-b11840-bin-macos-x64.tar.gz")!,
        sha256: "7fa0ffca7a0966ab408779481ca6ddf4552ab51c606661dd9b43450db5fa2523")
    #endif

    static func validate(_ url: URL, spec: ModelSpec) throws {
        guard let hash = spec.sha256, hash.count == 64 else { throw LocalInferenceError("This model has no pinned integrity checksum.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue == spec.sizeBytes else {
            throw LocalInferenceError("The \(spec.displayName) download is incomplete. Retry the download.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty { digest.update(data: bytes) }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == hash else { throw LocalInferenceError("The \(spec.displayName) checksum did not match. Retry the download.") }
    }

    func isDownloaded(_ spec: ModelSpec) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(spec.id + ".bin").path) else { return false }
        return (attributes[.size] as? NSNumber)?.intValue == spec.sizeBytes
    }

    func ensure(_ spec: ModelSpec) async throws -> URL {
        if let task = pending[spec.id] { return try await waitForShared(task) }
        let task = Task { try await self.fetch(spec) }
        pending[spec.id] = task
        defer { pending[spec.id] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func waitForShared(_ task: Task<URL, Error>) async throws -> URL {
        let waiter = AssetWaiter()
        Task { waiter.finish(await task.result) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter.begin($0) }
        } onCancel: { waiter.finish(.failure(CancellationError())) }
    }

    private func fetch(_ spec: ModelSpec) async throws -> URL {
        try Task.checkCancellation()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(spec.id + ".bin")
        if fm.fileExists(atPath: destination.path) {
            let date = (try? fm.attributesOfItem(atPath: destination.path)[.modificationDate]) as? Date
            if let date, verified[spec.id] == date { return destination }
            do {
                try Self.validate(destination, spec: spec)
                verified[spec.id] = date
                return destination
            } catch { /* Replace corrupt assets only after a new download verifies. */ }
        }
        let staging = root.appendingPathComponent(".\(spec.id)-\(UUID().uuidString).part")
        defer { try? fm.removeItem(at: staging) }
        await MainActor.run { LocalModelStatus.shared.activity = "Downloading \(spec.displayName)"; LocalModelStatus.shared.fraction = 0; LocalModelStatus.shared.error = nil }
        defer { Task { @MainActor in LocalModelStatus.shared.activity = nil } }
        let report: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in LocalModelStatus.shared.fraction = fraction }
        }
        if let downloader { try await downloader.download(spec: spec, to: staging, report: report) }
        else { try await AssetDownload.download(spec.url, to: staging, resumeAt: root.appendingPathComponent(".\(spec.id).resume"), report: report) }
        await MainActor.run { LocalModelStatus.shared.activity = "Verifying \(spec.displayName)" }
        try Self.validate(staging, spec: spec)
        try Task.checkCancellation()
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else { try fm.moveItem(at: staging, to: destination) }
        verified[spec.id] = (try fm.attributesOfItem(atPath: destination.path)[.modificationDate]) as? Date
        return destination
    }

    func runtime(whisper: Bool) async throws -> URL {
        let spec = whisper ? Self.whisperRuntime : Self.llamaRuntime
        let archive = try await ensure(spec)
        let folder = root.appendingPathComponent(spec.id, isDirectory: true)
        let relative = whisper ? "whisper.framework/whisper" : "llama-server"
        let binary = folder.appendingPathComponent(relative)
        // Verify the installed binary against its own recorded digest as well
        // as verifying the pinned archive on first use in each session.
        if let digest = try? String(contentsOf: folder.appendingPathComponent("installed.sha256"), encoding: .utf8),
           let data = try? Data(contentsOf: binary), SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest {
            return binary
        }
        let temporary = root.appendingPathComponent(".runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisper ? "/usr/bin/unzip" : "/usr/bin/tar")
        process.arguments = whisper ? ["-q", archive.path, "-d", temporary.path] : ["-xzf", archive.path, "-C", temporary.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LocalInferenceError("The local runtime archive could not be unpacked.") }
        let source = temporary.appendingPathComponent(whisper ? "build-apple/whisper.xcframework/macos-arm64_x86_64/whisper.framework" : "llama-b11840")
        let ready = temporary.appendingPathComponent("ready")
        if whisper {
            try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: ready.appendingPathComponent("whisper.framework"))
        } else { try FileManager.default.moveItem(at: source, to: ready) }
        let installed = ready.appendingPathComponent(relative)
        let data = try Data(contentsOf: installed)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try digest.write(to: ready.appendingPathComponent("installed.sha256"), atomically: true, encoding: .utf8)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try FileManager.default.moveItem(at: ready, to: folder)
        return binary
    }
}

private final class AssetWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    func begin(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation; self.continuation = nil
        lock.unlock(); continuation?.resume(with: result)
    }
}

private final class AssetDownload: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var cancelled = false
    private var lastProgress = -1.0
    private var resumeURL: URL?
    func cancel() {
        lock.lock(); cancelled = true; let task = task; let resumeURL = resumeURL; lock.unlock()
        task?.cancel { data in if let data, let resumeURL { try? data.write(to: resumeURL, options: .atomic) } }
    }
    static func download(_ url: URL, to destination: URL, resumeAt resumeURL: URL, report: @escaping @Sendable (Double) -> Void) async throws {
        let state = AssetDownload()
        state.resumeURL = resumeURL
        let resumeData = try? Data(contentsOf: resumeURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 14_400
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let completion: @Sendable (URL?, URLResponse?, Error?) -> Void = { temporary, response, error in
                    state.lock.lock(); let observation = state.observation; state.observation = nil; state.task = nil; state.lock.unlock()
                    observation?.invalidate()
                    do {
                        if let error {
                            if let data = (error as NSError).userInfo["NSURLSessionDownloadTaskResumeData"] as? Data {
                                try? data.write(to: resumeURL, options: .atomic)
                            } else if resumeData != nil { try? FileManager.default.removeItem(at: resumeURL) }
                            throw error
                        }
                        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), let temporary else {
                            throw LocalInferenceError("The model could not be downloaded. Check your connection and retry.")
                        }
                        try FileManager.default.moveItem(at: temporary, to: destination)
                        try? FileManager.default.removeItem(at: resumeURL)
                        continuation.resume()
                    } catch { continuation.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error) }
                }
                let task = resumeData.map { session.downloadTask(withResumeData: $0, completionHandler: completion) }
                    ?? session.downloadTask(with: url, completionHandler: completion)
                state.lock.lock()
                state.task = task
                state.observation = task.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                    state.lock.lock()
                    let value = progress.fractionCompleted
                    let update = value - state.lastProgress >= 0.005 || value >= 1
                    if update { state.lastProgress = value }
                    state.lock.unlock()
                    if update { report(value) }
                }
                let cancelled = state.cancelled
                state.lock.unlock()
                if cancelled { task.cancel() } else { task.resume() }
            }
        } onCancel: { state.cancel() }
    }
}

/// Models from concurrent meetings never coexist in memory. Cancellation of a
/// queued job stops that job while allowing the preceding job to release its model.
actor LocalInferenceQueue {
    static let shared = LocalInferenceQueue()
    private var busy = false
    private var order: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
    private func acquire() async throws {
        try Task.checkCancellation()
        if !busy { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                order.append(id); waiters[id] = continuation
            }
        } onCancel: { Task { await self.cancelWaiting(id) } }
    }
    private func cancelWaiting(_ id: UUID) {
        order.removeAll { $0 == id }
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
    private func release() {
        while !order.isEmpty {
            let id = order.removeFirst()
            if let continuation = waiters.removeValue(forKey: id) { continuation.resume(); return }
        }
        busy = false
    }
}

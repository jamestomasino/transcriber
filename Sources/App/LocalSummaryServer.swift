import Foundation
import Darwin
#if canImport(TranscriberCore)
import TranscriberCore
#endif

/// A private, permission-protected Unix socket. There is no listening TCP port,
/// web UI, credential file, prompt log, or externally reachable model service.
final class LocalSummaryServer: @unchecked Sendable {
    let directory: URL
    let socketURL: URL
    private let process = Process()
    private let input = Pipe()
    private var stopped = false

    init(executable: URL, model: URL, threads: Int = 4) throws {
        guard (1...4).contains(threads) else { throw LocalInferenceError("Invalid local model thread limit.") }
        directory = URL(fileURLWithPath: "/private/tmp/transcriber-lm-\(UUID().uuidString.prefix(12))", isDirectory: true)
        socketURL = directory.appendingPathComponent("model.sock")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // EOF on this pipe also stops the child if the app crashes. All variable
        // arguments are passed as argv, never interpolated into shell code.
        process.qualityOfService = .utility
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "umask 077; \"$@\" </dev/null & child=$!; printf '%s\\n' \"$child\" > \"$TMPDIR/model.pid\"; trap 'kill \"$child\" 2>/dev/null; wait \"$child\" 2>/dev/null' EXIT; trap 'exit 0' INT TERM; IFS= read -r stop; exit 0", "local-model",
            "/usr/bin/nice", "-n", "10", executable.path, "--model", model.path, "--host", socketURL.path,
            "--ctx-size", String(SummaryModelCatalog.contextTokens), "--parallel", "1",
            "--batch-size", "256", "--ubatch-size", "128", "--threads", String(threads),
            "--cache-ram", "0", "--no-cache-idle-slots", "--ctx-checkpoints", "0", "--no-context-shift",
            "--no-webui", "--no-slots", "--no-agent", "--no-ui-mcp-proxy", "--log-disable",
            "--reasoning-budget", "0", "--chat-template-kwargs", "{\"enable_thinking\":false}"]
        process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": directory.path, "LANG": "en_US.UTF-8"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func waitUntilReady() async throws {
        let deadline = Date().addingTimeInterval(180)
        let client = UnixModelHTTPClient(socket: socketURL, timeout: 2)
        while Date() < deadline {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: socketURL.path),
               let response = try? await client.send(HTTPRequest(url: URL(string: "http://localhost/health")!, method: "GET")), response.statusCode == 200 { return }
            guard process.isRunning else { throw LocalInferenceError("The local summary runtime stopped while loading the model.") }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw LocalInferenceError("The local summary model did not become ready. Check available memory and retry.")
    }
    func countTokens(messages: [[String: String]]) async throws -> Int {
        let client = UnixModelHTTPClient(socket: socketURL)
        func send(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
            let response = try await client.send(HTTPRequest(url: URL(string: "http://localhost" + path)!,
                headers: ["Content-Type": "application/json"], body: try JSONSerialization.data(withJSONObject: body)))
            guard response.statusCode == 200, let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
                throw LocalInferenceError("The local runtime could not check the summary context. Audio was kept.")
            }
            return object
        }
        let formatted = try await send("/apply-template", ["messages": messages, "chat_template_kwargs": ["enable_thinking": false]])
        guard let prompt = formatted["prompt"] as? String else { throw LocalInferenceError("The summary chat template could not be checked.") }
        let tokenized = try await send("/tokenize", ["content": prompt, "add_special": false, "parse_special": true])
        guard let tokens = tokenized["tokens"] as? [Int] else { throw LocalInferenceError("The summary tokens could not be counted.") }
        return tokens.count
    }
    /// Must finish before the inference guard releases its slot. Run cleanup
    /// independently of caller cancellation, without blocking the main actor.
    func shutdown() async throws {
        let task = Task.detached(priority: .utility) { try await self.finishShutdown() }
        do { try await task.value }
        catch {
            await LocalInferenceQueue.shared.quarantine()
            throw error
        }
    }
    private func finishShutdown() async throws {
        guard !stopped else { return }
        stopped = true
        let start = ProcessInfo.processInfo.systemUptime
        defer { Task { await ProcessingMeasurements.shared.record("helper.shutdown", seconds: ProcessInfo.processInfo.systemUptime - start) } }
        // Capture the PID while the owning shell is alive; its EXIT trap reaps
        // that child. Never signal an unowned process after the wrapper exits.
        var child: Int32?
        for _ in 0..<50 {
            if let text = try? String(contentsOf: directory.appendingPathComponent("model.pid"), encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 { child = pid; break }
            if !process.isRunning { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try? input.fileHandleForWriting.close()
        func wait(_ seconds: Double) async throws -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return !process.isRunning
        }
        if try await !wait(1) {
            if let child, process.isRunning { Darwin.kill(child, SIGTERM) }
            // Do not signal the shell while its EXIT trap is waiting: TERM
            // can interrupt wait and orphan a TERM-ignoring model. Keep the
            // owning shell alive until it reaps the child we just signaled.
            if child == nil, process.isRunning { process.terminate() }
            if try await !wait(1) {
                if let child, process.isRunning { Darwin.kill(child, SIGKILL) }
                _ = try await wait(1)
            }
        }
        guard let child, !process.isRunning, Darwin.kill(child, 0) != 0, errno == ESRCH else {
            throw LocalInferenceError("The previous summary model has not exited. Further local inference is blocked; restart Transcriber after the helper has stopped. Audio was kept.")
        }
        try FileManager.default.removeItem(at: directory)
    }
    static func withServer<T: Sendable>(executable: URL, model: URL, threads: Int = 4,
                                         operation: (LocalSummaryServer) async throws -> T) async throws -> T {
        let server = try LocalSummaryServer(executable: executable, model: model, threads: threads)
        let result: Result<T, Error>
        do { result = .success(try await operation(server)) }
        catch { result = .failure(error) }
        try await server.shutdown()
        return try result.get()
    }
    deinit {
        // Last-resort EOF guard; production callers always await withServer.
        try? input.fileHandleForWriting.close()
    }

}

struct DownloadedModelSummarizer: MeetingSummarizer {
    let modelID: String
    var reuseSections = false
    var modelAdmission: @Sendable () async throws -> Void = {}
    func summarize(segments: [TranscriptSegment], title: String) async throws -> MeetingSummary {
        try await summarize(segments: segments, title: title, meeting: nil)
    }
    func summarize(segments: [TranscriptSegment], title: String, meeting: Meeting) async throws -> MeetingSummary {
        try await summarize(segments: segments, title: title, meeting: Optional(meeting))
    }
    private func summarize(segments: [TranscriptSegment], title: String, meeting: Meeting?) async throws -> MeetingSummary {
        guard ProcessInfo.processInfo.physicalMemory >= SummaryModelCatalog.minimumMemoryBytes else {
            throw LocalInferenceError("The downloadable summary model needs at least 8 GB of memory. Choose another backend in Settings.")
        }
        let option = try await SummaryModelRegistry.shared.option(id: modelID)
        guard SummaryModelFit.fits(option, memoryBytes: ProcessInfo.processInfo.physicalMemory) else {
            throw LocalInferenceError("The selected summary model needs more memory than this Mac has. Choose a smaller model in Settings.")
        }
        // Download/verification does not occupy the native inference guard.
        let model = try await ProcessingMeasurements.measure("summary.assets") { try await LocalModelAssets.shared.ensure(option.asset) }
        let runtime = try await LocalModelAssets.shared.runtime(whisper: false)
        let cacheURL = reuseSections ? meeting.map { RecordingsDirectory.summarySectionsURL(for: $0) } : nil
        let cache = SummarySectionStore(url: cacheURL)
        do {
            let result = try await LocalInferenceQueue.shared.run {
                try await modelAdmission()
                return try await LocalSummaryServer.withServer(executable: runtime, model: model) { server in
                    try await ProcessingMeasurements.measure("summary.modelLoad") { try await server.waitUntilReady() }
                    let inner = LocalJSONSummarizer(model: modelID, http: UnixModelHTTPClient(socket: server.socketURL), countTokens: { try await server.countTokens(messages: $0) })
                    let reusing = ReusingSectionSummarizer(inner: inner, cache: cache, modelHash: option.asset.sha256!)
                    var summary = try await ChunkingSummarizer(inner: reusing, transcriptBudget: SummaryModelCatalog.transcriptBudget)
                        .summarize(segments: segments, title: title)
                    summary.model = option.asset.displayName
                    return summary
                }
            }
            try Summary.validateDetail(result, segments: segments)
            try cache.remove()
            return result
        } catch {
            // Partial notes are useful after an ordinary failed opted-in retry;
            // explicit cancellation and default retention leave no section file.
            if error is CancellationError || Task.isCancelled || !reuseSections { try? cache.remove() }
            throw error
        }
    }

}

/// Only the Unix socket is used; HTTPRequest.url supplies the route, not a
/// network destination. Content is never written to disk or a process argument.
struct UnixModelHTTPClient: HTTPClient {
    let socket: URL
    var timeout: Int = 900
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let connection = UnixConnection()
        return try await withTaskCancellationHandler {
            do {
                let response = try await Task.detached(priority: .utility) { try connection.send(request, socket: socket, timeout: timeout) }.value
                try Task.checkCancellation()
                return response
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: { connection.cancel() }
    }
}

private final class UnixConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var cancelled = false
    func cancel() {
        lock.lock()
        cancelled = true
        // Shutdown wakes a blocking read; the worker alone closes its descriptor,
        // preventing a cancelled request from touching a reused descriptor.
        if descriptor >= 0 { Darwin.shutdown(descriptor, SHUT_RDWR) }
        lock.unlock()
    }
    private func finish() {
        lock.lock(); let fd = descriptor; descriptor = -1; lock.unlock()
        if fd >= 0 { Darwin.close(fd) }
    }
    func send(_ request: HTTPRequest, socket path: URL, timeout: Int) throws -> HTTPResponse {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalInferenceError("Could not create the local model connection.") }
        lock.lock()
        if cancelled { lock.unlock(); Darwin.close(fd); throw CancellationError() }
        descriptor = fd; lock.unlock()
        defer { finish() }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var interval = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout.size(ofValue: interval)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout.size(ofValue: interval)))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = path.path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw LocalInferenceError("The local model socket path is too long.") }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
                bytes.withUnsafeBufferPointer { destination.update(from: $0.baseAddress!, count: $0.count) }
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw LocalInferenceError("The local model is not ready.") }
        let body = request.body ?? Data()
        var header = "\(request.method) \(request.url.path.isEmpty ? "/" : request.url.path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        for (key, value) in request.headers { header += "\(key): \(value)\r\n" }
        var packet = Data((header + "\r\n").utf8); packet.append(body)
        try packet.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard sent > 0 else { throw LocalInferenceError("The local model connection ended before the request was sent.") }
                offset += sent
            }
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                lock.lock(); let wasCancelled = cancelled; lock.unlock()
                if wasCancelled { throw CancellationError() }
                throw LocalInferenceError("The local model connection timed out or ended unexpectedly. The transcript was kept.")
            }
            response.append(contentsOf: buffer.prefix(count))
            guard response.count < 20_000_000 else { throw LocalInferenceError("The local model response exceeded its limit.") }
        }
        guard let split = response.range(of: Data("\r\n\r\n".utf8)),
              let headers = String(data: response[..<split.lowerBound], encoding: .utf8),
              let line = headers.components(separatedBy: "\r\n").first,
              let code = Int(line.split(separator: " ").dropFirst().first ?? "") else {
            throw LocalInferenceError("The local model returned an invalid response.")
        }
        var payload = Data(response[split.upperBound...])
        if headers.lowercased().contains("transfer-encoding: chunked") { payload = try Self.decodeChunks(payload) }
        return HTTPResponse(statusCode: code, body: payload)
    }
    private static func decodeChunks(_ data: Data) throws -> Data {
        var remaining = data[...]
        var output = Data()
        while let line = remaining.range(of: Data("\r\n".utf8)),
              let sizeText = String(data: remaining[..<line.lowerBound], encoding: .ascii)?.split(separator: ";").first,
              let size = Int(sizeText, radix: 16) {
            if size == 0 { return output }
            remaining = remaining[line.upperBound...]
            guard size >= 0, remaining.count >= size + 2 else { break }
            output.append(contentsOf: remaining.prefix(size))
            remaining = remaining.dropFirst(size + 2)
        }
        throw LocalInferenceError("The local model response was incomplete.")
    }
}

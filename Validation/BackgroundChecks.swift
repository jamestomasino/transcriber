import Foundation
import AVFoundation
import Darwin

/// Opt-in, cached-model benchmark. Only public synthetic speech is processed.
/// No settings, library, selected assets, downloads or retention choices change.
@main
struct BackgroundChecks {
    static func main() async {
        setbuf(stdout, nil)
        do { try await run() } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
    static func run() async throws {
        let args = CommandLine.arguments
        guard args.contains("--run-models") else {
            print("Usage: bash Validation/run.sh background --run-models [--threads 2|4] [--rounds 1...3]")
            print("Uses cached models only; emits numeric measurements, never meeting content.")
            return
        }
        func number(_ name: String, fallback: Int) -> Int {
            guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return fallback }
            return Int(args[i + 1]) ?? 0
        }
        let threads = number("--threads", fallback: 4), rounds = number("--rounds", fallback: 1)
        guard [2, 4].contains(threads), (1...3).contains(rounds) else { throw LocalInferenceError("Choose threads 2 or 4 and rounds 1 through 3.") }
        let whisperSpec = WhisperCatalog.spec(id: WhisperCatalog.defaultID)!
        let summarySpec = SummaryModelCatalog.all[0]
        for spec in [whisperSpec, summarySpec, LocalModelAssets.whisperRuntime, LocalModelAssets.llamaRuntime] {
            guard await LocalModelAssets.shared.isDownloaded(spec) else { throw LocalInferenceError("Required benchmark assets are not cached. Download them explicitly in Settings first.") }
        }
        let scheduling = BackgroundProcessingScheduler()
        BackgroundResourceMonitor.shared.start(scheduling: scheduling)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcriber-background-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("public-fixture.aiff")
        let text = "Alex will send the pharmacovigilance report by Friday. Priya will review the pharmacokinetics data on Monday. The team agreed to keep the dose at 50 milligrams. Do not increase the dose."
        let say = Process()
        say.qualityOfService = .utility
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-r", "180", "-o", audio.path, text]
        try say.run(); say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw LocalInferenceError("Synthetic speech could not be prepared.") }
        let file = try AVAudioFile(forReading: audio)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let summaryModel = try await LocalModelAssets.shared.ensure(summarySpec)
        let runtime = try await LocalModelAssets.shared.runtime(whisper: false)
        await ProcessingMeasurements.shared.reset()
        let resources = BenchmarkResourceSampler()
        resources.start()
        defer { resources.cancel() }
        var allChecksPassed = true
        for round in 1...rounds {
            let checksPassed = try await scheduling.run(id: UUID(), report: { _ in }) {
                let start = ProcessInfo.processInfo.systemUptime
                let transcriber = WhisperTranscriber(modelID: WhisperCatalog.defaultID, vocabulary: "pharmacovigilance, pharmacokinetics", threadLimit: threads, modelAdmission: { try await scheduling.checkpoint() })
                let transcript = try await transcriber.transcribe(audio: CapturedAudio(fileURLs: [.mic: audio]), language: "en")
                let seconds = ProcessInfo.processInfo.systemUptime - start
                let words = transcript.map(\.text).joined(separator: " ").lowercased()
                let transcriptionPassed = words.contains("pharmacovigilance") && words.contains("pharmacokinetics") && words.contains("friday") && words.contains("monday")
                await ProcessingMeasurements.shared.record("benchmark.transcription", seconds: seconds)
                print("round=\(round) threads=\(threads) audio_seconds=\(duration) transcription_seconds=\(seconds)")
                try await scheduling.checkpoint()
                let summaryStart = ProcessInfo.processInfo.systemUptime
                let notes = try await LocalInferenceQueue.shared.run {
                    try await scheduling.checkpoint()
                    return try await LocalSummaryServer.withServer(executable: runtime, model: summaryModel, threads: threads) { server in
                        for _ in 0..<50 {
                            if let text = try? String(contentsOf: server.directory.appendingPathComponent("model.pid"), encoding: .utf8),
                               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                resources.observe(pid); break
                            }
                            try await Task.sleep(nanoseconds: 10_000_000)
                        }
                        defer { resources.observe(nil) }
                        try await ProcessingMeasurements.measure("summary.modelLoad") { try await server.waitUntilReady() }
                        return try await LocalJSONSummarizer(model: SummaryModelCatalog.defaultID,
                            http: SeededBenchmarkHTTP(inner: UnixModelHTTPClient(socket: server.socketURL)), maximumOutputTokens: 512,
                            countTokens: { try await server.countTokens(messages: $0) })
                            .summarize(segments: [TranscriptSegment(speaker: "Alex", text: text)], title: "Public performance fixture")
                    }
                }
                let actions = notes.actionItems.joined(separator: " ").lowercased()
                let summaryPassed = actions.contains("alex") && actions.contains("priya") && actions.contains("friday") && actions.contains("monday")
                await ProcessingMeasurements.shared.record(summaryPassed ? "benchmark.summaryQualityPassed" : "benchmark.summaryQualityFailed", seconds: 0)
                print("round=\(round) threads=\(threads) summary_seconds=\(ProcessInfo.processInfo.systemUptime - summaryStart) transcription_quality_passed=\(transcriptionPassed) summary_quality_passed=\(summaryPassed)")
                return transcriptionPassed && summaryPassed
            }
            allChecksPassed = allChecksPassed && checksPassed
        }
        await resources.finish()
        let resourceData = try JSONEncoder().encode(resources.snapshot())
        print(String(decoding: resourceData, as: UTF8.self))
        let data = try JSONEncoder().encode(await ProcessingMeasurements.shared.snapshot())
        print(String(decoding: data, as: UTF8.self))
        guard allChecksPassed else { throw LocalInferenceError("A profile failed fixture quality checks. Numeric diagnostics were emitted; this profile must not be promoted.") }
        print("Synthetic fixture passed; no saved meeting, model selection or assets changed.")
    }
}

/// Optional test-only sampling. RSS excludes some GPU allocations, system swap
/// includes other apps, and main-actor dispatch delay is a responsiveness proxy,
/// not a measurement of browser/video-call interaction latency. CPU percentages
/// are sampled process-lifetime averages, not instantaneous utilization or quotas.
private final class BenchmarkResourceSampler: @unchecked Sendable {
    struct Sample: Codable {
        let appRSSBytes: UInt64
        let modelRSSBytes: UInt64
        let appLifetimeCPUPercent: Double
        let modelLifetimeCPUPercent: Double
        let systemSwapUsedMB: Double?
        let thermalState: Int
        let mainActorDispatchMilliseconds: Double
    }
    private let lock = NSLock()
    private var pid: Int32?
    private var samples: [Sample] = []
    private var task: Task<Void, Never>?
    func observe(_ pid: Int32?) { lock.withLock { self.pid = pid } }
    func snapshot() -> [Sample] { lock.withLock { samples } }
    func cancel() { task?.cancel() }
    func finish() async { task?.cancel(); await task?.value }
    func start() {
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let start = ProcessInfo.processInfo.systemUptime
                await MainActor.run {}
                let delay = (ProcessInfo.processInfo.systemUptime - start) * 1000
                let pid = self.lock.withLock { self.pid }
                let app = Self.statistics(getpid()), model = pid.map(Self.statistics) ?? (rss: 0, cpu: 0)
                let sample = Sample(appRSSBytes: app.rss, modelRSSBytes: model.rss,
                    appLifetimeCPUPercent: app.cpu, modelLifetimeCPUPercent: model.cpu,
                    systemSwapUsedMB: Self.swap(), thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                    mainActorDispatchMilliseconds: delay)
                self.lock.withLock { if self.samples.count < 3600 { self.samples.append(sample) } }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    private static func output(_ executable: String, _ arguments: [String]) -> String {
        let process = Process(), pipe = Pipe()
        process.qualityOfService = .utility
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: bytes, as: UTF8.self)
        } catch { return "" }
    }
    private static func statistics(_ pid: Int32) -> (rss: UInt64, cpu: Double) {
        let fields = output("/bin/ps", ["-o", "%cpu=,rss=", "-p", String(pid)]).split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 2 else { return (0, 0) }
        return ((UInt64(fields[1]) ?? 0) * 1024, Double(fields[0]) ?? 0)
    }
    private static func swap() -> Double? {
        let value = output("/usr/sbin/sysctl", ["-n", "vm.swapusage"])
        guard let used = value.components(separatedBy: "used = ").last?.split(separator: " ").first else { return nil }
        return Double(used.dropLast())
    }
}

/// A fixed benchmark seed isolates the profile comparison from random sampling.
/// Production generation settings are untouched.
private struct SeededBenchmarkHTTP: HTTPClient {
    let inner: UnixModelHTTPClient
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var request = request
        if let body = request.body, var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            object["seed"] = 42
            request.body = try JSONSerialization.data(withJSONObject: object)
        }
        return try await inner.send(request)
    }
}

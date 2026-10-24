import Foundation
import AVFoundation
import CryptoKit
#if canImport(TranscriberCore)
import TranscriberCore
#endif

struct SpeakerAssets: Sendable {
    let executable: URL
    let segmentation: URL
    let embedding: URL
    #if arch(arm64)
    static let runtime = ModelSpec(id: "runtime-speaker-1.13.8-arm64", displayName: "Speaker matching runtime", sizeBytes: 18_252_168,
        url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts.tar.bz2")!,
        sha256: "91b96512c4fa1960f8a9ed5360a6c8dda53a4b5015d0590244f14086a234557a")
    static let runtimeRoot = "sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts"
    #else
    static let runtime = ModelSpec(id: "runtime-speaker-1.13.8-x64", displayName: "Speaker matching runtime", sizeBytes: 20_646_120,
        url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-osx-x64-shared-no-tts.tar.bz2")!,
        sha256: "03fd4cffd98b239d74b9253c270ff637661adb4d51a5a6c9e1f7486e48306db3")
    static let runtimeRoot = "sherpa-onnx-v1.13.8-osx-x64-shared-no-tts"
    #endif

    static func prepare() async throws -> SpeakerAssets {
        let cache = LocalModelAssets.shared
        let runtimeFolder = try await cache.speakerArchive(runtime, member: runtimeRoot,
            required: ["bin/sherpa-onnx-offline-speaker-diarization", "lib/libonnxruntime.dylib"])
        let segmentationFolder = try await cache.speakerArchive(SpeakerModelCatalog.segmentation,
            member: "sherpa-onnx-pyannote-segmentation-3-0", required: ["model.onnx", "LICENSE"])
        let embedding = try await cache.ensure(SpeakerModelCatalog.embedding)
        return SpeakerAssets(executable: runtimeFolder.appendingPathComponent("bin/sherpa-onnx-offline-speaker-diarization"),
                             segmentation: segmentationFolder.appendingPathComponent("model.onnx"), embedding: embedding)
    }
}

extension LocalModelAssets {
    /// Validate the pinned archive and all required installed payloads. Neither
    /// weights nor executables are shipped in the app or needed during builds.
    func speakerArchive(_ spec: ModelSpec, member: String, required: [String]) async throws -> URL {
        let archive = try await ensure(spec)
        let folder = root.appendingPathComponent(spec.id, isDirectory: true)
        let manifestURL = folder.appendingPathComponent("installed.json")
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode([String: String].self, from: data),
           required.allSatisfy({ name in
               guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return false }
               return manifest[name] == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
           }) { return folder }
        let staging = root.appendingPathComponent(".speaker-unpack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let unpack = Process()
        unpack.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        unpack.arguments = ["-xjf", archive.path, "-C", staging.path]
        unpack.standardOutput = FileHandle.nullDevice; unpack.standardError = FileHandle.nullDevice
        try unpack.run(); unpack.waitUntilExit()
        guard unpack.terminationStatus == 0 else { throw LocalInferenceError("The speaker model archive could not be unpacked.") }
        try Task.checkCancellation()
        let ready = staging.appendingPathComponent(member)
        var manifest: [String: String] = [:]
        for name in required {
            let data = try Data(contentsOf: ready.appendingPathComponent(name))
            manifest[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        try JSONEncoder().encode(manifest).write(to: ready.appendingPathComponent("installed.json"), options: .atomic)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try FileManager.default.moveItem(at: ready, to: folder)
        return folder
    }
}

/// Real acoustic segmentation + embeddings + meeting-wide clustering. The
/// native helper sees only a managed transient WAV, never a transcript or key.
struct LocalSpeakerDiarizer: AudioDiarizer {
    var modelAdmission: @Sendable () async throws -> Void = {}
    func diarize(_ segments: [TranscriptSegment]) async throws -> [TranscriptSegment] {
        throw LocalInferenceError("Voice matching requires the retained meeting audio.")
    }

    func diarize(_ segments: [TranscriptSegment], audio: CapturedAudio,
                 report: @escaping @Sendable (ProcessingProgress) -> Void) async throws -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }
        let assets = try await SpeakerAssets.prepare()
        return try await LocalInferenceQueue.shared.run {
            try await modelAdmission()
            let files = [AudioSource.mic, .system].compactMap { audio.fileURLs[$0] }
            guard let first = files.first else { throw LocalInferenceError("Retained audio is required to update speaker labels.") }
            let folder = first.deletingLastPathComponent()
            let mixed = folder.appendingPathComponent(CapturedAudio.preparedFileName)
            let wave = folder.appendingPathComponent(CapturedAudio.speakerAudioFileName)
            defer {
                try? FileManager.default.removeItem(at: wave)
                if files.count > 1 { try? FileManager.default.removeItem(at: mixed) }
            }
            let input: URL
            if files.count > 1 {
                try? FileManager.default.removeItem(at: mixed)
                let offsets = Dictionary(audio.fileURLs.map { ($0.value, audio.startOffsets[$0.key] ?? 0) }, uniquingKeysWith: min)
                try await AudioPreparation.mix(files, to: mixed, offsets: offsets)
                input = mixed
            } else { input = first }
            let preparation = Task.detached(priority: .utility) { try Self.prepareWave(input: input, output: wave) }
            try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
            try Task.checkCancellation()
            try await modelAdmission()
            let output = try await SpeakerAnalysisProcess().run(assets: assets, wave: wave, report: report)
            let turns = try Self.parse(output)
            let labeled = SpeakerAlignment.label(segments, turns: turns)
            guard labeled.contains(where: { $0.speaker != SpeakerAlignment.unknownSpeaker }) else {
                throw LocalInferenceError("No speaker voices could be matched. The previous transcript and summary were kept.")
            }
            report(ProcessingProgress(stage: .diarizing, fraction: 1))
            return labeled
        }
    }

    static func prepareWave(input: URL, output: URL) throws {
        let source = try AVAudioFile(forReading: input)
        // Bound the offline helper's whole-file float buffer to ~460 MB.
        // Longer recordings retain all speech, but need a streaming diarizer.
        guard Double(source.length) / source.processingFormat.sampleRate <= 2 * 60 * 60 else {
            throw LocalInferenceError("Local voice matching currently supports recordings up to two hours. Original audio was kept.")
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let destination = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        while source.framePosition < source.length {
            try Task.checkCancellation()
            let samples = try WhisperAudio.readSection(source, seconds: 30)
            guard !samples.isEmpty else { break }
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
            try destination.write(from: buffer)
        }
        if #available(macOS 15, *) { destination.close() }
    }

    static func parse(_ output: String) throws -> [SpeakerTurn] {
        let regex = try NSRegularExpression(pattern: #"^([0-9]+\.[0-9]+) -- ([0-9]+\.[0-9]+) speaker_([0-9]+)"#, options: .anchorsMatchLines)
        return regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).compactMap { match in
            func field(_ n: Int) -> String { Range(match.range(at: n), in: output).map { String(output[$0]) } ?? "" }
            guard let start = Double(field(1)), let end = Double(field(2)), let speaker = Int(field(3)), end > start else { return nil }
            return SpeakerTurn(start: start, end: end, speaker: speaker)
        }
    }
}

final class SpeakerAnalysisProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var child: Process?
    private var cancelled = false

    func run(assets: SpeakerAssets, wave: URL,
             report: @escaping @Sendable (ProcessingProgress) -> Void) async throws -> String {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try self.execute(assets: assets, wave: wave, report: report) }.value
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let process = child; lock.unlock()
        process?.terminate()
    }
    private func execute(assets: SpeakerAssets, wave: URL,
                         report: @escaping @Sendable (ProcessingProgress) -> Void) throws -> String {
        let process = Process(), input = Pipe(), output = Pipe(), progress = Pipe()
        process.qualityOfService = .utility
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "umask 077; exec 3<&0; \"$@\" </dev/null & child=$!; (IFS= read -r stop <&3; kill \"$child\" 2>/dev/null) & watcher=$!; trap 'kill \"$child\" \"$watcher\" 2>/dev/null; wait \"$child\" \"$watcher\" 2>/dev/null' EXIT; trap 'exit 130' INT TERM; wait \"$child\"; result=$?; kill \"$watcher\" 2>/dev/null; wait \"$watcher\" 2>/dev/null; exit \"$result\"", "speaker-model",
            "/usr/bin/nice", "-n", "10", assets.executable.path, "--segmentation.pyannote-model=\(assets.segmentation.path)",
            "--embedding.model=\(assets.embedding.path)", "--embedding.num-threads=2", "--segmentation.num-threads=2",
            "--clustering.num-clusters=-1",
            "--clustering.cluster-threshold=0.8", wave.path]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = input; process.standardOutput = output; process.standardError = progress
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run(); child = process; lock.unlock() }
        catch { lock.unlock(); throw error }
        // Parent-pipe EOF terminates/reaps the helper even if the app exits.
        // Close our copies so readDataToEndOfFile observes helper completion.
        try? output.fileHandleForWriting.close(); try? progress.fileHandleForWriting.close()
        progress.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("progress ") {
                if let value = Double(line.dropFirst(9).dropLast()) {
                    report(ProcessingProgress(stage: .diarizing, fraction: value / 100))
                }
            }
        }
        defer {
            progress.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            lock.lock(); child = nil; lock.unlock()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
        guard process.terminationStatus == 0, !data.isEmpty else { throw LocalInferenceError("The local speaker runtime could not finish. The previous transcript and summary were kept.") }
        return String(decoding: data, as: UTF8.self)
    }
}

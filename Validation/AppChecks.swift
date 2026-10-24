import Foundation
import AVFoundation
import CryptoKit
import Darwin

/// App-layer checks use real media export but no permissions, keys or network.
@main
struct AppChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcriber-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dataRoot = root.appendingPathComponent("Documents/Transcriber", isDirectory: true)
        let settings = AppSettings(storageDirectory: dataRoot)
        try AppStorage.prepare(settings: settings)
        var isDirectory: ObjCBool = false
        precondition(FileManager.default.fileExists(atPath: dataRoot.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        let existing = dataRoot.appendingPathComponent("meetings.json")
        try Data("existing history".utf8).write(to: existing)
        try AppStorage.prepare(settings: settings)
        let preserved = try Data(contentsOf: existing)
        precondition(preserved == Data("existing history".utf8))
        do {
            try AppStorage.prepare(settings: AppSettings(storageDirectory: existing))
            preconditionFailure("A file cannot be used as a data folder")
        } catch {}
        print("✓ Startup creates missing data folders, preserves existing data, and reports creation failures")

        if #available(macOS 14.2, *) {
            for interleaved in [true, false] {
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: interleaved)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
                buffer.frameLength = 128
                let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                for entry in buffers { memset(entry.mData!, 0, Int(entry.mDataByteSize)) }
                precondition(SystemAudioTap.level(buffer) == 0)
                let stride = interleaved ? 2 : 1
                for i in 0..<128 { buffer.floatChannelData![0][i * stride] = 0.25 }
                precondition(abs(SystemAudioTap.level(buffer) - 0.25) < 0.0001)
                for entry in buffers { memset(entry.mData!, 0, Int(entry.mDataByteSize)) }
                for i in 0..<128 {
                    if interleaved { buffer.floatChannelData![0][i * 2 + 1] = 0.25 }
                    else { buffer.floatChannelData![1][i] = 0.25 }
                }
                precondition(abs(SystemAudioTap.level(buffer) - 0.25) < 0.0001, "Right-channel-only audio must verify access")
                // Core Audio lends buffers to the callback. Check the no-copy
                // wrapper preserves frame count and channel layout for writing.
                let borrowed = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: buffer.audioBufferList)!
                precondition(borrowed.frameLength == 128)
                let fileURL = root.appendingPathComponent("tap-\(interleaved).caf")
                var file: AVAudioFile? = try AVAudioFile(forWriting: fileURL, settings: format.settings,
                                                       commonFormat: format.commonFormat, interleaved: interleaved)
                try file!.write(from: borrowed)
                if #available(macOS 15, *) { file!.close() }
                file = nil
                let recorded = try AVAudioFile(forReading: fileURL)
                precondition(recorded.length == 128)
            }
            print("✓ Audio tap buffers preserve frame count, channel layout, signal level, and CAF output")
        }

        // Real 125-second audio must reach recognition in sections of at most
        // 50 seconds, with absolute timestamps and no leftover intermediate file.
        let longAudio = root.appendingPathComponent("long.caf")
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000 * 125)!
            buffer.frameLength = buffer.frameCapacity
            memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
            let output = try AVAudioFile(forWriting: longAudio, settings: format.settings)
            try output.write(from: buffer)
            if #available(macOS 15, *) { output.close() }
        }
        var durations: [Double] = []
        let sections = try await LocalSpeechTranscriber.transcribeSections(file: longAudio) { url in
            let audio = try AVAudioFile(forReading: url)
            durations.append(Double(audio.length) / audio.processingFormat.sampleRate)
            return [TranscriptSegment(speaker: "S1", text: "section", startOffset: 1, endOffset: 2)]
        }
        precondition(durations.count >= 3 && durations.allSatisfy { $0 > 0 && $0 <= 50 })
        precondition(abs(durations.reduce(0, +) - 125) < 0.001, "Every input frame reaches recognition")
        var elapsed = 0.0
        for (section, duration) in zip(sections, durations) {
            precondition(abs(section.startOffset - elapsed - 1) < 0.001)
            precondition(abs(section.endOffset - elapsed - 2) < 0.001)
            elapsed += duration
        }
        let intermediate = root.appendingPathComponent(CapturedAudio.speechSectionFileName)
        precondition(!FileManager.default.fileExists(atPath: intermediate.path))
        for error in [SpeechError("Injected failure") as Error, CancellationError() as Error] {
            do {
                _ = try await LocalSpeechTranscriber.transcribeSections(file: longAudio) { _ in throw error }
                preconditionFailure("Expected section recognition to fail")
            } catch {}
            precondition(!FileManager.default.fileExists(atPath: intermediate.path))
            precondition(FileManager.default.fileExists(atPath: longAudio.path))
        }
        print("✓ Long Speech input covers every section, aligns timestamps and cleans up on success, failure and cancellation")

        let mic = root.appendingPathComponent("mic.wav")
        let system = root.appendingPathComponent("system.wav")
        try tone(to: mic, secondHalf: false)
        try tone(to: system, secondHalf: true)
        let wave = try AVAudioFile(forReading: mic)
        let firstHalf = try WhisperAudio.readSection(wave, seconds: 0.5)
        let secondHalf = try WhisperAudio.readSection(wave, seconds: 0.5)
        precondition(abs(firstHalf.count - 8000) < 32 && abs(secondHalf.count - 8000) < 32)
        precondition(firstHalf.contains { abs($0) > 0.01 })
        precondition(wave.framePosition == wave.length)
        print("✓ Whisper audio conversion reads bounded 16 kHz mono sections without disk intermediates")

        let fixtureWeights = Data("verified-local-model-fixture".utf8)
        let hash = SHA256.hash(data: fixtureWeights).map { String(format: "%02x", $0) }.joined()
        let spec = ModelSpec(id: "fixture-model", displayName: "Fixture", sizeBytes: fixtureWeights.count,
                             url: URL(string: "https://example.invalid/never-requested")!, sha256: hash)
        let fakeDownload = FixtureModelDownloader(data: fixtureWeights)
        let assets = LocalModelAssets(root: root.appendingPathComponent("models"), downloader: fakeDownload)
        let cached = try await assets.ensure(spec)
        _ = try await assets.ensure(spec)
        precondition(fakeDownload.count == 1)
        try Data(repeating: 0, count: fixtureWeights.count).write(to: cached)
        do { try LocalModelAssets.validate(cached, spec: spec); preconditionFailure("A corrupt model must fail integrity validation") } catch {}
        _ = try await assets.ensure(spec)
        precondition(fakeDownload.count == 2)
        try LocalModelAssets.validate(cached, spec: spec)
        print("✓ Pinned local model cache validates SHA256, reuses offline assets and repairs same-size corruption")

        let downloadGate = QueueCheckGate()
        let sharedAssets = LocalModelAssets(root: root.appendingPathComponent("shared-assets"), downloader: WaitingFixtureDownloader(data: fixtureWeights, gate: downloadGate))
        let ownerDownload = Task { try await sharedAssets.ensure(spec) }
        while !(await downloadGate.entered) { await Task.yield() }
        let downloadCancellation = CancellationCheckFlag()
        let joinedDownload = Task {
            do { _ = try await sharedAssets.ensure(spec) }
            catch is CancellationError { await downloadCancellation.mark() }
            catch {}
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        joinedDownload.cancel()
        for _ in 0..<20 {
            if await downloadCancellation.value { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let joinedCancelledPromptly = await downloadCancellation.value
        await downloadGate.release()
        let sharedURL = try await ownerDownload.value
        await joinedDownload.value
        try LocalModelAssets.validate(sharedURL, spec: spec)
        precondition(joinedCancelledPromptly)
        print("✓ Cancelling a shared download waiter returns promptly and preserves the active download")

        let inferenceQueue = LocalInferenceQueue()
        let queueGate = QueueCheckGate()
        let firstJob = Task { try await inferenceQueue.run { await queueGate.hold(); return 1 } }
        while !(await queueGate.entered) { await Task.yield() }
        let cancellationSeen = CancellationCheckFlag()
        let secondJob = Task {
            do { _ = try await inferenceQueue.run { 2 } }
            catch is CancellationError { await cancellationSeen.mark() }
            catch {}
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        secondJob.cancel()
        for _ in 0..<20 {
            if await cancellationSeen.value { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let cancelledWhileQueued = await cancellationSeen.value
        await queueGate.release()
        _ = try await firstJob.value
        await secondJob.value
        let thirdValue = try await inferenceQueue.run { 3 }
        precondition(cancelledWhileQueued && thirdValue == 3)
        print("✓ Local inference serializes models and cancels queued work without waiting for another meeting")

        let fakeRuntime = root.appendingPathComponent("fake-local-runtime")
        try "#!/bin/sh\nprintf '%s' \"$$\" > \"$TMPDIR/fixture-pid\"\nexec /bin/sleep 30\n".write(to: fakeRuntime, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeRuntime.path)
        let ownedServer = try LocalSummaryServer(executable: fakeRuntime, model: root.appendingPathComponent("unused-model"))
        let pidFile = ownedServer.directory.appendingPathComponent("fixture-pid")
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let childPID = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        let stopStarted = Date()
        ownedServer.stop()
        precondition(Date().timeIntervalSince(stopStarted) < 2 && Darwin.kill(childPID, 0) != 0)
        precondition(!FileManager.default.fileExists(atPath: ownedServer.directory.path))
        print("✓ The local model child exits on parent-pipe EOF and its private socket folder is removed")

        for chunked in [false, true] {
            let fixture = try SocketFixture(chunked: chunked)
            defer { fixture.close() }
            let response = try await UnixModelHTTPClient(socket: fixture.path, timeout: 2)
                .send(HTTPRequest(url: URL(string: "http://example.invalid/health")!, method: "GET"))
            precondition(response.statusCode == 200 && String(data: response.body, encoding: .utf8) == "fixture-notes")
            await fixture.worker.value
        }
        let cancelledSocket = try SocketFixture(chunked: false, delay: 0.3)
        let clientTask = Task { try await UnixModelHTTPClient(socket: cancelledSocket.path, timeout: 2)
            .send(HTTPRequest(url: URL(string: "http://example.invalid/health")!, method: "GET")) }
        try await Task.sleep(nanoseconds: 100_000_000)
        clientTask.cancel()
        do { _ = try await clientTask.value; preconditionFailure("The cancelled socket request must not succeed") }
        catch is CancellationError {}
        await cancelledSocket.worker.value
        cancelledSocket.close()
        print("✓ Private model transport handles fixed and chunked responses, cancellation, and never resolves the URL host")

        let mixed = root.appendingPathComponent("mixed.m4a")
        try await AudioPreparation.mix([mic, system], to: mixed)
        let levels = try halfLevels(mixed)
        precondition(levels.0 > 0.05 && levels.1 > 0.05, "Both source tracks must be audible in mixed audio")
        print("✓ Real AVFoundation mix contains microphone and system tracks")

        let observer = AudioObserver()
        let wrapper = PreparingTranscriber(inner: observer)
        _ = try await wrapper.transcribe(audio: CapturedAudio(fileURLs: [.mic: mic, .system: system]), language: "en")
        precondition(observer.sawBothTracks)
        precondition(observer.file.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
        precondition(FileManager.default.fileExists(atPath: mic.path) && FileManager.default.fileExists(atPath: system.path))
        print("✓ Pipeline passes the mixed audio and removes only its derived file")

        observer.shouldFail = true
        do {
            _ = try await wrapper.transcribe(audio: CapturedAudio(fileURLs: [.mic: mic, .system: system]), language: "en")
            preconditionFailure("Expected transcription failure")
        } catch is SpeechError {}
        precondition(observer.file.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
        print("✓ Derived audio is removed when transcription fails")

        observer.shouldFail = false
        _ = try await wrapper.transcribe(audio: CapturedAudio(fileURLs: [.system: system]), language: "en")
        precondition(observer.file == system && FileManager.default.fileExists(atPath: system.path))
        print("✓ A single source passes through without deleting the recording")
        _ = try await PreparingTranscriber(inner: observer, prepareSingleSource: true)
            .transcribe(audio: CapturedAudio(fileURLs: [.system: system]), language: "en")
        precondition(observer.file?.pathExtension == "m4a" && observer.file != system)
        precondition(observer.file.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
        print("✓ Cloud preparation compresses even a single track and removes its derived file")
    }

    static func tone(to url: URL, secondHalf: Bool) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        buffer.frameLength = 44100
        for i in 0..<44100 {
            buffer.floatChannelData![0][i] = ((i >= 22050) == secondHalf)
                ? Float(sin(Double(i) * 2 * .pi * 440 / 44100)) * 0.5 : 0
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        if #available(macOS 15, *) { file.close() }
    }

    static func halfLevels(_ url: URL) throws -> (Double, Double) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        let n = Int(buffer.frameLength)
        var sums = [0.0, 0.0]
        for i in 0..<n { sums[i < n / 2 ? 0 : 1] += Double(samples[i] * samples[i]) }
        return (sqrt(sums[0] / Double(n / 2)), sqrt(sums[1] / Double(n / 2)))
    }
}

private final class AudioObserver: Transcriber, @unchecked Sendable {
    var file: URL?
    var sawBothTracks = false
    var shouldFail = false
    func transcribe(audio: CapturedAudio, language: String) async throws -> [TranscriptSegment] {
        file = audio.mic ?? audio.system
        let levels = try AppChecks.halfLevels(file!)
        sawBothTracks = levels.0 > 0.05 && levels.1 > 0.05
        if shouldFail { throw SpeechError("Expected validation failure") }
        return [TranscriptSegment(speaker: "Speaker 1", text: "Test")]
    }
}

private final class FixtureModelDownloader: ModelDownloader, @unchecked Sendable {
    let data: Data
    private(set) var count = 0
    init(data: Data) { self.data = data }
    func download(spec: ModelSpec, to destination: URL, report: @Sendable (Double) -> Void) async throws {
        count += 1
        try data.write(to: destination)
        report(1)
    }
}

private final class SocketFixture: @unchecked Sendable {
    let root: URL
    let path: URL
    let listener: Int32
    let worker: Task<Void, Never>
    init(chunked: Bool, delay: TimeInterval = 0) throws {
        root = URL(fileURLWithPath: "/private/tmp/transcriber-socket-test-\(UUID().uuidString.prefix(10))")
        path = root.appendingPathComponent("s")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        listener = socketFD
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.path.utf8CString
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { target in
                bytes.withUnsafeBufferPointer { target.update(from: $0.baseAddress!, count: $0.count) }
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        } }
        precondition(bound == 0 && Darwin.listen(listener, 1) == 0)
        let fd = listener
        worker = Task.detached {
            let peer = Darwin.accept(fd, nil, nil)
            guard peer >= 0 else { return }
            defer { Darwin.close(peer) }
            var one: Int32 = 1
            setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
            var buffer = [UInt8](repeating: 0, count: 8192)
            _ = Darwin.read(peer, &buffer, buffer.count)
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let response = chunked
                ? "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n7\r\nfixture\r\n6\r\n-notes\r\n0\r\n\r\n"
                : "HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: close\r\n\r\nfixture-notes"
            _ = response.withCString { Darwin.write(peer, $0, strlen($0)) }
        }
    }
    func close() { Darwin.close(listener); try? FileManager.default.removeItem(at: root) }
}

private actor QueueCheckGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func hold() async { await withCheckedContinuation { continuation = $0; entered = true } }
    func release() { continuation?.resume(); continuation = nil }
}
private actor CancellationCheckFlag {
    private(set) var value = false
    func mark() { value = true }
}

private struct WaitingFixtureDownloader: ModelDownloader {
    let data: Data
    let gate: QueueCheckGate
    func download(spec: ModelSpec, to destination: URL, report: @Sendable (Double) -> Void) async throws {
        await gate.hold()
        try data.write(to: destination)
        report(1)
    }
}

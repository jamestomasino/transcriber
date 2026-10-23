import Foundation
import AVFoundation

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

        let mic = root.appendingPathComponent("mic.wav")
        let system = root.appendingPathComponent("system.wav")
        try tone(to: mic, secondHalf: false)
        try tone(to: system, secondHalf: true)
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

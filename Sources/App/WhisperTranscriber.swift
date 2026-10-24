import Foundation
import AVFoundation
import Darwin
import CWhisper
#if canImport(TranscriberCore)
import TranscriberCore
#endif

struct WhisperTranscriber: Transcriber {
    let modelID: String
    let vocabulary: String
    func transcribe(audio: CapturedAudio, language: String) async throws -> [TranscriptSegment] {
        guard let input = audio.mic ?? audio.system else { throw LocalInferenceError("No recording is available for Whisper.") }
        guard let spec = WhisperCatalog.selectable.first(where: { $0.id == modelID }) else {
            throw LocalInferenceError("Choose a supported Whisper model in Settings.")
        }
        let model = try await LocalModelAssets.shared.ensure(spec)
        let runtime = try await LocalModelAssets.shared.runtime(whisper: true)
        return try await LocalInferenceQueue.shared.run {
            let cancellation = InferenceCancellation()
            return try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try Self.recognize(input: input, model: model, runtime: runtime, language: language, vocabulary: vocabulary, cancellation: cancellation)
                }.value
            } onCancel: { cancellation.cancel() }
        }
    }

    private static func recognize(input: URL, model: URL, runtime: URL, language: String, vocabulary: String, cancellation: InferenceCancellation) throws -> [TranscriptSegment] {
        let api = try WhisperAPI(path: runtime.path)
        api.logSet({ _, _, _ in }, nil)
        try cancellation.check()
        var options = api.contextDefaults()
        options.use_gpu = true
        options.flash_attn = true
        guard let context = model.path.withCString({ api.initialize($0, options) }) else {
            throw LocalInferenceError("Whisper could not load the selected model. Check available memory and download the model again if necessary. Audio was kept.")
        }
        defer { api.free(context) }
        let file = try AVAudioFile(forReading: input)
        let rate = file.processingFormat.sampleRate
        var result: [TranscriptSegment] = []
        while file.framePosition < file.length {
            try cancellation.check()
            let start = file.framePosition
            let offset = Double(start) / rate
            let samples = try WhisperAudio.readSection(file, seconds: 300)
            guard !samples.isEmpty else { break }
            var parameters = api.fullDefaults(WHISPER_SAMPLING_BEAM_SEARCH)
            parameters.n_threads = Int32(min(4, max(2, ProcessInfo.processInfo.activeProcessorCount - 2)))
            parameters.print_special = false; parameters.print_progress = false
            parameters.print_realtime = false; parameters.print_timestamps = false
            parameters.abort_callback = { pointer in
                guard let pointer else { return false }
                return Unmanaged<InferenceCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled
            }
            parameters.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
            let code = language.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? "auto"
            let glossary = String(vocabulary.prefix(1_000))
            let status = code.withCString { locale in
                glossary.withCString { hint in
                    parameters.language = locale
                    parameters.initial_prompt = glossary.isEmpty ? nil : hint
                    parameters.carry_initial_prompt = !glossary.isEmpty
                    return samples.withUnsafeBufferPointer { api.full(context, parameters, $0.baseAddress, Int32($0.count)) }
                }
            }
            try cancellation.check()
            guard status == 0 else { throw LocalInferenceError("Whisper could not finish transcription (code \(status)). Audio was kept; retry or select the faster model.") }
            for index in 0..<api.count(context) {
                guard let text = api.text(context, index) else { continue }
                let segment = TranscriptSegment(speaker: "Speaker 1", text: String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines),
                    startOffset: offset + Double(api.start(context, index)) / 100,
                    endOffset: offset + Double(api.end(context, index)) / 100)
                guard !segment.text.isEmpty else { continue }
                // Overlap protects words at a section boundary. Discard only
                // segments already entirely covered by the preceding section.
                if let previous = result.last, segment.endOffset <= previous.endOffset { continue }
                result.append(segment)
            }
            if file.framePosition >= file.length { break }
            let next = file.framePosition - AVAudioFramePosition(rate * 2)
            guard next > start else { throw LocalInferenceError("Whisper audio preparation made no progress. Original audio was kept.") }
            file.framePosition = next
        }
        return result
    }
}

/// Decode bounded sections directly into memory; never write an unmanaged WAV.
/// Five minutes at 16 kHz occupies ~19 MB, regardless of meeting length.
enum WhisperAudio {
    static func readSection(_ file: AVAudioFile, seconds: Double) throws -> [Float] {
        let inputFormat = file.processingFormat
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 8_192),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16_000) else {
            throw LocalInferenceError("The recorded audio format could not be prepared for Whisper.")
        }
        converter.primeMethod = .none
        let end = min(file.length, file.framePosition + AVAudioFramePosition(inputFormat.sampleRate * seconds))
        var samples: [Float] = []
        var readError: Error?
        while true {
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, state in
                guard file.framePosition < end else { state.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: input, frameCount: AVAudioFrameCount(min(8_192, end - file.framePosition)))
                    guard input.frameLength > 0 else { state.pointee = .endOfStream; return nil }
                    state.pointee = .haveData
                    return input
                } catch { readError = error; state.pointee = .endOfStream; return nil }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            }
            if status == .endOfStream { break }
            if status == .error { throw LocalInferenceError("Audio conversion failed. Original audio was kept.") }
        }
        return samples
    }
}

private final class InferenceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { if isCancelled { throw CancellationError() } }
}

/// The C ABI is pinned to the exact, checksum-verified upstream framework.
/// Only type declarations are compiled; build.sh still uses swiftc alone.
private final class WhisperAPI {
    let handle: UnsafeMutableRawPointer
    let contextDefaults: @convention(c) () -> whisper_context_params
    let fullDefaults: @convention(c) (whisper_sampling_strategy) -> whisper_full_params
    let initialize: @convention(c) (UnsafePointer<CChar>?, whisper_context_params) -> OpaquePointer?
    let free: @convention(c) (OpaquePointer?) -> Void
    let full: @convention(c) (OpaquePointer?, whisper_full_params, UnsafePointer<Float>?, Int32) -> Int32
    let count: @convention(c) (OpaquePointer?) -> Int32
    let text: @convention(c) (OpaquePointer?, Int32) -> UnsafePointer<CChar>?
    let start: @convention(c) (OpaquePointer?, Int32) -> Int64
    let end: @convention(c) (OpaquePointer?, Int32) -> Int64
    let logSet: @convention(c) (ggml_log_callback?, UnsafeMutableRawPointer?) -> Void
    init(path: String) throws {
        guard let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw LocalInferenceError("The verified Whisper runtime could not be loaded. Re-download the runtime in Settings.")
        }
        handle = library
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let pointer = dlsym(library, name) else { throw LocalInferenceError("The Whisper runtime ABI did not match. Re-download the runtime.") }
            return unsafeBitCast(pointer, to: type)
        }
        contextDefaults = try symbol("whisper_context_default_params", (@convention(c) () -> whisper_context_params).self)
        fullDefaults = try symbol("whisper_full_default_params", (@convention(c) (whisper_sampling_strategy) -> whisper_full_params).self)
        initialize = try symbol("whisper_init_from_file_with_params", (@convention(c) (UnsafePointer<CChar>?, whisper_context_params) -> OpaquePointer?).self)
        free = try symbol("whisper_free", (@convention(c) (OpaquePointer?) -> Void).self)
        full = try symbol("whisper_full", (@convention(c) (OpaquePointer?, whisper_full_params, UnsafePointer<Float>?, Int32) -> Int32).self)
        count = try symbol("whisper_full_n_segments", (@convention(c) (OpaquePointer?) -> Int32).self)
        text = try symbol("whisper_full_get_segment_text", (@convention(c) (OpaquePointer?, Int32) -> UnsafePointer<CChar>?).self)
        start = try symbol("whisper_full_get_segment_t0", (@convention(c) (OpaquePointer?, Int32) -> Int64).self)
        end = try symbol("whisper_full_get_segment_t1", (@convention(c) (OpaquePointer?, Int32) -> Int64).self)
        logSet = try symbol("whisper_log_set", (@convention(c) (ggml_log_callback?, UnsafeMutableRawPointer?) -> Void).self)
        // Keep code mapped for process lifetime; ggml registers global backends.
        // Context weights are freed after each operation, before a summary loads.
    }
}

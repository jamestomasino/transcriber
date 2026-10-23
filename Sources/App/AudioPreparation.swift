import Foundation
import AVFoundation

#if canImport(TranscriberCore)
import TranscriberCore
#endif

/// Mix both tracks before transcription. The export streams through AVFoundation
/// rather than loading an hours-long meeting into memory. Derived audio stays
/// inside the meeting's managed recording directory and is removed on every exit.
struct PreparingTranscriber: Transcriber {
    let inner: any Transcriber
    var prepareSingleSource = false

    func transcribe(audio: CapturedAudio, language: String) async throws -> [TranscriptSegment] {
        let files = [AudioSource.mic, .system].compactMap { audio.fileURLs[$0] }
        guard files.count > 1 || (prepareSingleSource && !files.isEmpty) else {
            return try await inner.transcribe(audio: audio, language: language)
        }
        let output = files[0].deletingLastPathComponent()
            .appendingPathComponent(CapturedAudio.preparedFileName)
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        defer { try? FileManager.default.removeItem(at: output) }
        let offsets = Dictionary(audio.fileURLs.map { ($0.value, audio.startOffsets[$0.key] ?? 0) }, uniquingKeysWith: { min($0, $1) })
        try await AudioPreparation.mix(files, to: output, offsets: files.count > 1 ? offsets : [:])
        let segments = try await inner.transcribe(audio: CapturedAudio(fileURLs: [.mic: output]), language: language)
        try FileManager.default.removeItem(at: output)
        return segments
    }
}

enum AudioPreparation {
    static func mix(_ files: [URL], to output: URL, offsets: [URL: TimeInterval] = [:]) async throws {
        let composition = AVMutableComposition()
        var parameters: [AVAudioMixInputParameters] = []
        for file in files {
            let asset = AVURLAsset(url: file)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw SpeechError("A recorded audio track could not be read. The original files were kept.")
            }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: CMTime(seconds: max(0, offsets[file] ?? 0), preferredTimescale: 48000))
            let input = AVMutableAudioMixInputParameters(track: track)
            input.setVolume(1 / Float(files.count), at: .zero)
            parameters.append(input)
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw SpeechError("Audio mixing is unavailable on this Mac.")
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        exporter.audioMix = mix
        exporter.outputFileType = .m4a
        exporter.outputURL = output
        try Task.checkCancellation()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                exporter.exportAsynchronously { continuation.resume() }
            }
        } onCancel: { exporter.cancelExport() }
        try Task.checkCancellation()
        guard exporter.status == .completed else {
            throw exporter.error ?? SpeechError("Audio mixing failed. The original files were kept.")
        }
    }
}

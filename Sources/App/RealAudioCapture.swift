import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreAudio

#if canImport(TranscriberCore)
import TranscriberCore
#endif

// MARK: - App-layer audio capture
//
// Concrete implementation of the Core `AudioCapture` contract. This is the
// only place in the app that touches AVFoundation, ScreenCaptureKit, or
// CoreMedia. It records the **mic** and **system audio** as two separate
// files (the most robust MVP strategy — no real-time mixing) and reports
// live levels for the UI meter.
//
// Every API used here was verified against the installed macOS SDK before
// being written (see PLAN.md §7):
//   - Mic: `AVAudioEngine` input node tap → `AVAudioFile` (CAF).
//   - System audio: `SCStream` + `capturesAudio`, delegate
//     `stream(_:didOutputSampleBuffer:ofType:)`, buffer converted via
//     `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer`.
//   - Mic permission: `AVAudioApplication.shared.recordPermission` /
//     `AVAudioApplication.requestRecordPermission(_:)` (macOS; `AVAudioSession`
//     is iOS-only and unavailable here).
//   - Screen Recording: TCC-only, no Info.plist usage string required.

// MARK: - AVAudioCapture

/// AVFoundation + ScreenCaptureKit capture. One instance per app; it runs one
/// session at a time (the app only ever records one meeting).
final class AVAudioCapture: AudioCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: [AudioSource: AudioCaptureError] = [:]
    private var _levels: [AudioSource: Float] = [:]
    private var _session: AVCaptureSession?

    var status: [AudioSource: AudioCaptureError] {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    func level(_ source: AudioSource) -> Float {
        lock.lock(); defer { lock.unlock() }
        return _levels[source] ?? 0
    }

    private func setLevel(_ source: AudioSource, _ v: Float) {
        lock.lock(); _levels[source] = v; lock.unlock()
    }

    private func setStatus(_ source: AudioSource, _ e: AudioCaptureError?) {
        lock.lock()
        if let e { _status[source] = e } else { _status[source] = nil }
        lock.unlock()
    }

    func start(sources: Set<AudioSource>, directory: URL) async throws -> AudioCaptureSession {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lock.lock(); _status = [:]; _levels = [:]; lock.unlock()

        // The session reports live levels back to us via this sink.
        let session = AVCaptureSession(directory: directory, levelSink: { [weak self] source, v in
            self?.setLevel(source, v)
        })

        var startedAny = false

        if sources.contains(.mic) {
            do {
                try await session.startMic()
                startedAny = true
            } catch {
                setStatus(.mic, Self.error(for: .mic, error))
            }
        }
        if sources.contains(.system) {
            do {
                try await session.startSystemAudio()
                startedAny = true
            } catch {
                setStatus(.system, Self.error(for: .system, error))
            }
        }

        guard startedAny else {
            throw AudioCaptureError.sourceFailed(
                source: sources.first ?? .mic,
                detail: "No audio source could be started (check microphone / Screen Recording permissions).")
        }

        lock.lock(); _session = session; lock.unlock()
        return session
    }

    /// Map an arbitrary error to a typed `AudioCaptureError` the UI can act on.
    private static func error(for source: AudioSource, _ error: Error) -> AudioCaptureError {
        if let ae = error as? AudioCaptureError { return ae }
        let code = (error as NSError).code
        switch source {
        case .mic:
            // 212 = kAudioUnitErr_PermissionDenied (mic TCC).
            if code == 212 { return .microphoneNotAuthorized }
            return .sourceFailed(source: .mic, detail: (error as NSError).localizedDescription)
        case .system:
            if code == 4 || code == 212 || code == 23 { return .screenRecordingNotAuthorized }
            return .sourceFailed(source: .system, detail: (error as NSError).localizedDescription)
        }
    }
}

// MARK: - Session

/// A running capture: an optional mic engine and an optional SCStream.
final class AVCaptureSession: AudioCaptureSession, @unchecked Sendable {
    private let directory: URL
    private let levelSink: (AudioSource, Float) -> Void
    private let lock = NSLock()

    // Mic.
    private var micEngine: AVAudioEngine?
    private var micFile: AVAudioFile?
    private var micStarted = false

    // System audio.
    private var scStream: SCStream?
    private var scDelegate: SystemAudioDelegate?
    private var sysFile: AVAudioFile?
    private var sysStarted = false

    init(directory: URL, levelSink: @escaping (AudioSource, Float) -> Void) {
        self.directory = directory
        self.levelSink = levelSink
    }

    // MARK: Mic

    func startMic() async throws {
        // Permission (macOS).
        var perm = AVAudioApplication.shared.recordPermission
        if perm == .undetermined {
            let granted = await withCheckedContinuation { cont in
                AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
            }
            perm = granted ? .granted : .denied
        }
        guard perm == .granted else { throw AudioCaptureError.microphoneNotAuthorized }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.sourceFailed(source: .mic, detail: "No input device / invalid format.")
        }

        let url = directory.appendingPathComponent("mic.caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)

        let sink = levelSink
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            do { try file.write(from: buffer) } catch { /* keep recording */ }
            sink(.mic, Self.rms(of: buffer))
        }

        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }

        lock.lock()
        micEngine = engine
        micFile = file
        micStarted = true
        lock.unlock()
    }

    // MARK: System audio

    func startSystemAudio() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayAvailable
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        if #available(macOS 15.0, *) { config.captureMicrophone = false }
        config.sampleRate = 48000
        config.channelCount = 2
        config.showsCursor = false
        config.width = 1
        config.height = 1

        let url = directory.appendingPathComponent("system.caf")
        // SC delivers float32 deinterleaved PCM; write it as such.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)

        let sink = levelSink
        let delegate = SystemAudioDelegate(file: file) { v in sink(.system, v) }
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                stream.startCapture { err in
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                }
            }
        } catch {
            let code = (error as NSError).code
            if code == 4 || code == 212 || code == 23 {
                throw AudioCaptureError.screenRecordingNotAuthorized
            }
            throw error
        }

        lock.lock()
        scStream = stream
        scDelegate = delegate
        sysFile = file
        sysStarted = true
        lock.unlock()
    }

    // MARK: Stop

    func stop() async throws -> CapturedAudio {
        lock.lock()
        let mic = micStarted
        let sys = sysStarted
        micStarted = false
        sysStarted = false
        lock.unlock()

        var urls: [AudioSource: URL] = [:]

        if mic {
            micEngine?.inputNode.removeTap(onBus: 0)
            micEngine?.stop()
            micEngine = nil
            if let f = micFile {
                Self.closeAudioFile(f)
                if FileManager.default.fileExists(atPath: f.url.path) { urls[.mic] = f.url }
            }
            micFile = nil
        }

        if sys {
            if let s = scStream {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    s.stopCapture { _ in cont.resume() }
                }
            }
            scStream = nil
            scDelegate = nil
            if let f = sysFile {
                Self.closeAudioFile(f)
                if FileManager.default.fileExists(atPath: f.url.path) { urls[.system] = f.url }
            }
            sysFile = nil
        }

        return CapturedAudio(fileURLs: urls)
    }

    /// `AVAudioFile.close()` is macOS 15+; on earlier systems ARC releases the
    /// file and flushes on deinit, so we guard the call.
    private static func closeAudioFile(_ file: AVAudioFile) {
        if #available(macOS 15.0, *) {
            try? file.close()
        }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        let n = Int(buffer.frameLength)
        let s = ch[0]
        for i in 0..<n { sum += s[i] * s[i] }
        return min(1.0, (sum / Float(n)).squareRoot())
    }
}

// MARK: - System audio delegate (SCStream)

/// Receives SCStream audio sample buffers and writes them to an `AVAudioFile`.
/// SC delivers `CMSampleBuffer`s of float32 PCM; we convert to
/// `AVAudioPCMBuffer` and write.
final class SystemAudioDelegate: NSObject, SCStreamDelegate {
    private let file: AVAudioFile
    private let levelSink: (Float) -> Void

    init(file: AVAudioFile, levelSink: @escaping (Float) -> Void) {
        self.file = file
        self.levelSink = levelSink
    }

    func stream(_ stream: SCStream, didOutput sampleBuffer: CMSampleBuffer, ofType type: SCStreamOutputType) {
        guard type == .audio else { return }

        // 1) Size the AudioBufferList.
        var ablSizeNeeded = 0
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &ablSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == noErr, ablSizeNeeded > 0 else { return }

        // 2) Allocate and fill the AudioBufferList.
        let ablBytes = UnsafeMutableRawPointer.allocate(byteCount: ablSizeNeeded, alignment: 16)
        defer { ablBytes.deallocate() }
        let ablRaw = UnsafeMutablePointer<AudioBufferList>(OpaquePointer(ablBytes))
        let status2 = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablRaw,
            bufferListSize: ablSizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status2 == noErr else { return }
        let abl = UnsafeMutableAudioBufferListPointer(ablRaw)

        // 3) Format.
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)?.pointee else { return }
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bytesPerSample = isFloat ? 4 : 2
        let frames = Int(abl[0].mDataByteSize) / bytesPerSample
        let common: AVAudioCommonFormat = isFloat ? .pcmFormatFloat32 : .pcmFormatInt16
        guard let fmt = AVAudioFormat(commonFormat: common,
                                      sampleRate: asbd.mSampleRate,
                                      channels: AVAudioChannelCount(asbd.mChannelsPerFrame),
                                      interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)

        // 4) Copy.
        if let fd = buf.floatChannelData {
            for i in 0..<abl.count {
                if let src = abl[i].mData {
                    fd[i].update(from: src.assumingMemoryBound(to: Float.self), count: frames)
                }
            }
        }

        do { try file.write(from: buf) } catch { /* keep going */ }
        levelSink(Self.rms(of: buf))
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        let n = Int(buffer.frameLength)
        let s = ch[0]
        for i in 0..<n { sum += s[i] * s[i] }
        return min(1.0, (sum / Float(n)).squareRoot())
    }
}

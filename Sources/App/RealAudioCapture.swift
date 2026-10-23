import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreAudio
import AudioToolbox

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
//   - System audio: Core Audio process tap on macOS 14.2+, otherwise
//     `SCStream` + `capturesAudio`, delegate
//     `stream(_:didOutputSampleBuffer:ofType:)`, buffer converted via
//     `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer`.
//   - Mic permission: `AVAudioApplication.shared.recordPermission` /
//     `AVAudioApplication.requestRecordPermission(_:)` (macOS; `AVAudioSession`
//     is iOS-only and unavailable here).
//   - Audio taps use NSAudioCaptureUsageDescription; the legacy stream uses screen access.

// MARK: - AVAudioCapture

/// AVFoundation + Core Audio capture (ScreenCaptureKit on macOS 14.0–14.1). One instance per app; it runs one
/// session at a time (the app only ever records one meeting).
final class AVAudioCapture: AudioCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: [AudioSource: AudioCaptureError] = [:]
    private var _levels: [AudioSource: Float] = [:]
    private var _session: AVCaptureSession?
    private let inputDeviceUID: () -> String?

    init(inputDeviceUID: @escaping () -> String? = { nil }) {
        self.inputDeviceUID = inputDeviceUID
    }

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
        let session = AVCaptureSession(directory: directory, errorSink: { [weak self] source, error in
            self?.setStatus(source, error)
        }, levelSink: { [weak self] source, v in
            self?.setLevel(source, v)
        })

        var startedAny = false

        if sources.contains(.mic) {
            do {
                try await session.startMic(deviceUID: inputDeviceUID())
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
                detail: "No audio source could be started (check microphone / system audio permissions).")
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

/// A running capture: an optional mic engine and a system audio tap or legacy SCStream.
final class AVCaptureSession: AudioCaptureSession, @unchecked Sendable {
    private let directory: URL
    private let levelSink: (AudioSource, Float) -> Void
    private let errorSink: (AudioSource, AudioCaptureError) -> Void
    private let startedAt = Date()
    private var startOffsets: [AudioSource: TimeInterval] = [:]
    private let lock = NSLock()

    // Mic.
    private var micEngine: AVAudioEngine?
    private var micFile: AVAudioFile?
    private var micStarted = false

    // System audio.
    private var audioTap: AnyObject? // SystemAudioTap on macOS 14.2+
    private var scStream: SCStream?
    private var scDelegate: SystemAudioDelegate?
    private var sysFile: AVAudioFile?
    private var sysStarted = false
    private let systemQueue = DispatchQueue(label: "Transcriber.systemAudio")

    init(directory: URL, errorSink: @escaping (AudioSource, AudioCaptureError) -> Void, levelSink: @escaping (AudioSource, Float) -> Void) {
        self.directory = directory
        self.errorSink = errorSink
        self.levelSink = levelSink
    }

    // MARK: Mic

    func startMic(deviceUID: String?) async throws {
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
        if let deviceUID {
            guard let device = AudioDevices.inputs().first(where: { $0.id == deviceUID }),
                  let unit = input.audioUnit else {
                throw AudioCaptureError.sourceFailed(source: .mic, detail: "The selected microphone is disconnected. Choose another input in Settings.")
            }
            var id = device.audioID
            guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &id,
                                       UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
                throw AudioCaptureError.sourceFailed(source: .mic, detail: "Could not select the microphone. Choose another input in Settings.")
            }
        }
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
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        var started = false
        defer {
            if !started {
                Self.closeAudioFile(file)
                try? FileManager.default.removeItem(at: url)
            }
        }

        let sink = levelSink
        let failure = errorSink
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            do { try file.write(from: buffer) } catch { failure(.mic, .sourceFailed(source: .mic, detail: error.localizedDescription)) }
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
        startOffsets[.mic] = Date().timeIntervalSince(startedAt)
        lock.unlock()
        started = true
    }

    // MARK: System audio

    func startSystemAudio() async throws {
        if #available(macOS 14.2, *) {
            try startAudioTap()
            return
        }
        // Compatibility path for macOS 14.0–14.1 only.
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
        config.excludesCurrentProcessAudio = true
        config.showsCursor = false
        config.width = 2
        config.height = 2

        let url = directory.appendingPathComponent("system.caf")
        // SC delivers float32 deinterleaved PCM; write it as such.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        var started = false
        defer {
            if !started {
                Self.closeAudioFile(file)
                try? FileManager.default.removeItem(at: url)
            }
        }

        let sink = levelSink
        let failure = errorSink
        let delegate = SystemAudioDelegate(file: file, errorSink: { error in
            failure(.system, .sourceFailed(source: .system, detail: error.localizedDescription))
        }, levelSink: { v in sink(.system, v) })
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try stream.addStreamOutput(delegate, type: .audio,
                                   sampleHandlerQueue: systemQueue)

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
        startOffsets[.system] = Date().timeIntervalSince(startedAt)
        lock.unlock()
        started = true
    }

    @available(macOS 14.2, *)
    private func startAudioTap() throws {
        let tap = try SystemAudioTap()
        let url = directory.appendingPathComponent("system.caf")
        var file: AVAudioFile?
        do {
            let output = try AVAudioFile(forWriting: url, settings: tap.format.settings,
                                         commonFormat: tap.format.commonFormat, interleaved: tap.format.isInterleaved)
            file = output
            let failure = errorSink
            let levels = levelSink
            try tap.start { buffer in
                do { try output.write(from: buffer) }
                catch { failure(.system, .sourceFailed(source: .system, detail: error.localizedDescription)) }
                levels(.system, SystemAudioTap.level(buffer))
            }
            lock.lock()
            audioTap = tap
            sysFile = output
            sysStarted = true
            startOffsets[.system] = Date().timeIntervalSince(startedAt)
            lock.unlock()
        } catch {
            tap.stop()
            if let file { Self.closeAudioFile(file) }
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    var audio: CapturedAudio {
        lock.lock(); defer { lock.unlock() }
        var files: [AudioSource: URL] = [:]
        if micStarted { files[.mic] = directory.appendingPathComponent("mic.caf") }
        if sysStarted { files[.system] = directory.appendingPathComponent("system.caf") }
        return CapturedAudio(fileURLs: files, startOffsets: startOffsets)
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
            if #available(macOS 14.2, *), let tap = audioTap as? SystemAudioTap { tap.stop() }
            audioTap = nil
            if let s = scStream {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    s.stopCapture { _ in cont.resume() }
                }
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                systemQueue.async { continuation.resume() }
            }
            scStream = nil
            scDelegate = nil
            if let f = sysFile {
                Self.closeAudioFile(f)
                if FileManager.default.fileExists(atPath: f.url.path) { urls[.system] = f.url }
            }
            sysFile = nil
        }

        return CapturedAudio(fileURLs: urls, startOffsets: startOffsets)
    }

    /// `AVAudioFile.close()` is macOS 15+; on earlier systems ARC releases the
    /// file and flushes on deinit, so we guard the call.
    private static func closeAudioFile(_ file: AVAudioFile) {
        if #available(macOS 15.0, *) {
            file.close()
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
final class SystemAudioDelegate: NSObject, SCStreamDelegate, SCStreamOutput {
    private let file: AVAudioFile
    private let levelSink: (Float) -> Void
    private let errorSink: (Error) -> Void

    init(file: AVAudioFile, errorSink: @escaping (Error) -> Void, levelSink: @escaping (Float) -> Void) {
        self.file = file
        self.errorSink = errorSink
        self.levelSink = levelSink
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return }
        var asbd = streamDescription.pointee
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, frames <= Int(Int32.max),
              let format = AVAudioFormat(streamDescription: &asbd),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                           into: buf.mutableAudioBufferList) == noErr else { return }

        do { try file.write(from: buf) } catch { errorSink(error) }
        levelSink(Self.rms(of: buf))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { errorSink(error) }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        let n = Int(buffer.frameLength)
        let s = ch[0]
        for i in 0..<n { sum += s[i] * s[i] }
        return min(1.0, (sum / Float(n)).squareRoot())
    }
}

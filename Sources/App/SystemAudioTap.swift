import Foundation
import AVFoundation
import CoreAudio

/// Audio-only capture: no display enumeration and no screen recording access.
/// The owner stops I/O before releasing the callback's file or other resources.
@available(macOS 14.2, *)
final class SystemAudioTap {
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "Transcriber.audioTap")
    let format: AVAudioFormat

    init() throws {
        // Exclude our playback, without muting audio heard by the user.
        var pid = getpid()
        var process: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let translated = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                    UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: translated == noErr && process != 0 ? [process] : [])
        description.name = "Transcriber system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var newTap: AudioObjectID = 0
        try Self.check(AudioHardwareCreateProcessTap(description, &newTap), "Create audio tap")
        tap = newTap
        do {
            var asbd = AudioStreamBasicDescription()
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            address.mSelector = kAudioTapPropertyFormat
            try Self.check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd), "Read audio tap format")
            guard let audioFormat = AVAudioFormat(streamDescription: &asbd), asbd.mBytesPerFrame > 0 else {
                throw TapError(operation: "Unsupported audio tap format", status: kAudioHardwareUnsupportedOperationError)
            }
            format = audioFormat
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Transcriber system audio",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "Create audio tap device")
        } catch {
            if device != 0 { AudioHardwareDestroyAggregateDevice(device) }
            AudioHardwareDestroyProcessTap(tap)
            throw error
        }
    }

    /// Buffers are borrowed and must be consumed before the callback returns.
    func start(receive: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let format = self.format
        try Self.check(AudioDeviceCreateIOProcIDWithBlock(&io, device, queue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, first.mData != nil else { return }
            let frames = first.mDataByteSize / format.streamDescription.pointee.mBytesPerFrame
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input) else { return }
            buffer.frameLength = frames
            receive(buffer)
        }, "Install audio tap callback")
        try Self.check(AudioDeviceStart(device, io), "Start system audio capture")
    }

    func stop() {
        if let io {
            AudioDeviceStop(device, io)
            AudioDeviceDestroyIOProcID(device, io)
            self.io = nil
            queue.sync {} // Drain callbacks before closing a recording file.
        }
        if device != 0 { AudioHardwareDestroyAggregateDevice(device); device = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }

    deinit { stop() }

    /// There is no public audio-tap permission preflight. Successful creation
    /// alone does not prove access: a denied tap can deliver zeroed buffers.
    /// Verify actual samples, without saving audio or treating silence as denial.
    static func checkAccess() async throws -> Bool {
        let tap = try SystemAudioTap()
        defer { tap.stop() }
        let signal = Signal()
        try tap.start { signal.observe($0) }
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if signal.heardAudio { return true }
        }
        return false
    }

    static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let channels = Int(buffer.format.channelCount)
        var peak: Float = 0
        for channel in 0..<channels {
            var sum: Float = 0
            for frame in 0..<Int(buffer.frameLength) {
                let value = buffer.format.isInterleaved ? samples[0][frame * channels + channel] : samples[channel][frame]
                sum += value * value
            }
            peak = max(peak, (sum / Float(buffer.frameLength)).squareRoot())
        }
        return min(1, peak)
    }

    private final class Signal: @unchecked Sendable {
        private let lock = NSLock()
        private var heard = false
        var heardAudio: Bool { lock.lock(); defer { lock.unlock() }; return heard }
        func observe(_ buffer: AVAudioPCMBuffer) {
            if SystemAudioTap.level(buffer) > 0.00001 { lock.lock(); heard = true; lock.unlock() }
        }
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw TapError(operation: operation, status: status) }
    }

    struct TapError: LocalizedError {
        let operation: String
        let status: OSStatus
        var errorDescription: String? { "\(operation) failed (Core Audio \(status)). Check System Audio Recording access in System Settings, then quit and reopen Transcriber if requested." }
    }
}

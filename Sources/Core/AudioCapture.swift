import Foundation

// MARK: - Audio capture (Core contract)
//
// This is the seam between the pure Core and the App-layer AVFoundation /
// ScreenCaptureKit implementation (see `Sources/App/AudioCapture.swift`).
// Core imports nothing but Foundation here, so the view model can drive a
// recording and be tested headless against a fake that writes a tiny valid
// audio file — the same seam the base repo uses for its processors.
//
// The design records the **mic** and **system audio** as **two separate
// files** during capture (most robust: no real-time mixing bugs) and hands
// back their URLs. Mixing to a single mono stream for ASR is a *pipeline*
// concern (Phase 3), not a capture concern.

/// The result of a capture session: the on-disk file(s) produced, keyed by
/// source. A source is absent if it was not requested or failed to start.
public struct CapturedAudio: Equatable, Sendable {
    public static let preparedFileName = "mixed.m4a"
    public static let speechSectionFileName = "speech-section.caf"
    public static let speakerAudioFileName = "speaker-analysis.wav"
    /// File URLs per source that actually captured something.
    public var fileURLs: [AudioSource: URL]
    public var startOffsets: [AudioSource: TimeInterval]

    public init(fileURLs: [AudioSource: URL] = [:], startOffsets: [AudioSource: TimeInterval] = [:]) {
        self.fileURLs = fileURLs
        self.startOffsets = startOffsets
    }

    /// The microphone file, if captured.
    public var mic: URL? { fileURLs[.mic] }
    /// The system-audio file, if captured.
    public var system: URL? { fileURLs[.system] }

    /// True if at least one source produced a file.
    public var isEmpty: Bool { fileURLs.isEmpty }
}

/// A capture session in flight.
///
/// `start` opens the requested sources and begins writing; `stop` tears them
/// down and returns the final file URLs. Implementations are expected to be
/// resilient: a source that fails to start (e.g. Screen Recording not yet
/// granted) is skipped and surfaced via `AudioCaptureError`, rather than
/// failing the whole session, so the meeting still records what it can.
public protocol AudioCapture: Sendable {
    /// Begin capturing the given sources into `directory`.
    /// Returns the in-flight session (call `stop` to finish).
    ///
    /// Resilient: a source that fails to start (e.g. Screen Recording not
    /// yet granted) is skipped and reported via `status`, not thrown — so the
    /// meeting still records what it can. Only if *every* requested source
    /// fails does `start` throw.
    func start(sources: Set<AudioSource>, directory: URL) async throws -> AudioCaptureSession
    /// Current live level (RMS, 0…1) for a source, for the UI meter.
    func level(_ source: AudioSource) -> Float
    /// Per-source start errors (e.g. permission denied), if any.
    var status: [AudioSource: AudioCaptureError] { get }
}

// MARK: - Directory for a meeting's recordings
//
// Foundation-only, so the view model (Core) and the test harness can compute
// the canonical location without touching the App layer.

/// Where raw audio lives: `…/Transcriber/recordings/yyyyMMdd-HHmm-<id>/`.
///
/// `baseDirectory` is injectable so tests can point it at a temp dir without
/// touching the user's real Application Support.
public enum RecordingsDirectory {
    public static var baseDirectory: (() -> URL)?

    public static func base() -> URL {
        if let override = baseDirectory { return override() }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("Transcriber", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
    }

    public static func forMeeting(_ meeting: Meeting, timeZone: TimeZone = .current) -> URL {
        base().appendingPathComponent(fileStem(for: meeting, timeZone: timeZone), isDirectory: true)
    }

    public static func fileStem(for meeting: Meeting, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let prefix = formatter.string(from: meeting.startedAt)
        return "\(prefix)-\(meeting.id.uuidString)"
    }

    /// Recognize only our dated names and the original UUID-only names.
    static func meetingID(inDirectoryName name: String) -> UUID? {
        if let legacy = UUID(uuidString: name) { return legacy }
        guard name.count == 50,
              name.range(of: #"^[0-9]{8}-[0-9]{4}-"#, options: .regularExpression) != nil
        else { return nil }
        return UUID(uuidString: String(name.dropFirst(14)))
    }

    /// The per-meeting directories that are safe to delete at startup.
    ///
    /// Pure (Foundation-only): it *decides* which directories to remove and
    /// returns their URLs; the caller performs the `FileManager.remove` side
    /// effect. This is the same posture as `RetentionPolicy` — the product's
    /// "keep only the summary" promise made testable without I/O.
    ///
    /// A directory is an orphan when:
    /// - its name matches our dated or legacy UUID format, and
    /// - it is not a *live* meeting's directory (`liveIDs`), OR it is a live
    ///   meeting's directory but is already **empty** (a leftover from a build
    ///   that summarized the meeting but never cleaned the dir up).
    ///
    /// A live, non-empty directory is always kept: it may hold audio the user
    /// still needs to retry a failed meeting, so the sweep never deletes it.
    public static func orphanDirectories(liveIDs: Set<UUID>, base: URL? = nil) -> [URL] {
        let b = base ?? Self.base()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: b, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var orphans: [URL] = []
        for entry in entries {
            guard let isDir = try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  isDir,
                  let uuid = meetingID(inDirectoryName: entry.lastPathComponent)
            else { continue }

            if !liveIDs.contains(uuid) {
                orphans.append(entry)
            } else if let contents = try? FileManager.default.contentsOfDirectory(
                at: entry, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ), contents.isEmpty {
                orphans.append(entry)
            }
        }
        return orphans
    }
}

/// A running capture session.
public protocol AudioCaptureSession: Sendable {
    /// File references persisted while recording, so a crash remains retryable.
    var audio: CapturedAudio { get }
    /// Stop capturing and finalize the files.
    func stop() async throws -> CapturedAudio
}

public extension AudioCaptureSession {
    var audio: CapturedAudio { CapturedAudio() }
}

// MARK: - Storage directory (Core, pure)
//
// Resolves the base directory for Transcriber *data* (meetings.json +
// recordings/ + summaries/ + transcripts/) from the user's settings. Pure: it only reads the settings
// value and applies the default — no I/O, no side effects.
//
// Design note: `settings.json` itself always lives in Application Support
// (the app must be able to find it on launch without knowing the custom path
// yet). The `storageDirectory` setting controls where the *data* — meetings
// and recordings — is stored, which is what the DoD's "summary save location"
// preference is about.
//
// New settings → ~/Documents/Transcriber/
// `storageDirectory == nil` (legacy default) → ~/Library/Application Support/Transcriber/
// `storageDirectory == /path/to/dir` → that directory is the Transcriber data root.

public enum StorageDirectory {
    /// New installations keep their data together inside Documents.
    public static var defaultDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        return documents.appendingPathComponent("Transcriber", isDirectory: true)
    }

    /// The Transcriber data root for the given settings.
    public static func base(settings: AppSettings) -> URL {
        if let custom = settings.storageDirectory {
            return custom
        }
        // A nil location in existing settings means the original default.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("Transcriber", isDirectory: true)
    }

    /// `meetings.json` inside the resolved data root.
    public static func meetingsURL(settings: AppSettings) -> URL {
        base(settings: settings).appendingPathComponent("meetings.json")
    }

    /// The recordings directory inside the resolved data root.
    public static func recordingsURL(settings: AppSettings) -> URL {
        base(settings: settings).appendingPathComponent("recordings", isDirectory: true)
    }
}

/// Error types surfaced by capture, so the UI can show actionable messages
/// instead of a generic failure.
public enum AudioCaptureError: Error, Equatable, Sendable {
    /// The microphone is not authorized (TCC `kTCCServiceMicrophone`).
    case microphoneNotAuthorized
    /// Screen Recording is not authorized (TCC `kTCCServiceScreenCapture`).
    case screenRecordingNotAuthorized
    /// No display was available to capture system audio from.
    case noDisplayAvailable
    /// The requested source could not be started for another reason.
    case sourceFailed(source: AudioSource, detail: String)
}

extension AudioCaptureError {
    /// A human-readable, actionable description for the UI. Told to the user
    /// verbatim, so it names the setting to flip and where to find it.
    public var description: String {
        switch self {
        case .microphoneNotAuthorized:
            return "Microphone access is off, so your voice isn't captured. Enable it in System Settings → Privacy & Security → Microphone, then start again."
        case .screenRecordingNotAuthorized:
            return "Screen Recording is off, so system audio (Zoom / Slack / Teams) isn't captured. Enable it in System Settings → Privacy & Security → Screen Recording, then start again."
        case .noDisplayAvailable:
            return "No display was available to capture system audio from."
        case .sourceFailed(let source, let detail):
            let name = source == .mic ? "Microphone" : "System audio"
            return "\(name) could not be started: \(detail)"
        }
    }
}

// MARK: - Core test fake
//
// A trivial capture implementation for tests and for the "no real audio"
// path: it writes a small, valid, silent **WAV** file for each requested
// source so downstream pipeline code can be exercised headless.
//
// Deliberately in Core (Foundation-only) so the test harness — which links
// only Core, not the App's AVFoundation code — can use it. `AVAudioFile`
// reads the WAV back as 16-bit mono PCM (verified against the SDK).

public final class RecordingAudioCapture: AudioCapture, @unchecked Sendable {
    private let directory: URL
    private var startedSources: Set<AudioSource> = []
    private var _status: [AudioSource: AudioCaptureError] = [:]
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    public var status: [AudioSource: AudioCaptureError] {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    public func start(sources: Set<AudioSource>, directory: URL) async throws -> AudioCaptureSession {
        lock.lock()
        self.startedSources = sources
        lock.unlock()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return RecordingSession(directory: directory, sources: sources)
    }

    public func level(_ source: AudioSource) -> Float {
        lock.lock()
        defer { lock.unlock() }
        return startedSources.contains(source) ? 0.0 : 0.0
    }
}

private final class RecordingSession: AudioCaptureSession, @unchecked Sendable {
    private let directory: URL
    private let sources: Set<AudioSource>
    private var stopped = false

    init(directory: URL, sources: Set<AudioSource>) {
        self.directory = directory
        self.sources = sources
    }

    public func stop() async throws -> CapturedAudio {
        // Test fake: no real concurrency, so no lock (NSLock is unavailable in
        // async contexts). Guard against a double-stop.
        if stopped { return CapturedAudio() }
        stopped = true

        var urls: [AudioSource: URL] = [:]
        for source in sources {
            let url = directory.appendingPathComponent(Self.fileName(for: source))
            try Self.writeSilentWAV(at: url)
            urls[source] = url
        }
        return CapturedAudio(fileURLs: urls)
    }

    static func fileName(for source: AudioSource) -> String {
        source == .mic ? "mic.wav" : "system.wav"
    }

    /// Write a short silent 16-bit mono WAV (0.1 s) so the output is a real,
    /// readable audio file rather than an empty placeholder.
    static func writeSilentWAV(at url: URL) throws {
        let sampleRate = 44100, bits = 16, channels = 1
        let frames = 8820
        let dataBytes = frames * (bits / 8) * channels
        var d = Data()
        func u16(_ v: UInt16) { d.append(UInt8(v & 0xff)); d.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) {
            d.append(UInt8(v & 0xff)); d.append(UInt8((v >> 8) & 0xff))
            d.append(UInt8((v >> 16) & 0xff)); d.append(UInt8((v >> 24) & 0xff))
        }
        d.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        u32(16)               // fmt chunk size
        u16(1)                // PCM
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * bits / 8))
        u16(UInt16(channels * bits / 8))
        u16(UInt16(bits))
        d.append(contentsOf: Array("data".utf8))
        u32(UInt32(dataBytes))
        d.append(contentsOf: Data(count: dataBytes)) // silence
        try d.write(to: url)
    }
}


/// Small persistence seam for the transient artifacts. The view model asks for
/// cleanup without accessing the filesystem; tests can inject a failing store.
public protocol MeetingArtifactManaging: Sendable {
    func sweep(liveIDs: Set<UUID>) -> [URL]
    func remove(_ urls: [URL]) throws
    func removeEmptyDirectory(for id: UUID) throws
    func discard(_ meeting: Meeting) throws
}

public struct MeetingArtifacts: MeetingArtifactManaging {
    public init() {}

    public func sweep(liveIDs: Set<UUID>) -> [URL] {
        // An interrupted inference can leave a derived recording in a live
        // meeting folder. Remove only our known transient names; original
        // mic/system tracks and foreign folders are never swept here.
        if let entries = try? FileManager.default.contentsOfDirectory(at: RecordingsDirectory.base(),
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for directory in entries {
                guard let id = RecordingsDirectory.meetingID(inDirectoryName: directory.lastPathComponent),
                      liveIDs.contains(id),
                      (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                try? remove([CapturedAudio.preparedFileName, CapturedAudio.speechSectionFileName, CapturedAudio.speakerAudioFileName]
                    .map { directory.appendingPathComponent($0) })
            }
        }
        return RecordingsDirectory.orphanDirectories(liveIDs: liveIDs).filter {
            do { try FileManager.default.removeItem(at: $0); return true }
            catch { return false }
        }
    }

    public func remove(_ urls: [URL]) throws {
        for url in urls {
            do { try FileManager.default.removeItem(at: url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { continue }
        }
    }

    public func removeEmptyDirectory(for id: UUID) throws {
        for dir in try directories(for: id) {
            let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            if contents.isEmpty { try FileManager.default.removeItem(at: dir) }
        }
    }

    public func discard(_ meeting: Meeting) throws {
        try remove(RetentionPolicy(settings: AppSettings()).artifactsToDelete(for: meeting))
        try remove(meeting.contentFiles?.allURLs ?? [])
        try remove(directories(for: meeting.id))
    }

    /// Look up by ID so cleanup also works after a timezone change or upgrade.
    private func directories(for id: UUID) throws -> [URL] {
        let base = RecordingsDirectory.base()
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ).filter {
            guard RecordingsDirectory.meetingID(inDirectoryName: $0.lastPathComponent) == id else { return false }
            return try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }
    }
}

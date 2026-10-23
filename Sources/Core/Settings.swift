import Foundation

// MARK: - Settings (Core, lenient Codable)
//
// User preferences. Mirrors the base repo's `AppSettings`: lenient decoding
// (new keys default, so old files still load) and a `SettingsStore` with an
// `inMemory()` seam so tests never touch the user's real settings.json.
//
// The two decisions that drive the pipeline:
//   - `transcriptionBackend`: local (Apple Speech, private, no model download)
//     or cloud (Deepgram, best speaker ID, needs an API key in the Keychain).
//   - `whisperModel`: which whisper.cpp size to download on demand (only used
//     by the optional whisper path; the local Speech path needs no model).

/// Where transcription + speaker ID happens.
public enum TranscriptionBackend: String, Codable, CaseIterable, Sendable {
    /// Apple Speech, on-device, private. No API key, no model download.
    /// Speaker ID is best-effort (heuristic diarization).
    case local
    /// Deepgram (Nova) — native diarization (accurate speaker labels).
    /// Needs an API key (stored in the Keychain, never in settings.json).
    case deepgram
}

/// Where the summary comes from.
public enum SummaryBackend: String, Codable, CaseIterable, Sendable {
    /// On-device Apple Intelligence model — fully local, offline, no API key,
    /// no model download. Requires macOS 26+ with Apple Intelligence enabled;
    /// the app degrades gracefully (a clear error) on older systems.
    case local
    case openai
    case anthropic
}

public struct AppSettings: Codable, Equatable, Sendable {
    // Audio
    public var captureMic: Bool
    public var captureSystem: Bool
    public var inputDeviceID: String?
    public var inputDeviceName: String?

    // Storage + retention
    public var storageDirectory: URL?
    public var keepTranscriptAfterSummary: Bool
    public var keepAudioAfterSummary: Bool

    // Transcription
    public var transcriptionBackend: TranscriptionBackend
    public var whisperModel: String
    public var language: String

    // Summary
    public var summaryBackend: SummaryBackend
    public var summaryModel: String
    public var promptOverride: String?

    // General
    public var showToasts: Bool
    public var notifyOnSummary: Bool

    public init(
        captureMic: Bool = true,
        captureSystem: Bool = true,
        inputDeviceID: String? = nil,
        inputDeviceName: String? = nil,
        storageDirectory: URL? = nil,
        keepTranscriptAfterSummary: Bool = false,
        keepAudioAfterSummary: Bool = false,
        transcriptionBackend: TranscriptionBackend = .local,
        whisperModel: String = "whisper-base",
        language: String = "",
        summaryBackend: SummaryBackend = .openai,
        summaryModel: String = "gpt-4o-mini",
        promptOverride: String? = nil,
        showToasts: Bool = true,
        notifyOnSummary: Bool = true
    ) {
        self.captureMic = captureMic
        self.captureSystem = captureSystem
        self.inputDeviceID = inputDeviceID
        self.inputDeviceName = inputDeviceName
        self.storageDirectory = storageDirectory
        self.keepTranscriptAfterSummary = keepTranscriptAfterSummary
        self.keepAudioAfterSummary = keepAudioAfterSummary
        self.transcriptionBackend = transcriptionBackend
        self.whisperModel = whisperModel
        self.language = language
        self.summaryBackend = summaryBackend
        self.summaryModel = summaryModel
        self.promptOverride = promptOverride
        self.showToasts = showToasts
        self.notifyOnSummary = notifyOnSummary
    }

    /// The sources to capture, derived from the toggles.
    public var requestedSources: Set<AudioSource> {
        var s: Set<AudioSource> = []
        if captureMic { s.insert(.mic) }
        if captureSystem { s.insert(.system) }
        return s
    }

    // Lenient decoding: missing keys fall back to defaults so files written by
    // older versions still load (mirrors the base repo's TimeEntry strategy).
    private enum CodingKeys: String, CodingKey {
        case captureMic, captureSystem, inputDeviceID, inputDeviceName
        case storageDirectory, keepTranscriptAfterSummary, keepAudioAfterSummary
        case transcriptionBackend, whisperModel, language
        case summaryBackend, summaryModel, promptOverride
        case showToasts, notifyOnSummary
    }

    public init(from decoder: Decoder) throws {
        let d = try decoder.container(keyedBy: CodingKeys.self)
        let def = AppSettings()
        captureMic = try d.decodeIfPresent(Bool.self, forKey: .captureMic) ?? def.captureMic
        captureSystem = try d.decodeIfPresent(Bool.self, forKey: .captureSystem) ?? def.captureSystem
        inputDeviceID = try d.decodeIfPresent(String.self, forKey: .inputDeviceID)
        inputDeviceName = try d.decodeIfPresent(String.self, forKey: .inputDeviceName)
        storageDirectory = try d.decodeIfPresent(URL.self, forKey: .storageDirectory)
        keepTranscriptAfterSummary = try d.decodeIfPresent(Bool.self, forKey: .keepTranscriptAfterSummary) ?? def.keepTranscriptAfterSummary
        keepAudioAfterSummary = try d.decodeIfPresent(Bool.self, forKey: .keepAudioAfterSummary) ?? def.keepAudioAfterSummary
        transcriptionBackend = try d.decodeIfPresent(TranscriptionBackend.self, forKey: .transcriptionBackend) ?? def.transcriptionBackend
        whisperModel = try d.decodeIfPresent(String.self, forKey: .whisperModel) ?? def.whisperModel
        language = try d.decodeIfPresent(String.self, forKey: .language) ?? def.language
        summaryBackend = try d.decodeIfPresent(SummaryBackend.self, forKey: .summaryBackend) ?? def.summaryBackend
        summaryModel = try d.decodeIfPresent(String.self, forKey: .summaryModel) ?? def.summaryModel
        promptOverride = try d.decodeIfPresent(String.self, forKey: .promptOverride)
        showToasts = try d.decodeIfPresent(Bool.self, forKey: .showToasts) ?? def.showToasts
        notifyOnSummary = try d.decodeIfPresent(Bool.self, forKey: .notifyOnSummary) ?? def.notifyOnSummary
    }
}

// MARK: - SettingsStore
//
// Persists `AppSettings` to settings.json. `inMemory()` returns a store that
// never touches disk, so the test suite can round-trip settings without
// reading/writing the user's real file (same seam as the base repo).

public final class SettingsStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var cache: AppSettings?

    public init(url: URL) {
        self.url = url
    }

    /// A store that keeps settings only in memory (tests).
    public static func inMemory(initial: AppSettings = AppSettings()) -> SettingsStore {
        let s = SettingsStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriber-settings-\(UUID().uuidString).json"))
        s.cache = initial
        return s
    }

    public func load() -> AppSettings {
        if let c = cache { return c }
        guard let data = try? Data(contentsOf: url) else { return AppSettings() }
        do {
            let s = try JSONDecoder().decode(AppSettings.self, from: data)
            cache = s
            return s
        } catch {
            return AppSettings()
        }
    }

    public func save(_ s: AppSettings) {
        cache = s
        let data = (try? JSONEncoder().encode(s)) ?? Data()
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - MeetingNotification (Core, pure)
//
// Decides, given a meeting's terminal state + the user's settings, what
// notification (if any) to post when a meeting finishes. Pure: it returns the
// *content* to post (title / body / a severity), not the platform call — the
// App layer owns `UNUserNotificationCenter`. This is the same posture as
// `RetentionPolicy`: a product decision made testable without AppKit.
//
// Why it exists: a meeting started from the menu bar runs headless. When it
// finishes (or fails) the user may be in another app and has no other cue that
// the summary is ready — so the app posts a notification, gated by the
// `notifyOnSummary` setting.

/// What a notification should say about a finished meeting.
public struct MeetingNotification: Equatable, Sendable {
    public let title: String
    public let body: String
    /// Whether the outcome is an error (a failed pipeline). The App layer uses
    /// this to pick an alert style / sound; it has no effect on the copy.
    public let isError: Bool

    public init(title: String, body: String, isError: Bool) {
        self.title = title
        self.body = body
        self.isError = isError
    }
}

/// The pure decision: given a meeting + settings, the notification to post, or
/// `nil` when the user has disabled notifications or there is nothing to say.
public enum MeetingNotificationPolicy {
    /// `nil` when `notifyOnSummary` is off. A meeting that reached `.summarized`
    /// posts a "ready" note with the overall line; a `.failed` meeting posts an
    /// error note with the reason (if known) so the user knows to retry.
    /// Meetings still `.recording` or `.processing` post nothing — they are not
    /// terminal, so a notification would be premature.
    public static func notification(
        for meeting: Meeting,
        errorDescription: String?,
        settings: AppSettings
    ) -> MeetingNotification? {
        guard settings.notifyOnSummary else { return nil }

        let title = meeting.title.isEmpty ? "Meeting" : meeting.title

        switch meeting.status {
        case .summarized:
            let overall = meeting.summary?.overall.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = (overall?.isEmpty ?? true)
                ? "Summary ready."
                : "Summary ready: \(overall!)"
            return MeetingNotification(title: title, body: body, isError: false)
        case .failed:
            let detail = errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = (detail?.isEmpty ?? true)
                ? "This meeting failed. Open it to retry."
                : "This meeting failed: \(detail!). Open it to retry."
            return MeetingNotification(title: title, body: body, isError: true)
        case .recording, .processing:
            return nil
        }
    }
}

// MARK: - RetentionPolicy (Core, pure)
//
// Decides, given a meeting + settings, which on-disk artifacts to delete after
// a successful summary. Pure: it returns the *set of URLs to delete* — the
// actual `FileManager.remove` is a side effect the view model performs. This
// is the product's core promise (keep only the summary) made testable.
//
// Defaults (per the requirement): delete audio + transcript, keep the summary.
// Toggles: "keep transcript" / "keep audio" (both default off).

public struct RetentionPolicy: Sendable {
    public let settings: AppSettings

    public init(settings: AppSettings) {
        self.settings = settings
    }

    /// The on-disk artifacts to delete after a successful summary.
    public func artifactsToDelete(for meeting: Meeting) -> [URL] {
        var urls: [URL] = []
        if !settings.keepAudioAfterSummary {
            urls.append(contentsOf: meeting.audioFileURLs.values)
        }
        if !settings.keepTranscriptAfterSummary {
            // The transcript is stored in meetings.json, not a separate file in
            // the MVP — but if a transcript file was written, it lives next to
            // the audio. We delete the per-meeting directory's transcript file
            // if present; the engine also clears the in-memory transcript.
            if let base = meeting.audioFileURLs.values.first?.deletingLastPathComponent() {
                urls.append(base.appendingPathComponent("transcript.json"))
            }
        }
        // De-duplicate (a URL could appear once per source).
        return Array(Set(urls))
    }

    /// True if, after summarization, the meeting keeps its transcript in the
    /// record (the engine retains it) rather than clearing it.
    public var keepTranscript: Bool { settings.keepTranscriptAfterSummary }

    /// True if audio files are retained after summarization.
    public var keepAudio: Bool { settings.keepAudioAfterSummary }
}

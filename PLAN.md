# Transcriber — Plan

A native macOS app that records a meeting (your mic **and** system audio, so it
captures Zoom / Slack / Teams conversations), then turns that recording into a
**transcript with identified speakers**, writes a **meeting summary**, and keeps
only the **summary** — deleting the audio and the transcript.

> **Implementation progress (as of the meeting detail pane, orphan sweep, notifications, and long-meeting hardening).**
> Phases 0–5 plus the Settings window, menu bar, the meeting detail pane, the
> startup orphan sweep, **notifications**, and **long-meeting hardening** are
> built and green (278 tests, `bash build.sh test`):
> the pure core model + engine, mic +
> system audio capture, the **transcribe → diarize → summarize → retention**
> pipeline (pluggable Apple Speech / Deepgram + OpenAI / Anthropic), **durable
> persistence** via `MeetingStore` → `meetings.json`, and a **Settings window**
> (⌘,) for backends, models, retention, language, and API keys (Keychain).
> The summary survives a relaunch (the product's core promise), and a meeting
> that was mid-flight when the app quit is reconciled to a retryable `.failed`
> state on next launch. The pipeline is now **rebuilt from the current settings
> at run time** (a `processorFactory` seam on the view model), so switching
> backend or model in Settings takes effect on the next meeting without a
> relaunch. A **menu-bar item** offers a live Start / Stop. Selecting a meeting
> opens a **detail pane** with the full structured summary, the retained
> transcript (when kept), a **Retry** button for failed meetings, and
> **copy** / **delete** actions — the copyable text comes from pure Core
> helpers (`summaryText()` / `transcriptText()`). The **startup orphan sweep**
> is done: retention now removes the empty per-meeting recording directory after
> a successful summary, and `TranscriberViewModel` runs a pure
> `RecordingsDirectory.orphanDirectories(liveIDs:)` decision at launch to clear
> any that outlived their meeting (a live, non-empty dir is always kept so a
> failed meeting's audio stays retryable) — so no empty directories leak into
> `~/Library/Application Support`. **Notifications** are done: the previously
> dead `notifyOnSummary` toggle now drives a real macOS banner — a pure
> `MeetingNotificationPolicy.notification(for:errorDescription:settings:)`
> decision in Core (nothing for `.recording`/`.processing`, a "Summary ready:
> {overall}" note on success, a "This meeting failed: {reason}…" error note on
> failure, and nothing at all when the toggle is off) feeds a `notifier` seam
> on the view model, and the App layer posts it via `UserNotifications`
> (requesting authorization once at launch). The decision is pure Core and
> tested; the App owns the platform framework. **Long-meeting hardening** is
> done: the real HTTP client (`URLSessionHTTPClient`) now uses a dedicated
> `URLSession` with a generous request timeout (`HTTPRetryPolicy.
> defaultRequestTimeout`, 300s) instead of `URLSession.shared`'s 60s cap, so a
> long recording's upload to Deepgram or a long transcript's trip to the LLM
> can't be cut off mid-flight; and the pipeline's client is wrapped in a pure
> `HTTPRetryPolicy`-driven `RetryingHTTPClient` (Core) that retries transient
> 429 / 5xx / network-timeout failures up to a cap while never retrying 4xx
> client errors — the decision is pure Core and tested with a scripted fake, the
> backoff delay is injectable so the suite stays instant, and the App wires the
> real client + retry into `ProcessorFactory` by default. The **transcript cap**
> is also done: both LLM summarizers fit the transcript into a generous
> `Summary.defaultTranscriptBudget` (120k chars) via the pure
> `Summary.fitTranscript`, which keeps the opening (agenda/context) and the
> closing (decisions/action items) and marks the omission in between — so a very
> long recording's prompt stays inside the model's context window and cost
> budget instead of failing the summary with a 400. And because that cap is a
> *partial view*, the **user is told**: `MeetingSummary.transcriptWasCapped`
> (lenient-decoded, so old stored summaries load as uncapped) is set by both
> summarizers when the transcript didn't fit, carried through the pipeline to
> the persisted summary, and surfaced three ways — the detail pane shows an
> orange warning banner, `summaryText()` (the Copy path) prepends a
> "partial view" note, and the flag survives encode/decode so the caveat is
> still there after a relaunch. Remaining: the
> Phase 7 onboarding polish and a live end-to-end run with a real key. Note:
> the detail pane's on-screen rendering has been verified only
> indirectly — the app launches with seeded data and its window opens, and the
> copyable text it shows is covered by
> the integration test — but the live display was asleep during the session, so
> a visual confirmation of the rendered pane is still outstanding.

This plan is written to be implemented on top of the `timetracker` repo: same
architecture, same build system, same conventions. Where it differs, the
difference is called out.

> **Read this first — where I had to guess.** You asked for a plan, not a
> spec, so I filled the gaps with sensible defaults and flagged them. The
> items marked **ASSUMPTION** are things I decided on your behalf that you
> should confirm or override before I start coding. Everything else is either
> directly stated in your request or a safe engineering default.

- **ASSUMPTION — "identify different speakers" = speaker diarization.**
  I interpreted "identify different speakers" as *automatic* speaker
  separation (labeling utterances Speaker 1 / Speaker 2 / …), not as the user
  manually tagging who said what. If you meant manual labeling, the pipeline
  changes a lot (no diarization engine needed).
- **ASSUMPTION — the summary is the only durable artifact.** You said "save
  only the meeting summary." I read that as: the **summary text is the only
  thing persisted**; the audio and the full transcript are deleted after the
  summary is generated. I've made this the *default* but left a toggle to keep
  the transcript (in case you want it). If you want the transcript gone
  *always* with no option, say so and I'll hard-code it.
- **ASSUMPTION — "meeting" is a single continuous recording.** I assumed one
  Start → one Stop = one meeting, transcribed after Stop. I did **not** assume
  live/real-time transcription (you didn't ask for it), and I did **not**
  assume multiple simultaneous meetings.
- **ASSUMPTION — local-first is *not* required.** You didn't say "offline" or
  "no API." So I've planned for a **cloud transcription + LLM summary** as the
  primary path (most reliable speaker ID + best summaries), with a **local
  (on-device)** fallback as a secondary. If privacy/offline is a hard
  requirement, that flips the priority — tell me.
- **ASSUMPTION — macOS-only, Apple Silicon, no Xcode.** I'm mirroring
  `timetracker`: `swiftc`-only build, macOS 14+ target, arm64. Confirm this
  matches your environment (I'll verify the actual machine before Phase 0).
- **ASSUMPTION — "start/stop audio recording" = record to disk, then process.**
  I'm capturing to a file and transcribing on Stop, not streaming. This is the
  simpler, more robust choice and matches "transcribe the conversation" (not
  "transcribe as it happens").
- **ASSUMPTION — one app, one window + menu bar.** I'm assuming a normal macOS
  app (window + optional menu-bar extra), not a menu-bar-only utility.

If any of these are wrong, the cheapest fixes are the first two (diarization
and retention), because they change the pipeline and the data model.

---

## 1. Goals & non-goals

### Goals (MVP)
- **Start / stop recording** with one button, with a live timer and input-level
  meter.
- **Capture two sources**: the microphone (your voice) and system audio
  (everyone else, from Zoom / Slack / Teams). Mix them into one recording.
- **Name a meeting** at start (optional; defaults to a timestamp if left blank).
- On stop, **process** the recording into:
  1. a **transcript** with **speaker labels** (who said what, in order), and
  2. a **structured summary** (overall gist, key points, decisions, action items).
- **Retention**: once the summary is captured, **delete the audio file and the
  transcript**, keeping only the summary + metadata. (Configurable; see §10.)
- **Preferences**: choose audio devices, where summaries are saved, the
  transcription/summary backend, and retention behavior.
- **History**: a searchable list of past meetings (title, date, duration,
  speakers, status); open one to read its summary; delete it.
- **Menu bar** quick control (start/stop, live timer, open window).
- **Buildable with `swiftc` only** (no full Xcode), with a fast, deterministic
  test suite — exactly like `timetracker`.

### Non-goals (for now)
- Live / real-time transcription while the meeting is in progress (we transcribe
  after stop).
- Cloud sync, multi-user, sharing, export to other tools.
- Windows / Linux.
- Editing or re-summarizing a meeting (v1 is read-mostly after it's done).
- Capturing video, or the screen image (audio only).

---

## 2. What we reuse from `timetracker` (and what changes)

| Concern | `timetracker` (base) | `transcriber` (this app) |
|---|---|---|
| Layering | Pure `Core/` + SwiftUI `App/` | **Same.** Core stays pure; capture/ASR/LLM live in App behind protocols. |
| State machine | `TimeTrackerEngine` (add/start/stop/auto-stop) | `MeetingEngine` (start/stop/processing/summarized/failed/delete). |
| Persistence | `EntryStore` (backup-rotating JSON), `SettingsStore` (+ `inMemory()`) | `MeetingStore` (same durability), `SettingsStore` (same, `inMemory()`). |
| View model | `TrackerViewModel` (ticker, toasts, injected hooks) | `TranscriberViewModel` (ticker, toasts, injected `MeetingProcessor`). |
| Platform hooks | `postReminder` / `requestAuthorization` closures | `process` / `reportProgress` closures + `AudioCapture`. |
| Build | `build.sh` (swiftc + SDK fallback), `Package.swift` | **Copied**, renamed, + mic/screen usage keys in Info.plist. |
| Tests | `Tests/main.swift` assertion harness | **Same harness**, new sections for the meeting pipeline. |
| Toasts | `ToastCenter` | **Reused pattern** (delete / processing-complete / processing-failed). |

The single structural addition is a **pluggable processing pipeline**
(`TranscriptionEngine` + `Diarizer` + `Summarizer`, or one `MeetingProcessor`)
whose concrete backends live in the App layer. Everything the user can
*decide* (start/stop, ordering, search, retention, settings) stays in the pure,
testable Core.

---

## 3. Architecture

Two modules, mirroring `timetracker`'s `Package.swift`:

- **`TranscriberCore`** (`Sources/Core/`) — pure. No AVFoundation, no
  network, no file I/O in the engine. Models, the lifecycle state machine,
  persistence layers, settings, retention logic, and the *protocols/types* for
  the processing pipeline. Deterministic and unit-testable.
- **`TranscriberApp`** (`Sources/App/`) — the SwiftUI shell **and** all
  platform detail: `AVAudioEngine` mic capture, screen-capture system audio,
  CoreAudio device enumeration, the concrete transcription/diarization/summary
  backends (local + cloud), LLM client, TCC permission prompts, notifications.

The Core layer never imports `AVFoundation`, `AVFAudio`, `CoreAudio`,
`Speech`, `URLSession`, or `UserNotifications`. It only sees the *abstractions*
(`AudioCapture`, `MeetingProcessor`, `TranscriptionEngine`, `Diarizer`,
`Summarizer`) and the data types. Concrete implementations are injected by the
App layer (or by the test harness).

### File layout

```
transcriber/
  build.sh                        # swiftc-only build + test runner (copied, renamed)
  Package.swift                   # TranscriberCore lib + TranscriberApp + TranscriberTests
  AGENTS.md                       # build gotcha + hard constraints + Transcriber-specific rules
  README.md
  PLAN.md                         # this document
  Sources/
    Core/
      Meeting.swift               # Meeting, MeetingSummary, TranscriptSegment, RecordingState
      MeetingEngine.swift         # pure lifecycle state machine (no I/O)
      MeetingStore.swift          # JSON persistence (backup-rotating) for meetings.json
      Settings.swift              # AppSettings: audio, storage dir, retention, backend, model
      SettingsStore.swift         # JSON persistence for settings.json (+ inMemory() for tests)
      RetentionPolicy.swift       # pure decision: what to delete after a successful summary
      Pipeline.swift              # protocols + types: MeetingProcessor, TranscriptionEngine,
                                  #   Diarizer, Summarizer, CapturedAudio, ProcessingProgress
      TranscriberViewModel.swift  # @MainActor ObservableObject bridge + ticker + processor wiring
      ToastCenter.swift           # transient toast state + auto-dismiss (reused pattern)
      Clock.swift                 # Clock protocol + SystemClock (determinism under test)
    App/
      TranscriberApp.swift        # @main: window + Settings + MenuBarExtra + permission/terminate wiring
      ContentView.swift           # header, start/stop, live meter, list, search
      MeetingRow.swift            # one meeting row: title, date, duration, status, speakers
      MeetingDetailView.swift     # summary (or live processing status) for one meeting
      AudioCapture.swift          # AVAudioEngine mic + screen-capture system audio -> file(s)
      AudioDevices.swift          # CoreAudio input/output device enumeration
      LocalTranscriber.swift      # Apple Speech (SFSpeechURLRecognition) + diarization (optional)
      CloudTranscriber.swift      # AssemblyAI / Deepgram transcribe + diarize (API key)
      LLMClient.swift             # generic OpenAI/Anthropic call for the summary
      Permissions.swift           # Microphone + Screen Recording TCC prompts + status
      TranscriberNotifications.swift  # completion / failure notifications (app layer)
  Resources/                      # (reserved: app icon, summary prompt template)
  Tests/
    main.swift                    # assertion harness for the Core module
```

---

## 4. Domain model (Core)

### `RecordingState`
```
idle          // no meeting is active
recording     // audio is being captured
processing    // stopped; transcribe -> diarize -> summarize running
summarized    // summary captured; audio + transcript deleted (terminal, happy path)
failed        // processing errored; artifacts may remain, user can retry or discard
```

### `TranscriptSegment`
```
id: UUID
speaker: String          // "Speaker 1", "Speaker 2", or a resolved name
text: String
startOffset: TimeInterval   // seconds from recording start
endOffset: TimeInterval
```

### `MeetingSummary`
```
overall: String          // 2–4 sentence gist
keyPoints: [String]
decisions: [String]
actionItems: [String]
generatedAt: Date
model: String            // which backend/model produced it (for transparency)
```

### `Meeting`
```
id: UUID
title: String
status: RecordingState
startedAt: Date
stoppedAt: Date?                 // recording end (nil while recording)
duration: TimeInterval           // stoppedAt - startedAt (derived, also stored on stop)
createdAt: Date
lastActivityAt: Date            // for "recent" ordering

// Transient until summarized:
audioFileURLs: [AudioSource: URL]   // .mic, .system — deleted after summary
transcript: [TranscriptSegment]     // deleted after summary
speakerCount: Int

// Retained:
summary: MeetingSummary?
```

`Meeting` is `Codable` with **lenient decoding** (mirrors `TimeEntry`): new
keys default to empty so files written by older versions still load.

---

## 5. Lifecycle state machine (Core, pure)

`MeetingEngine` is the pure state machine (the `TimeTrackerEngine` analog).
Clock-injected, no I/O. Transitions:

- `startRecording(title:)` → create a `Meeting` in `.recording` (only one
  active at a time; starting a new one stops the current — same "only one
  running" invariant as `timetracker`).
- `stopRecording(id:)` → set `stoppedAt`, compute `duration`, status →
  `.processing`. (The *actual* processing is kicked off by the view model via
  the injected processor; the engine only records state.)
- `markProcessing(id:)` / progress updates → stays `.processing`.
- `markSummarized(id:, summary:, speakers:)` → attach `summary`, set
  `speakerCount`, status → `.summarized`, clear `transcript`. (Audio deletion
  is a *side effect* handled by the view model + `RetentionPolicy`, not the
  engine — the engine just drops the transient fields from its model.)
- `fail(id:, reason:)` → status `.failed` (artifacts kept for retry).
- `retry(id:)` → back to `.processing`.
- `delete(id:)` → remove (also deletes any on-disk artifacts — side effect).
- `recent` → most-recently-active first, active meeting pinned to top.
- `search(query:)` → case-insensitive substring over title, summary text,
  speaker names, and transcript text.

The engine knows *nothing* about audio, files, or networks. It is fully
testable with a `ManualClock` and a fake processor, exactly like the base
tests.

---

## 6. Processing pipeline (Core protocols + App implementations)

Defined in Core so it's testable; implemented in App so Core stays pure.

```swift
// Core — the data that flows through the pipeline
public enum AudioSource: String, Sendable { case mic, system }
public struct CapturedAudio: Sendable { public var files: [AudioSource: URL] }
public struct ProcessingProgress: Equatable, Sendable {
    public var stage: Stage            // .transcribing / .diarizing / .summarizing
    public var fraction: Double        // 0...1 within the stage
    public enum Stage: String, Sendable { case transcribing, diarizing, summarizing }
}
public struct ProcessedResult: Sendable {
    public var segments: [TranscriptSegment]
    public var summary: MeetingSummary
}

// Core — the abstraction the view model calls
public protocol MeetingProcessor: Sendable {
    func process(
        meetingID: UUID,
        audio: CapturedAudio,
        meeting: Meeting,
        report: @Sendable (ProcessingProgress) -> Void
    ) async throws -> ProcessedResult
}
```

`MeetingProcessor` is the single seam the view model depends on. It can be
implemented in three ways, all behind the same protocol:

1. **`LocalProcessor`** (App): Apple `SFSpeechURLRecognitionRequest` for
   on-device transcription + a diarization step (see §8). No API key, private.
2. **`CloudProcessor`** (App): one provider (AssemblyAI or Deepgram) that
   returns a diarized transcript, then an LLM call for the summary.
3. **`FakeProcessor`** (Tests): returns canned segments + summary
   synchronously, so the whole pipeline is exercised deterministically.

The view model's `stop` path:
```
stopRecording(id)
  → engine.stopRecording(id)                 // state: .processing
  → Task { @MainActor in
        let result = try await processor.process(...)   // updates progress
        engine.markSummarized(id:, result)              // state: .summarized
        retention.deleteArtifacts(for: meeting)         // side effect: rm audio+transcript
        store.saveNow()
        toast("Summary ready")
      }
```
On error: `engine.fail(id:, reason:)`, keep artifacts, toast the failure, offer
Retry.

---

## 7. Audio capture (App layer) — **the hard part**

Two sources, recorded, then mixed into one stream for ASR.

### Sources
- **Mic**: `AVAudioEngine` input node → `AVAudioFile` (CAF). Standard.
- **System audio** (Zoom/Slack/Teams output): the tricky one. macOS options:
  1. **ScreenCaptureKit (recommended, no third-party)**: `SCStream` +
     `SCStreamConfiguration` with `capturesAudio = true` captures the display's
     system audio mix. Requires the app to be in the **Screen Recording** list
     (TCC service `kTCCServiceScreenCapture`). **No Info.plist usage string is
     required** — verified: the ScreenCaptureKit framework references no
     `*UsageDescription` key; the prompt is TCC-only (unlike the mic, which
     needs `NSMicrophoneUsageDescription`). This grabs *all* system output
     audio — exactly what we want for a meeting.
     **Verified against the installed macOS 27 SDK** (compiles clean):
     - Entry: `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)`
       → first `display`.
     - Filter: `SCContentFilter(display:excludingWindows:[])`.
     - Config: `capturesAudio = true` (macOS 13+); `captureMicrophone` is
       `macOS 15+` (guard with `if #available`); set `sampleRate`/`channelCount`,
       `showsCursor = false`, minimal `width`/`height` (we only want audio).
     - Delegate: `stream(_:didOutputSampleBuffer:ofType:)`, handle
       `SCStreamOutputType.audio`.
     - Buffer → PCM: `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer`
       (two-call pattern: size, then fill a raw-allocated `AudioBufferList`),
       format via `CMSampleBufferGetFormatDescription` +
       `CMAudioFormatDescriptionGetStreamBasicDescription`, then
       `AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)` and
       `AVAudioPCMBuffer`.
     - `startCapture` is a callback; bridge it to async with
       `withCheckedThrowingContinuation`.
  2. **Virtual audio device (alternative)**: BlackHole / Loopback. User routes
     system output through the virtual device and we record it as a normal
     input. No Screen Recording permission, but requires installing a driver.

  **Decision needed (§15).** Default plan: **ScreenCaptureKit** (option 1).

### Mixing strategy (MVP)
- Record **mic** and **system** as **two separate files** during capture
  (simplest, most robust — no real-time mixing bugs).
- In the pipeline, decode both, **sum to a single mono PCM** (with per-source
  gain), and feed that to the transcriber.
- If only one source is present (user disabled one), transcribe that one.
- **Stretch**: real-time mix into one file during capture (nice, but more
  failure modes; defer).

### Live UI feedback
- `AudioCapture` exposes a **live level** (RMS) so the header shows a meter.
- `AudioCapture` reports **device errors / permission loss** so the UI can show
  "Microphone not authorized" etc.

### `AudioCapture` protocol (Core) / `AVAudioCapture` (App)
```swift
// Core
public protocol AudioCapture: Sendable {
    func start(sources: Set<AudioSource>, to dir: URL) async throws -> CapturedAudio
    func stop() async throws
    var level: (AudioSource) -> Float { get }     // for the meter
}
```
`AVAudioCapture` (App) implements it with `AVAudioEngine` + screen capture.
Tests use a fake that writes a tiny valid audio file.

---

## 8. Transcription + speaker identification (App)

### Option A — Local (private, no key)
- **Transcription**: `SFSpeechURLRecognitionRequest(url:)` with
  `requiresOnDeviceRecognition = true` (when a model is available) — Apple
  Speech, runs on the Mac, no network.
- **Diarization**: Apple Speech does **not** do speaker separation. Options:
  - Bundle a speaker-embedding model (e.g. a small `whisper.cpp` +
    pyannote-style clustering) — heavy to bundle in a `swiftc` build.
  - Heuristic turn-taking (energy/overlap) — weak, not reliable.
- **Verdict**: local transcription is solid; local *diarization* is the weak
  point. Good for privacy-first users who accept "Speaker 1/2" heuristics or a
  bundled model.

### Option B — Cloud (best diarization, needs API key)
- **AssemblyAI** or **Deepgram (Nova)**: one call returns a **diarized
  transcript** (speaker labels + timestamps) — the most reliable path to
  "identify different speakers."
- Then an **LLM** call (OpenAI / Anthropic) produces the structured summary.
- Tradeoff: audio leaves the machine; per-meeting cost; needs an API key
  (stored in **Keychain**, never in `settings.json`).

### Recommendation
- **Default backend: cloud (AssemblyAI or Deepgram) for transcribe+diarize,
  OpenAI/Anthropic for the summary** — it's the most reliable for the
  "identify speakers" requirement and the least code to get right.
- **Local mode** (Apple Speech + best-effort diarization) as a documented,
  selectable alternative for privacy.
- All behind `MeetingProcessor`, so backends are swappable and the Core tests
  never depend on which one is chosen.

**Decision needed (§15):** local vs cloud default, and which provider.

---

## 9. Summarization (App)

- **`Summarizer`** protocol (Core) / `LLMClient` (App).
- Input: the **diarized** transcript (speaker-labeled, so the summary can
  attribute statements).
- Output: JSON that maps 1:1 to `MeetingSummary`
  (`overall`, `keyPoints`, `decisions`, `actionItems`).
- A **prompt template** (in `Resources/`, overridable in Settings) is the key
  asset. Structured output enforced (JSON mode / tool call) with a fallback to
  plain text if the model misbehaves.
- Provider-agnostic: OpenAI and Anthropic behind `LLMClient`; model name from
  Settings.

---

## 10. Retention (Core, pure — testable)

`RetentionPolicy` decides, given a `Meeting` + `AppSettings`, which on-disk
artifacts to remove:

- **Default (per requirement)**: after a successful summary → **delete the
  audio file(s) and the transcript**; keep only the `Meeting` record
  (summary + metadata) in `meetings.json`.
- **Toggles** (Settings):
  - "Keep transcript after summarization" (default **off**).
  - "Keep audio after summarization" (default **off**).
- **Destructive-action guard**: deletion is irreversible, so the UI offers a
  "Keep" path and the *delete-meeting* action (removing a summarized meeting)
  asks for confirmation (mirrors `timetracker`'s safe-delete).
- `RetentionPolicy` is pure (returns the set of URLs to delete) so it's unit
  tested; the actual `FileManager.remove` is a side effect in the view model.

---

## 11. Preferences (Settings)

`AppSettings` (Core, lenient `Codable`, mirrors the base `AppSettings`):

- **Audio**
  - Input device (mic) — id + name.
  - "Capture system audio" toggle (default on) + which display/output.
  - "Capture microphone" toggle (default on).
  - Per-source gain (optional).
- **Storage**
  - **Location to save meeting summaries** (a directory; default
    `~/Library/Application Support/Transcriber/`).
  - "Keep transcript after summarization" (default off).
  - "Keep audio after summarization" (default off).
- **Transcription**
  - Backend: `local` | `assemblyai` | `deepgram`.
  - API key (reference — actual value in **Keychain**).
  - Language (default: system).
- **Summary**
  - LLM provider: `openai` | `anthropic`.
  - Model name.
  - Prompt template override (optional).
- **General**
  - "Show in-app toasts" (default on).
  - "Post a notification when a summary is ready" (default on).

`SettingsStore` persists to `settings.json` (same durability as the base).
`SettingsStore.inMemory()` for tests.

---

## 12. Storage layout (on disk)

```
<storage dir>/                     # default: ~/Library/Application Support/Transcriber/
  meetings.json                    # retained summaries + metadata (backup-rotating .bak)
  settings.json                    # preferences (always in Application Support, see below)
  recordings/<meetingID>/         # transient audio (mic.caf / system.caf) — deleted after summary
```

- `meetings.json` uses the **same backup-rotation + corrupt-fallback** logic as
  `EntryStore` (the summary is the user's irreplaceable data).
- `settings.json` uses the lighter `SettingsStore` approach.
- **Data location is user-configurable.** The `<storage dir>` (meetings +
  recordings) is resolved by the pure Core `StorageDirectory` resolver from the
  `storageDirectory` setting: the user's chosen directory if set, otherwise
  Application Support. `settings.json` itself always lives in Application
  Support so the app can find it on launch before it knows the custom path.
  The Settings window exposes a "Data location" picker (Choose… / Reset).
- `recordings/` is ephemeral; a startup sweep removes orphans
  (meetings that never reached `.summarized`).

---

## 13. UI

### Main window
- **Header**: big **Start / Stop** button, live timer (h:mm:ss), live input
  level meter, and a "New meeting" title field (optional) + Start.
- **Meeting list**: recent first, active meeting pinned to top. Each row:
  title, date, duration, **status badge** (Recording / Processing / Summarized
  / Failed), speaker count. Click → detail.
- **Search box**: filters by title, summary, speaker, transcript text.
- **Detail** (`MeetingDetailView`):
  - `.summarized`: overall gist, key points, decisions, action items, speakers,
    "Open in Finder" (if audio kept), "Delete" (with confirmation).
  - `.recording`: live timer + meter + Stop.
  - `.processing`: stage + progress bar + Cancel.
  - `.failed`: error + Retry + Discard.
- **Toasts** (sparingly): delete, summary-ready, processing-failed.

### Menu bar
- `MenuBarExtra` (`.window` style) sharing the same view model as the window
  (mirrors the base). Shows the active meeting's timer + Stop, and "Open
  Transcriber" / "Settings…" / "Quit".

### Permissions & onboarding
- On first **Start** (or first run), request **Microphone** and, if system
  audio is enabled, **Screen Recording**.
- A short onboarding card explains each permission and links to
  System Settings if a permission is missing, and disables the affected source
  until granted.

### Settings window
- Sections: **Audio**, **Storage**, **Transcription**, **Summary**, **General**
  (mirrors the base's sectioned `SettingsView`).

---

## 14. Build & test

### `build.sh` (copied from `timetracker`, then)
- `APP_NAME="Transcriber"`, `BUNDLE_ID="local.transcriber"`.
- Add all `Sources/Core/*.swift` to `CORE_SRC`, `Sources/App/*.swift` to
  `APP_SRC`.
- **Keep the SDK-fallback logic verbatim** (the `SwiftUIMacros` gotcha).
- Info.plist additions:
  - `NSMicrophoneUsageDescription` (required for mic capture).
  - **No usage string for system audio.** Verified: ScreenCaptureKit's
    Screen-Recording permission is TCC-only (`kTCCServiceScreenCapture`); the
    framework references no `*UsageDescription` key. Do **not** add a guessed
    `NSScreenCaptureUsageDescription`.
  - `LSApplicationCategoryType` = productivity (same as the base).
- `codesign` stays ad-hoc (required for a GUI app; also helps TCC prompts).

### `Package.swift`
- `TranscriberCore` (path `Sources/Core`), `TranscriberApp` (path
  `Sources/App`, depends on Core), `TranscriberTests` (path `Tests`, depends on
  Core).

### `AGENTS.md`
- Keep the base's build gotcha + hard constraints.
- Add Transcriber-specific rules:
  - **Core stays pure** — no `AVFoundation`/`CoreAudio`/`Speech`/`URLSession`
    in Core; capture, ASR, and summary are App-layer behind injected protocols.
  - **API keys live in Keychain**, never in `settings.json`.
  - **Retention deletes are destructive** — gate behind settings + a UI
    confirm; the engine never deletes files.
  - **Remove dead public APIs** (base rule).

### Test plan (`Tests/main.swift`, same harness)
- **Engine**: start/stop/auto-stop, processing→summarized, fail→retry, delete,
  `recent` ordering, search (title/summary/speaker/transcript).
- **Retention**: default deletes audio+transcript; toggles keep them; the pure
  decision returns exactly the right URL set.
- **Pipeline (fake)**: `stop` → processor called once with the right `CapturedAudio`
  → `markSummarized` clears transcript, sets summary, status `.summarized`.
- **Persistence**: `meetings.json` round-trip, backup rotation, corrupt
  fallback, **backward-compat decode** (old files without new keys).
- **Settings**: defaults, lenient decode, `inMemory()` round-trip, file
  round-trip.
- **View model wiring**: ticker auto-starts, toasts, injected-processor side
  effects are captured (mirrors the base's "settings wiring" section).

---

## 15. Key decisions needed (before code)

These materially change the build. I've put a **recommended default** next to
each; tell me where you'd differ.

1. **Transcription + diarization backend.**
   - Recommended: **cloud (AssemblyAI or Deepgram)** for reliable speaker
     identification + an LLM summary.
   - Alternative: **local** (Apple Speech on-device + best-effort diarization)
     for privacy.
   - This drives privacy (local = audio never leaves the Mac), cost, and setup
     (cloud needs an API key).
2. **System-audio capture method.**
   - Recommended: **ScreenCaptureKit** (`SCStream` + `capturesAudio`)
     — no third-party, captures all app output.
   - Alternative: **virtual audio device** (BlackHole/Loopback).
3. **Summary LLM.** Recommended: **OpenAI** (default) with Anthropic as an
   option; model from Settings.
4. **Retention default.** Recommended: **delete audio + transcript after a
   successful summary** (per your requirement), with "keep" toggles off by
   default.
5. **Mixing.** Recommended: **record mic + system separately, mix in the
   pipeline** (robust). Real-time mix deferred.
6. **Meeting naming.** Recommended: **optional title at start**; default to a
   timestamp if blank.

---

## 16. Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **System-audio capture** (permission + API) | Can't capture the meeting | Default to Screen Recording; document the virtual-device fallback; onboarding explains the permission. |
| **Speaker diarization quality** | Wrong/mis-merged speakers | Use a provider with native diarization; keep speaker labels as "Speaker N" until names are known; make diarization pluggable. |
| **Long meetings** (hours) | Big files, slow/costly ASR, timeouts | Stream/progress reporting; chunked upload for cloud; generous timeouts + retry; cap or warn on very long recordings. **Done:** 300s timeout + `RetryingHTTPClient`; transcript cap (`Summary.fitTranscript`); user-facing partial-view warning (`transcriptWasCapped` → detail banner + copy note + lenient decode); progress via `ProcessingProgress`. **Evaluated and deferred:** chunked cloud upload — Deepgram's max is 2 GB (a 1-hr mono recording is ~345 MB, well within it), and the 300s timeout + retry already handle the timeout risk; splitting the audio into separate requests would fragment speaker diarization (Speaker 1 in chunk 3 ≠ Speaker 1 in chunk 7), a real quality regression for no benefit at realistic meeting lengths. |
| **Destructive retention** | User loses audio/transcript they wanted | Toggles default per requirement but easily flipped; "Keep" path; delete-meeting confirmation. |
| **Privacy (cloud)** | Audio leaves the machine | Offer local mode; make the choice explicit in Settings; state it in onboarding. |
| **SDK/SwiftUI macro build gotcha** | Build fails on some machines | Keep the base's SDK-fallback verbatim. |
| **Permission loss mid-meeting** | Silent capture failure | `AudioCapture` reports errors; UI shows a clear status; log to Console. |

---

## 17. Phased roadmap

Each phase ends in a **buildable, testable** state (`bash build.sh test`).

- **Phase 0 — Scaffold.** `build.sh`, `Package.swift`, `AGENTS.md`, `README.md`,
  empty `Core`/`App`, Core compiles, harness runs (0 checks). *Accept: builds +
  runs the empty suite.*
- **Phase 1 — Core model + engine + persistence.** `Meeting`, `MeetingEngine`,
  `MeetingStore`, `Settings`, `SettingsStore`, `RetentionPolicy`, `Pipeline`
  protocols. Full unit tests. *Accept: engine + retention + persistence green,
  no audio/network involved.*
- **Phase 2 — View model + main UI (stub processor).** `TranscriberViewModel`,
  `ContentView`, `MeetingRow`, `MeetingDetailView`, menu bar, toasts, settings
  window. Fake processor so the whole flow works end-to-end. *Accept: start →
  (fake) process → summary shown; list/search/detail work; settings persist.*
- **Phase 3 — Audio capture (App).** `AudioCapture` protocol + `AVAudioCapture`
  (mic + system), `AudioDevices`, live meter, `Permissions`. *Accept: records a
  real mic + system file; meter moves; permissions flow works.*
- **Phase 4 — Transcription + diarization.** `LocalTranscriber` and/or
  `CloudTranscriber` behind `MeetingProcessor`. *Accept: a real recording
  yields a speaker-labeled transcript (chosen backend).*
- **Phase 5 — Summarization.** `LLMClient` + `Summarizer` + prompt template.
  *Accept: transcript → structured `MeetingSummary` shown in detail view.*
- **Phase 6 — Retention + polish.** Wire `RetentionPolicy` (delete
  audio+transcript on success), startup orphan sweep, onboarding, notifications,
  error/retry UX. *Accept: full happy path; artifacts deleted per settings;
  failure path recovers.*
- **Phase 7 — Hardening + docs.** Long-meeting handling, retries, edge cases,
  README, final `AGENTS.md` pass. *Accept: `bash build.sh test` green; app
  launches and runs a real meeting end-to-end.*

---

## 18. Definition of done (MVP)

- `bash build.sh` produces a launchable `build/Transcriber.app` (swiftc-only).
- `bash build.sh test` passes the full assertion suite.
- A real meeting can be: **named → recorded (mic + system) → stopped →
  transcribed with speakers → summarized → audio + transcript deleted**, leaving
  a searchable, readable summary in the list.
- Preferences let the user set **audio devices**, **summary save location**,
  **backend/model**, and **retention**.
- Menu bar start/stop works; permissions are requested and surfaced clearly.
- Core remains pure and fully unit-tested; no AVFoundation/network in Core.

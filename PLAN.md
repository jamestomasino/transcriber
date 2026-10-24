# Transcriber — Plan

A native macOS app that records a meeting (your mic **and** system audio, so it
captures Zoom / Slack / Teams conversations), then turns that recording into a
**transcript with identified speakers**, writes a **meeting summary**, and keeps
only the **summary** — deleting the audio and the transcript.

> **Current standard — 24 October 2026.** Downloaded Whisper large-v3 Q5_0
> transcription and Qwen 3.5 4B Q4_K_M summaries are the standard path for fresh
> installs. Weights and inference runtimes are not bundled or fetched on launch
> or backend selection: download explicitly in Setup/Settings or on first use,
> then reuse the verified cache offline. Existing saved backend choices remain
> intact; Apple and cloud providers are explicit alternatives. See §24 and
> [docs/LOCAL_MODELS.md](docs/LOCAL_MODELS.md) for the authoritative workflow,
> resource profile and validation limits. Earlier sections preserve design history.
>
> Phases 0–7 and the local model pivot are implemented. The CLT-only build and
> SDK fallback remain required. `bash build.sh test` passes 498 assertions and
> real media, cache, transport and cleanup checks. Live checks exercised local
> Whisper pharma terms and a real recording excerpt; the downloaded summarizer
> recovered a real meeting from its retained transcript. A subsequent complete
> 37-minute recording passed both downloaded stages with saved vocabulary:
> 6,180 transcript words, improved name spellings and a durable new summary.
> This is one observed run, not a ground-truth accuracy evaluation.
> See [Validation/README.md](Validation/README.md).

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

### Original recommendation (superseded by §24)
- **Original default backend: cloud (AssemblyAI or Deepgram) for transcribe+diarize,
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


## 19. Final implementation review

The original sections above preserve the design history. The authoritative
implementation audit is [docs/PLAN_REVIEW.md](docs/PLAN_REVIEW.md). In particular:

- Current first-run defaults are downloaded Whisper transcription and Qwen
  local summaries, language `en`, and `~/Documents/Transcriber` storage (see §24).
  The earlier Apple defaults documented in the original review are alternatives.
  Saved settings and legacy Application Support storage remain unchanged;
  local speaker labeling remains approximate.
- Summary saves precede deletion, and pending cleanup decisions survive a crash.
  Failed cleanup can be retried without repeating provider requests.
- New recording folders use `yyyyMMdd-HHmm-<meeting-id>` in local start time.
  Cleanup supports both dated and legacy ID-only folders.
- Audio devices, source toggles, settings, retention, search, detail actions,
  timers, onboarding, notifications, and toasts are implemented.
- Local long meetings use section summaries; cloud requests retain their
  existing transcript cap and partial-view warning.
- Data-location changes apply on restart and do not migrate existing history.
- Automated assertions and actual media exports pass. Live Speech authorization,
  an authenticated cloud end-to-end run, and distribution credentials are still
  required to finish those environment-dependent acceptance checks.

## 20. Audio-only permission repair — 23 October 2026

System capture now uses a private Core Audio process tap on macOS 14.2+,
with `NSAudioCaptureUsageDescription`. It captures other apps without display
enumeration or screen access. macOS 14.0–14.1 retains the ScreenCaptureKit path.
Prepared audio and original capture files still follow the existing retention path.
Tap I/O stops and drains before files close; the aggregate device and tap are
removed after stop and on failed startup.

Onboarding remembers permission requests across relaunch. Audio-only access is
independent of `CGPreflightScreenCaptureAccess`; setup verifies incoming samples
in memory, with no files. Silence is shown as unverified with retry guidance,
not as permission denial or success. Local ad-hoc signing can invalidate privacy
grants across rebuilds; a certificate identity remains the distribution path.

Validation: the live tap captured audible `afplay` output into the managed
recording and removed the fixture files. The isolated setup preview launched.
The live Speech check was skipped for missing authorization; the separate live
summary check returned `com.apple.SensitiveContentAnalysisML` error 15, so this
run does not establish full transcription-to-summary acceptance.

## 21. Optional local model fallback — 23 October 2026

**Historical proposal: superseded by §§23–24.** At this point the downloaded
models were a contingency, with Apple Speech and Apple Intelligence still the
local defaults. Evaluate their
quality using a real meeting with audio and transcript retention explicitly
enabled, comparing the recording, transcript, and resulting notes before
deciding whether to replace either stage.

- **If transcription loses detail:** evaluate a downloadable local Whisper
  model through [whisper.cpp](https://github.com/ggml-org/whisper.cpp), replacing
  Apple Speech behind the existing `Transcriber` seam. Benchmark complete
  long-meeting coverage, terminology, timestamps, processing time, and memory
  on the target Mac. Whisper performs speech-to-text; it does not generate
  meeting summaries or by itself provide reliable speaker identification.
- **If the transcript is complete but notes lose detail:** evaluate a separate
  downloadable local language model behind `Summarizer`, replacing Apple
  Intelligence. Compare concrete findings, priorities, decisions, owners,
  deadlines, and open questions against the retained transcript. Check both
  omissions and invented details, including details from the middle and end.
- **If both stages fall short:** replace them independently. A Whisper upgrade
  alone does not address poor summarization. Select models and runtimes only
  after measuring quality and resource use; no model choice is committed here.

Any implementation should offer an explicit model download with size and
progress, reuse or extend the existing model cache with integrity checks and
retryable failures, and support offline processing after download. Keep model
assets separate from meeting artifacts. Audio, temporary sections, prepared
mixes, and transcripts must remain under managed retention; opting into a
different model must not change the default deletion policy. Preserve the
CLT-only build, pure Core layer, and injected test seams. Add deterministic
download/pipeline/cleanup checks and validate model quality on retained real
recordings before making a new backend the default.

## 22. Recovery after a local summary failure — 23 October 2026

A real meeting reached Apple Intelligence and failed with
`com.apple.SensitiveContentAnalysisML error 15`; the original recordings remained
available. That error alone does not establish whether the content was rejected
or a model service failed. The app previously attached the transcript only after
summary success, so opting into transcript retention did not preserve completed
transcription when the summarizer failed.

`TranscriptCheckpointingProcessor` now lets the pipeline await a durable
transcript save before invoking the summarizer. The view model writes this
checkpoint only when transcript retention is enabled. A failed meeting with a
retained transcript resumes at summarization on Retry, including after relaunch.
Original audio remains available on failure, and successful retention still
follows the existing policy. Apple Intelligence failures now identify the summary
stage and give retry/backend guidance rather than only exposing a numeric code.

For explicit recovery automation, launching the app with
`--retry-meeting <meeting UUID>` invokes the same guarded retry path as the UI.
Ordinary launches do not automatically retry failed meetings.

Validation: 386 assertions and the real-media checks pass. New checks inspect a
fresh store from inside the summarizer to verify that an opted-in transcript is
already durable, verify that the default does not persist a transcript, and
exercise summary-only retry after a simulated relaunch without retranscription.

The recovered transcript exposed a separate transcription defect: the legacy
URL recognizer returned closing fragments of each audio block. A live fixture
with three sentences separated by silence also returned only its last sentence,
even with partial callbacks and the multi-utterance delegate. Local transcription
on macOS 26+ now uses `SpeechAnalyzer` with `SpeechTranscriber` to consume the
entire file and collect finalized results. This uses installed on-device language
assets; it does not send audio to a service or silently download another model.
Older systems retain the sectioned legacy path, now accumulating hypotheses and
utterances through the full task lifecycle. Pure tests cover revisions, repeated
snapshots, timestamp jitter, and preserving earlier utterances.

An explicit `--retranscribe-meeting <meeting UUID>` recovery invocation ignores
an incomplete retained transcript for processing, while leaving that checkpoint
on disk until a new transcription is successfully saved. Normal Retry continues
to reuse retained transcripts. `--validate-local-speech` runs a synthetic
multi-utterance check inside the app's existing authorization without creating a
fixture meeting or processing a real recording.

Live validation of the modern path preserved all three task details and deadlines
in the separated-sentence fixture. Reprocessing the retained 37-minute recording
then recovered approximately 6,010 words versus 1,273 from the legacy recognizer,
with coverage through the meeting's closing speech. This verifies the substantial
transcription repair; the independent Apple Intelligence summary failure remains
a separate failure: the subsequent real summary attempt again returned a generic
`FoundationModels.LanguageModelError` code -1, with the fuller transcript safely
retained. A passing synthetic summary fixture does not establish reliability on
real meetings. At that point the independent local summarizer in §21 was still
a contingency; §23 records its implementation and §24 makes it standard.

## 23. Downloaded local model pivot — 23 October 2026

The optional fallback in §21 is now authorized and implemented. Fresh installs
select Whisper large-v3 Q5_0 for transcription and Qwen 3.5 4B Q4_K_M for
summarization. Explicit saved backend choices are preserved; the user's selected
pivot is applied through normal settings. Large-v3 Turbo Q5_0 is available as a
smaller transcription option. A short vocabulary field conditions Whisper on
relevant pharma terms without claiming a domain-specific fine-tune.

The 4B summary profile targets recent Macs with at least 8 GB memory; 16 GB gives
additional application headroom. Context, generation and prefill batches are
bounded. Models from concurrent meetings run in a serial inference queue and
release their weights between transcription and summary. A larger summary model
is not auto-selected from physical memory alone. See [the model profile and
measurements](docs/LOCAL_MODELS.md) for exact asset sizes and limits.

The app downloads and caches pinned upstream runtimes and model revisions with
exact-size and SHA-256 validation, atomic cache replacement, progress and
URLSession resume data. Runtime source compilation is not introduced: the CLT
build still invokes swiftc, importing pinned C declarations and dynamically
loading the verified Whisper framework. The summary subprocess uses a private
Unix socket, schema-constrained JSON, no enabled tools or web UI, no prompt logs,
and an EOF lifetime guard. Audio is decoded into bounded PCM buffers without a
new on-disk WAV; all existing summary, checkpoint and retention rules apply.

Settings and onboarding expose downloads and sizes. Failed meetings distinguish
Retry summary from Transcribe again. Isolated UI fixtures disable downloads;
asset and transport tests inject temporary roots and fake downloaders. Live
checks cover synthetic pharma terms and a real retained meeting excerpt; these
are separate from the deterministic harness and do not establish clinical-domain
accuracy across all meetings. Apple Speech and Apple Intelligence remain explicit
alternatives, alongside the existing cloud providers.

Acceptance: the 394-assertion harness and real-media checks pass, including model
integrity repair, shared-download cancellation, serialized inference cancellation,
private HTTP socket framing, and child cleanup on EOF. Whisper Large v3 retained
three synthetic pharma terms/deadlines and transcribed a real recording excerpt.
The local 4B summarizer passed the grounded fixture and recovered the real meeting
summary with 41 key points and 10 actions from its retained transcript. Runtime
idle prompt RAM caching and context checkpoints are disabled; the final cached
fixture completed in 52 seconds on the 8 GB A18 Pro machine. The app uses the new
local backends and preserves the user's opted-in audio/transcript retention.

## 24. Standard local workflow — 24 October 2026

The downloaded model path is the product standard going forward, not a backup:
Whisper large-v3 Q5_0 transcription, then Qwen 3.5 4B Q4_K_M summarization. Fresh
settings already select these backends. Preserve explicit saved selections;
Apple Speech, Apple Intelligence and cloud providers remain optional alternatives.

Distribute the application without model weights or inference runtime binaries.
Fetch selected assets only through an explicit Setup/Settings download or the
first processing task that needs them. App launch and backend selection alone
do not initiate downloads. Verify pinned revisions, sizes and SHA-256 hashes,
cache separately from meeting artifacts, and reuse the cache offline. Keep the
CLT-only build independent of downloads and inference runtime compilation.

Run one inference job at a time, process all meeting sections within bounded
memory, and preserve the durable-summary-before-deletion contract. The standard
8 GB minimum / 16 GB headroom profile, measured limits, terminology hints,
private helper lifecycle and acceptance coverage are maintained in
[docs/LOCAL_MODELS.md](docs/LOCAL_MODELS.md). New changes should follow that
reference and AGENTS.md rather than the superseded default recommendations.

## 25. Local vocabulary — 24 October 2026

Settings has a dedicated Local vocabulary section for canonical names,
organizations, products, projects and acronyms. Save one name per line (comma/semicolon lists
also work) in the existing local `transcriptionVocabulary` setting. Preserve
existing hints and do not populate the user's list from meeting content.

Whisper receives normalized, case-insensitively deduplicated names in saved
order, within the existing 1,000-character hint budget. Keep whole terms; show
saved/included counts and warn when terms do not fit. These hints guide future
transcription and explicit retranscription of retained audio. They are not
automatic replacements and do not modify saved transcripts or summary retries.
Other transcription backends preserve the setting but do not consume it.

An explicit **Transcribe again** also works on completed meetings with retained
audio, rerunning both stages with current settings. Ordinary retry does not
restart completed meetings, and completed meetings without source audio stay
unchanged. Keep the old result until replacement stages succeed.

## 26. Acoustic speaker matching — 24 October 2026

Replace the production local pause-grouping heuristic with downloaded speaker
segmentation and voice embeddings using sherpa-onnx. A pause is not evidence of
a new identity. Keep model/runtime downloads pinned and cached, serialize the
stage with other local inference, and retain the CLT-only build.

Speaker labels are meeting-local voice clusters, not cross-meeting profiles or
participant names. Persist attribution provenance; legacy guessed counts are
unverified. Infer the count automatically without manual count controls or a
speaker-repair button. An internal diagnostic rerun can reuse retained audio
and transcript, preserving text, timing and summary. Ignore legacy count hints. Keep
temporary WAVs in the managed retention path and always remove them. See the
local-model profile for resource bounds, model sources and validation limits.

## 27. Discoverable summary models — 24 October 2026

Add an explicit Settings check for trusted Qwen GGUF releases, immutable model
metadata and a cached catalog. Recommend estimated fits using memory headroom,
architecture support, parameter balance and version; never automatically replace
the selected model or claim general accuracy from release recency.

Download & switch verifies and runs a synthetic local notes check, durably saves
the descriptor/selection, then deletes only the previous summary weights. Failed
or cancelled preparation/settings saves keep the working model. Serialize with
inference, guard recording/processing and stale settings at activation, preserve
the last downloaded selection across provider changes, and keep offline model
resolution independent of the latest server catalog. New architectures may need
a runtime/app update. Speech and speaker assets remain separately pinned.

## 28. Transcript cleanup before summarization — 24 October 2026

Deduplicate confirmed same-speaker replay at overlapping audio boundaries, then
assemble readable paragraphs for summarization, display and copying. Preserve
fine-grained timed segments in transcript checkpoints for acoustic relabeling.
Use timing/section provenance and exact word evidence; never globally remove
repeated sentences or use fuzzy edits to names, numbers, units or negation.
Unknown voices and changed speakers remain separate. Pause/length limits split
long turns into readable blocks, without truncating content.

Whisper retains boundary alternatives until cleanup can compare words instead
of discarding all fully covered timestamps. Retained summary retries also pass
through cleanup. Existing summaries are not regenerated by display formatting,
and internal speaker-only diagnostics still preserve their saved text/timings.


## 29. Separate meeting content files (current storage layout)

The configured data root contains `meetings.json` and its `.bak` as metadata
indexes only. Each meeting uses the existing recording stem,
`yyyyMMdd-HHmm-UUID`, reused from its recording folder when available and then
persisted to keep names stable across title/timezone changes:

- `summaries/<stem>.md`: readable summary, including the meeting title.
- `summaries/<stem>.json`: structured summary and revision identity.
- `transcripts/<stem>.txt`: readable speaker paragraphs when retained/pending processing.
- `transcripts/<stem>.json`: timed segments and revision identity.
- `recordings/<stem>/`: unchanged source audio layout.

Content JSON has a previous-revision `.bak` so the metadata backup can resolve
its referenced content. All content writes finish before the metadata index is
committed. Failed writes restore earlier content. Legacy inline libraries migrate
on load, preserving content and audio; both indexes become metadata-only only
after the separate files are durable. A failed migration leaves the legacy index
intact and pauses automatic cleanup. Missing content preserves the meeting’s
metadata and references and also pauses cleanup.

Default retention removes transcript text, timed JSON and their backups only
after the summary and cleanup decision are saved. Summary files remain. Explicit
Delete journals its intent before removing all content and audio, then sanitizes
both metadata indexes. An interrupted deletion resumes at startup. Tests use
isolated temporary roots and the in-memory store never creates files.

Validation: `bash build.sh test` passed 498 assertions plus real media/cache/
transport/cleanup checks. Normal app relaunch migrated the existing retained
meeting; its structured summary and all 655 timed segments compared equal to
the pre-migration library, both audio file sizes were unchanged, and both
metadata indexes contained no summary/transcript bodies.

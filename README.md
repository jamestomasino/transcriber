# Transcriber

A native macOS app that records a meeting — your **microphone and the system
audio** from Zoom, Slack, or Teams — turns it into a **transcript with
identified speakers**, writes a **structured summary**, and then **deletes the
audio and the transcript, keeping only the summary.**

The summary is the only thing that sticks around. That's the point.

```
  ┌─────────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────────┐
  │  Record     │ → │  Transcribe  │ → │  Summarize   │ → │  Keep summary,   │
  │ mic + system│   │ + speakers   │   │ structured   │   │  delete the rest │
  └─────────────┘   └──────────────┘   └──────────────┘   └──────────────────┘
        Start ▸ meeting ▸ Stop ▸ (runs automatically) ▸ "Summary ready"
```

---

## What you get

- **One-tap meetings.** Start and stop a recording (optionally with a name) from
  the main window or the **menu bar** — no need to focus the app.
- **Both sides of the call.** Microphone *and* system audio are recorded as
  separate tracks, then mixed with their start offsets for transcription.
  Cloud-bound audio is compressed before upload. Temporary mixes are removed
  after transcription, including when it fails.
- **Speaker labels.** Deepgram separates voices into Speaker 1, Speaker 2, ….
  Local speech uses downloaded acoustic models to match returning voices.
  Labels remain estimates; the app does not identify participants by name.
- **A structured summary.** Overall, key points, decisions, and action items —
  not a wall of text.
- **Transcript cleanup.** Consecutive speech from one speaker reads as
  paragraphs. Replayed phrases at overlapping audio boundaries are removed
  before summarization, while ordinary spoken repetition is preserved.
- **Local by default.** Fresh installs use Whisper Large v3 for transcription
  and a quantized Qwen 3.5 4B model for summaries. Download about 4.2 GB once,
  then process meetings offline without an account or API key. Saved backend
  choices are preserved. The initial language code is `en`.
- **Local vocabulary.** Save names, organizations, products, projects and
  acronyms in Settings to help Whisper recognize terminology in your meetings.
  Large v3 prioritizes accuracy; Turbo offers a smaller, faster option.
- **Local model updates.** Check available Qwen summary models in Settings.
  Fit estimates help you choose for this Mac; switching verifies and tests the
  replacement before saving the selection and deleting the previous weights.
- **Cloud when you want it.** Swap in Deepgram (best speaker ID) or
  OpenAI / Anthropic (stronger summaries) with a key — or mix and match per
  stage.
- **It remembers the summary.** Meetings survive a relaunch. A meeting that was
  mid-flight when you quit the app comes back as **retryable**, not lost.
- **A notification when it's done.** A macOS banner — "Summary ready: …" on
  success, the failure reason on error — so a meeting started from the menu bar
  doesn't finish silently.

---

## Requirements

- **macOS 14 or later** (Apple Silicon or Intel).
- **Microphone access** — use Allow in onboarding, or macOS asks on your first recording.
- **System Audio Recording access** — needed to capture other apps on macOS 14.2+.
  Use Allow in Setup and permissions; no screen or video is captured. macOS
  14.0–14.1 uses Screen Recording access instead. Neither is needed for mic-only recording.
- **8 GB memory or more** for the downloaded local summary model; 16 GB gives
  more headroom for other apps. Model downloads need about 4.2 GB of storage.
- **Speech Recognition permission** is needed only when selecting Apple Speech.
  Whisper does not use Apple's Speech service.
- **Alternative summary backends:** Apple Intelligence needs macOS 26+ and its
  system models enabled. OpenAI and Anthropic require a Keychain-stored API key.

See [local models](docs/LOCAL_MODELS.md) for pinned assets, resource limits,
terminology hints and validation coverage.

---

## Getting started

Build and run from the terminal (the build needs the Command Line Tools only —
no full Xcode required):

```bash
bash build.sh              # → build/Transcriber.app
open build/Transcriber.app
```

Then, in the app:

1. **Download the selected local models** in Setup or Settings (⌘,). The default
   Whisper and 4B summary models need about 4.2 GB including runtimes. Downloads
   show progress, validate checksums, and can resume after interruptions. Missing
   models also download on first use. Apple and cloud alternatives remain in the
   backend pickers; cloud API keys are stored in Keychain.
2. **Start a meeting.** Give it a name (optional) and hit **Start**. A level
   meter and a permission/capture status card show what's being recorded.
3. **Stop when you're done.** Transcription and summarization run automatically
   in the background.
4. **Read the summary.** A notification tells you it's ready; select the meeting
   to open its **detail pane** with the full structured summary, and **Retry**,
   **Copy**, or **Delete** it.

Model weights and inference runtimes are **not included in the app bundle**.
Launching the app or selecting a local backend does not start a download. Assets
are fetched when you request them in Setup/Settings or first process a meeting
with the selected backend, then reused from the local cache. This is the standard
workflow; Apple and cloud providers are optional alternatives.

That's the whole loop. Everything else is optional tuning.

---

## Backends

Transcription and summarization are **independent** — pick any combination.

| Stage        | Option        | Runs where      | Needs a key? | Notes                                   |
| ------------ | ------------- | --------------- | ------------ | --------------------------------------- |
| **Transcribe** | **Whisper** | On your Mac | No | Default: Large v3 Q5. Download once. Approximate speaker labels. |
| **Transcribe** | **Apple Speech** | On your Mac | No | Alternative; modern SpeechAnalyzer on macOS 26+. |
| **Transcribe** | **Deepgram** | Cloud | Yes | Nova with native speaker diarization. |
| **Summarize** | **Downloaded local model** | On your Mac | No | Default: Qwen 3.5 4B Q4. Bounded context, complete meeting sections. |
| **Summarize** | **Apple Intelligence** | On your Mac | No | Alternative, macOS 26+. |
| **Summarize** | **OpenAI** | Cloud | Yes | Default: `gpt-4o-mini`. |
| **Summarize** | **Anthropic** | Cloud | Yes | Default: `claude-haiku-4-5`. |

**Fully local:** Whisper + the downloaded local summarizer need network access
only for public model/runtime downloads. Audio and transcript inference stays on
the Mac. The summary helper uses a private Unix socket and exits after each job.
Models from concurrent meetings are queued to keep memory use bounded.

**Best quality:** Deepgram transcriber + your preferred LLM for the summary.

API keys are stored in the **macOS Keychain** (via `Keychain.set`), never in
`settings.json` or any plain-text file, and the UI shows a "stored" indicator
rather than echoing the secret back.

---

## Privacy & where your data lives

- **The summary is the only durable artifact.** By default, right after the
  summary is written, Transcriber **deletes the audio and the transcript** and
  removes the per-meeting recording folder. A startup sweep clears any recording
  directory that outlived its meeting within the managed data folder.
- **Opt in to keep more** if you want to: Settings → *Storage* → "Keep
  transcript after summary" / "Keep audio after summary."
- **Your summaries persist** in individual dated Markdown files under `summaries/`,
  with structured JSON sidecars. Retained transcripts live under `transcripts/`
  as readable text plus JSON with speaker timings. All use the recordings’
  `yyyyMMdd-HHmm-UUID` naming convention. `meetings.json` indexes metadata and file
  references only, with a previous-generation backup. Existing libraries migrate
  automatically on launch; a failed migration preserves the original library.
- **Choose where data goes** in Settings → *Storage* → **Data location**. The
  first-run default is `~/Documents/Transcriber`; pick a folder or
  **Reset** to return to the default. Restart to use the chosen location.
  The app creates the selected folder automatically on startup if needed.
  Meeting audio lives in `recordings/yyyyMMdd-HHmm-<meeting-id>/`, using the
  local meeting start time so folders sort by date. The ID keeps meetings
  started in the same minute distinct. Existing ID-only folders remain supported.
  Existing meetings stay in their original folder; this does not migrate them.
  Existing installations using Application Support keep that location until
  you choose another folder or Reset. Preferences stay in Application Support.
- **Cloud backends send audio / transcript to that provider** (Deepgram, OpenAI,
  or Anthropic) to do their job. Downloaded local backends request only public
  model/runtime assets; they never upload meeting audio or transcripts.

---

## Settings (⌘,)

Everything is configurable and saved immediately. Changing a backend or model
takes effect on the **next meeting** or retry — no relaunch needed. Switching
summary providers selects a compatible model; you can then enter a custom model.

| Section        | What you can set                                                        |
| -------------- | ----------------------------------------------------------------------- |
| **Audio**      | Capture microphone / system audio; microphone device picker.          |
| **Storage**    | Keep transcript / keep audio after summary; **Data location** picker.  |
| **Transcription** | Backend, Whisper size, language, and Deepgram key.     |
| **Local vocabulary** | Saved names, organizations, products, projects and acronyms, one per line; reused as Whisper hints. |
| **Summary**    | Local model discovery, fit recommendations, verified replacement; Apple/cloud alternatives and provider keys. |
| **General**    | Show toasts; notify when a summary is ready.                           |

---

## Troubleshooting

**"I stopped the meeting but there's no summary."**
Read the saved failure reason in the meeting detail. Download the selected
models in Settings if needed, or configure the chosen cloud provider's key.
If Apple Intelligence fails, select the downloaded local summary model and
choose **Retry summary**. An opted-in transcript is saved before summarization,
so a summary failure does not discard completed transcription.

**"It captured my voice but not the other side."**
Open **Setup and permissions → System Audio Recording → Allow**. On macOS
14.2+, the app uses an audio-only Core Audio tap; screen recording access is
not required. In System Settings → Privacy & Security → Screen & System Audio
Recording, enable Transcriber’s audio access. Quit and reopen the same app if
macOS asks. Play sound in another app and click **Check audio again**; a green
check means actual system audio was received. Silence alone cannot distinguish
an idle app from missing permission. macOS 14.0–14.1 still uses Screen Recording.

Local builds are ad-hoc signed by default. Rebuilding changes their code identity
and can invalidate macOS privacy grants even when the Settings toggle stays on.
Grant access to the current app copy; for a consistent identity across builds,
set `TRANSCRIBER_SIGN_IDENTITY` to a code-signing certificate (see
[distribution](docs/DISTRIBUTION.md)).

**"The Local summary option is greyed out / errors with 'use OpenAI or Anthropic'."**
The on-device summarizer requires **macOS 26+ with Apple Intelligence enabled**.
On older systems, use OpenAI or Anthropic for the summary (transcription can
still be fully local).

**"A meeting shows as failed."**
Open it and hit **Retry summary** to reuse a saved transcript, or **Transcribe
again** to run your selected speech backend on the retained recording. Meetings
without a saved transcript offer **Retry** for the whole pipeline.
Transient network and rate-limit failures are retried automatically; a persistent
one (e.g. a bad key) shows its reason, including after relaunch. You can cancel
processing without deleting the source audio. Cleanup retries reuse a saved
summary instead of calling the providers again.

**"My summary says it's a partial view."**
A model request needed a shorter transcript, keeping its opening and closing.
Cloud summaries cap very long transcripts. Local summaries normally process
all sections in separate requests and combine the results; unusually dense
text may still need a smaller per-request cap. The full transcript remains
available if you enabled "Keep transcript."

---

## Development

```bash
bash build.sh          # build the app
bash build.sh test     # build + run Core assertions and real media checks
```

See [Validation/README.md](Validation/README.md) for isolated UI fixtures and
optional live capture / local model checks. [The plan review](docs/PLAN_REVIEW.md)
records the final implementation audit and remaining environment-dependent
acceptance checks.

The build uses `swiftc` only (no Xcode, no SwiftPM at build time). If your
Command Line Tools SDK can't compile SwiftUI's `@State` / `@Observable` macros,
`build.sh` automatically falls back to an older installed SDK — that's expected,
not a failure.

**Layout**

```
Sources/Core/   Pure, AppKit-free core (Foundation only): the model, engine,
                view model, the transcribe → diarize → summarize pipeline,
                settings, retention, persistence, the summary parser, and the
                pluggable backends. Fully unit-testable.
Sources/App/    The SwiftUI/AppKit shell (window, menu bar, detail pane,
                settings) plus the platform pieces Core stays pure of: real
                audio capture (Core Audio taps, with a ScreenCaptureKit fallback),
                Whisper, the private local summary runtime, verified asset downloads,
                optional Apple/cloud processing, Keychain, and notifications.
Sources/CWhisper/ Pinned upstream C ABI declarations and license; no model weights
                or compiled inference runtime.
Tests/          Custom assertion-based test harness (no XCTest).
build.sh        swiftc-only build (app + tests), with SDK fallback.
PLAN.md         Full design, architecture, roadmap, and open decisions.
docs/           Standard local model profile, validation and distribution runbooks.
```

**Design principle:** the tricky logic (retention, retry, summarization
decisions, notification policy) lives in Core as pure, deterministic functions
that return *decisions*; the App layer performs the I/O. That keeps the product
promises testable without a Mac, a network, or a key.

---

## More

- [PLAN.md](PLAN.md) — architecture, phased roadmap, and the product decisions
  behind each choice.
- [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) — how to sign, notarize, and
  ship the app to other Macs (Developer ID, GitHub Actions).

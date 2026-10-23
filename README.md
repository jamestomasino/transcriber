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
  Local speech uses approximate labels based on pauses; it cannot reliably
  identify different people.
- **A structured summary.** Overall, key points, decisions, and action items —
  not a wall of text.
- **A fully local option.** Choose Local transcription (Apple Speech) and Local
  summarization (Apple Intelligence) to keep the whole pipeline on your Mac.
  No account or API key. Local transcription is the default; summaries default
  to OpenAI until you change the backend in Settings.
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
- **Microphone access** — macOS asks on your first recording.
- **Screen Recording access** — needed to capture *system* audio
  (System Settings → Privacy & Security → Screen Recording). Not needed if you
  only want your own microphone.
- **Speech Recognition** (for on-device transcription) —
  System Settings → Privacy & Security → Speech Recognition.
- **A summarization backend** — one of:
  - **Local** (on-device Apple Intelligence): nothing else required, **but**
    needs **macOS 26+** with Apple Intelligence enabled, or
  - **OpenAI** or **Anthropic**: an API key (stored in your macOS Keychain).

> **The one decision that matters most:** the app ships with a **local
> transcriber** (no key needed) but an **OpenAI summarizer** (needs a key) as
> the default. So out of the box you'll either add an OpenAI key, or switch the
> summary backend to **Local** for a fully offline setup. See [Backends](#backends)
> and [Getting started](#getting-started).

---

## Getting started

Build and run from the terminal (the build needs the Command Line Tools only —
no full Xcode required):

```bash
bash build.sh              # → build/Transcriber.app
open build/Transcriber.app
```

Then, in the app:

1. **Pick a summary backend** in Settings (⌘,):
   - **Local** — fully offline. Choose this if you're on macOS 26+ and don't
     want to sign up for anything. No key, no network.
   - **OpenAI** or **Anthropic** — enter your API key under *Summary*. It's
     saved to the macOS Keychain, never written to a file.
2. **Start a meeting.** Give it a name (optional) and hit **Start**. A level
   meter and a permission/capture status card show what's being recorded.
3. **Stop when you're done.** Transcription and summarization run automatically
   in the background.
4. **Read the summary.** A notification tells you it's ready; select the meeting
   to open its **detail pane** with the full structured summary, and **Retry**,
   **Copy**, or **Delete** it.

That's the whole loop. Everything else is optional tuning.

---

## Backends

Transcription and summarization are **independent** — pick any combination.

| Stage        | Option        | Runs where      | Needs a key? | Notes                                   |
| ------------ | ------------- | --------------- | ------------ | --------------------------------------- |
| **Transcribe** | **Local**   | On your Mac     | No           | Apple Speech. Private, offline. Default. |
| **Transcribe** | **Deepgram**| Cloud          | Yes (Deepgram) | Nova with native diarization — the most accurate speaker IDs. |
| **Summarize**  | **Local**   | On your Mac     | No           | Apple Intelligence. Offline. **macOS 26+.** |
| **Summarize**  | **OpenAI**  | Cloud           | Yes (OpenAI) | Any chat model (default: `gpt-4o-mini`). |
| **Summarize**  | **Anthropic** | Cloud          | Yes (Anthropic) | Any Claude model.                        |

**Fully local (recommended for privacy):** Local transcriber + Local summarizer
= the entire app runs on your machine. No account, no key, no network. On
macOS 26+ this is the best default; on older systems the Local summarizer is
unavailable, so use OpenAI or Anthropic for the summary.

**Best quality:** Deepgram transcriber + your preferred LLM for the summary.

API keys are stored in the **macOS Keychain** (via `Keychain.set`), never in
`settings.json` or any plain-text file, and the UI shows a "stored" indicator
rather than echoing the secret back.

---

## Privacy & where your data lives

- **The summary is the only durable artifact.** By default, right after the
  summary is written, Transcriber **deletes the audio and the transcript** and
  removes the per-meeting recording folder. A startup sweep clears any recording
  directory that outlived its meeting, so nothing leaks into your Application
  Support folder.
- **Opt in to keep more** if you want to: Settings → *Storage* → "Keep
  transcript after summary" / "Keep audio after summary."
- **Your summaries persist** to `meetings.json` (with a one-generation backup
  and a corrupt-file fallback), so they survive a relaunch.
- **Choose where data goes** in Settings → *Storage* → **Data location**. The
  default is `~/Library/Application Support/Transcriber`; pick a folder or
  **Reset** to return to the default. Restart to use the chosen location.
  Existing meetings stay in their original folder; this does not migrate them.
- **Cloud backends send audio / transcript to that provider** (Deepgram, OpenAI,
  or Anthropic) to do their job. Local backends send nothing anywhere.

---

## Settings (⌘,)

Everything is configurable and saved immediately. Changing a backend or model
takes effect on the **next meeting** or retry — no relaunch needed. Switching
summary providers selects a compatible model; you can then enter a custom model.

| Section        | What you can set                                                        |
| -------------- | ----------------------------------------------------------------------- |
| **Audio**      | Capture microphone / system audio; microphone device picker.          |
| **Storage**    | Keep transcript / keep audio after summary; **Data location** picker.  |
| **Transcription** | Backend (Local / Deepgram), language code, and the Deepgram key.     |
| **Summary**    | Backend (Local / OpenAI / Anthropic), model, and the provider key.     |
| **General**    | Show toasts; notify when a summary is ready.                           |

---

## Troubleshooting

**"I stopped the meeting but there's no summary."**
You likely have the OpenAI/Anthropic summarizer selected without a key. Add the
key in Settings, or switch the summary backend to **Local** (macOS 26+) and
retry the meeting from its detail pane.

**"It captured my voice but not the other side."**
System audio needs **Screen Recording** permission. Grant it in System Settings
→ Privacy & Security → Screen Recording, then start a new meeting.

**"The Local summary option is greyed out / errors with 'use OpenAI or Anthropic'."**
The on-device summarizer requires **macOS 26+ with Apple Intelligence enabled**.
On older systems, use OpenAI or Anthropic for the summary (transcription can
still be fully local).

**"A meeting shows as failed."**
Open it and hit **Retry** — it re-runs with your current backend and key.
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
                audio capture (ScreenCaptureKit), on-device Speech,
                on-device summarization (FoundationModels), URLSession + retry,
                Keychain-backed keys, and notifications.
Tests/          Custom assertion-based test harness (no XCTest).
build.sh        swiftc-only build (app + tests), with SDK fallback.
PLAN.md         Full design, architecture, roadmap, and open decisions.
docs/           Distribution runbook (signing, notarization, CI).
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

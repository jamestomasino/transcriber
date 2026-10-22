# Transcriber

A native macOS app that records a meeting (your microphone and the system audio
from Zoom / Slack / Teams), transcribes it with speaker identification, generates
a structured summary, and then **deletes the audio and the raw transcript,
keeping only the summary.**

> **Status:** Phase 6 (Settings UI + menu bar + detail view) in progress. The
> build, test harness, pure core model + engine, the mic + system-audio capture
> path, the **transcribe → diarize → summarize → retention** pipeline,
> **durable persistence**, a **settings window**, a **menu-bar item**, and a
> **meeting detail pane** are in place and green (186 tests, including
> integration tests that drive the real pipeline → real store → the copyable
> text the detail pane shows, across the default-retention, retry, and
> transcript-kept paths).
> Transcription is pluggable — **local Apple Speech** (private, on-device, no
> key) by default, or **Deepgram** for accurate speaker ID — and summarization
> runs on **OpenAI** or **Anthropic**. A download-on-demand model store is in
> place for local-model backends. A live level meter and a permission / capture
> status card are wired into the UI. Meeting summaries **survive a relaunch**
> (`MeetingStore` → `meetings.json`), which is the product's core promise: the
> summary is the only durable artifact. Backends, models, retention, and API
> keys are now **user-configurable in the Settings window** (⌘,) — and because
> the pipeline is rebuilt from the *current* settings at run time, switching
> backend or model takes effect on the next meeting without a relaunch. Select
> a meeting to read its **full structured summary** (overall, key points,
> decisions, action items), the **retained transcript** (when you opted to
> keep it), and to **retry** a failed meeting, **copy** the summary/transcript,
> or **delete** it. See [PLAN.md](PLAN.md).

## Features

- Start / stop meeting recording, with an optional meeting name.
- Capture the microphone and the system audio simultaneously.
- Transcribe with speaker identification (diarization).
- Generate a structured summary: overall, key points, decisions, action items.
- Save only the summary; delete the audio and transcript by default
  (`RetentionPolicy`; opt-in "keep transcript / keep audio" flags on `AppSettings`).
- The summary is **durable**: meetings persist to `meetings.json` across
  relaunches (`MeetingStore`). A meeting that was mid-flight (recording or
  processing) when the app quit is reconciled to a retryable `.failed` state on
  next launch.
- Pluggable transcription + summarization backends (see Backends below).
- A **Settings window** (Transcriber ▸ Settings, ⌘,) to configure capture
  sources, retention, the transcription/summary backends, models, and language,
  and to enter/clear API keys. Every change is persisted to `settings.json`
  immediately (API keys go to the Keychain, never to disk in plain text).
- **Live backend switching**: the pipeline is rebuilt from the *current*
  settings at run time, so changing backend or model in Settings takes effect
  on the next meeting without a relaunch.
- A **menu-bar item** with a live Start / Stop, so a meeting can be started or
  stopped without the main window focused.
- A **meeting detail pane**: select any meeting to read its full structured
  summary (overall, key points, decisions, action items) and the retained
  transcript (when you opted to keep it). A failed meeting shows its error and
  a **Retry** button (it re-runs with the current backend + key); you can also
  **copy** the summary or transcript to the clipboard, or **delete** the
  meeting. The copyable text is produced by pure Core helpers
  (`summaryText()` / `transcriptText()`), so the on-screen view and the
  clipboard share one deterministic source.

## Backends

Transcription and summarization are **pluggable**, selected via `AppSettings`
and configurable in the **Settings window** (⌘,). Defaults are local + OpenAI:

| Stage        | Backend            | Notes                                                        |
| ------------ | ------------------ | ------------------------------------------------------------ |
| Transcribe   | **Apple Speech**   | On-device, private, no API key, no network. Default.         |
| Transcribe   | **Deepgram**       | Nova-2 with diarization; accurate speaker ID. Needs a key.   |
| Summarize    | **OpenAI**         | Any chat model. Needs a key.                                 |
| Summarize    | **Anthropic**      | Any Claude model. Needs a key.                               |

API keys are stored in the macOS Keychain (never in settings or on disk in
plain text). The download-on-demand model store (`ModelStore` + a Whisper
catalog) is in place for backends that need a local model; the current local
path uses Apple's on-device Speech and downloads nothing.

## Requirements

- macOS 14+ (Apple Silicon or Intel), built with the **Command Line Tools only**
  (no full Xcode required).
- Microphone access (granted on first recording) and, for the local path,
  Speech Recognition (System Settings → Privacy & Security).
- A summarization backend: an OpenAI or Anthropic API key (stored in the
  Keychain via `Keychain.set`). A Deepgram key is optional, only for the
  cloud transcription backend.
- No network or account is required for the default path (local Speech +
  a backend key for summarization). Meeting summaries persist to
  `~/Library/Application Support/Transcriber/meetings.json` (with a
  `meetings.json.bak` backup of the prior generation, plus a corrupt-file
  fallback, so the summary — the only durable artifact — is recoverable).

## Build & run

```bash
bash build.sh          # build build/Transcriber.app
bash build.sh test     # build the app + run the test suite
open build/Transcriber.app
```

The build uses `swiftc` only. If your Command Line Tools SDK can't compile
SwiftUI's `@State`/`@Observable` macros, `build.sh` automatically falls back to
an older installed SDK — this is expected and not a failure.

## Project layout

```
Sources/Core/   Pure, AppKit-free core (Foundation only): model, engine, view
                model, pipeline (transcribe → diarize → summarize), settings,
                retention, persistence (MeetingStore → meetings.json), model
                store, summary parser, and the pluggable LLM / Deepgram
                backends. Fully unit-testable.
Sources/App/    SwiftUI/AppKit shell (window + menu bar + meeting detail pane),
                plus the platform pieces that Core stays pure of: real audio
                capture (AVFoundation), local Speech transcription, the
                URLSession HTTP + model downloaders, Keychain-backed API keys,
                and the processor factory.
Tests/          Custom assertion-based test harness (no XCTest)
build.sh        swiftc-only build (app + tests), with SDK fallback
PLAN.md         Full design, architecture, roadmap, and open decisions
```

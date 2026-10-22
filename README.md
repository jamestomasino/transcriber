# Transcriber

A native macOS app that records a meeting (your microphone and the system audio
from Zoom / Slack / Teams), transcribes it with speaker identification, generates
a structured summary, and then **deletes the audio and the raw transcript,
keeping only the summary.**

> **Status:** early scaffold (Phase 0). The build, test harness, and the pure
> core model + engine are in place and green. Recording, transcription,
> summarization, and the full UI land in later phases — see [PLAN.md](PLAN.md).

## Features (target)

- Start / stop meeting recording, with an optional meeting name.
- Capture the microphone and the system audio simultaneously.
- Transcribe with speaker identification (diarization).
- Generate a structured summary: overall, key points, decisions, action items.
- Save only the summary; delete the audio and transcript by default.
- Preferences: choose audio input/output devices and where summaries are saved.

## Requirements

- macOS 14+ (Apple Silicon or Intel), built with the **Command Line Tools only**
  (no full Xcode required).
- Microphone access (granted on first recording).
- A transcription/summarization backend (cloud API key, or local Speech) —
  configured in a later phase.

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
Sources/Core/   Pure, AppKit-free core: model, engine, view model (testable)
Sources/App/    SwiftUI/AppKit shell (window + menu bar)
Tests/          Custom assertion-based test harness (no XCTest)
build.sh        swiftc-only build (app + tests), with SDK fallback
PLAN.md         Full design, architecture, roadmap, and open decisions
```

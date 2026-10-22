# AGENTS.md

Guidance for agents (and humans) working in this repo.

## Build — the one gotcha to know

- Build with `bash build.sh` (app) or `bash build.sh test` (app + test suite).
  Both use `swiftc` only; **full Xcode is not required and is not assumed.**
- If the build prints `external macro implementation type 'SwiftUIMacros.StateMacro'
  could not be found`, that is **expected on some machines, not a regression**.
  Recent Command Line Tools SDKs (e.g. 27.0) declare SwiftUI `@State`/`@Observable`
  as external macros backed by a `SwiftUIMacros` plugin that is not always
  installed. `build.sh` already detects this and falls back to an older installed
  SDK (e.g. 26.5) that compiles the same code. Do **not** "fix" this by removing
  the fallback, pinning the SDK, or rewriting the SwiftUI views.
- The test suite is a **custom assertion harness** (`Tests/main.swift`), not
  XCTest. `swift run TranscriberTests` (SwiftPM) runs the same harness.

## Hard constraints (do not regress)

- **CLT-only build must keep working.** The `swiftc` path is a stated requirement,
  not a convenience. Keep `build.sh` self-contained and Xcode-free.
- **Keep the Core layer pure.** `MeetingEngine` and the Core module avoid
  SwiftUI, AppKit, AVFoundation, `Speech`, and the network so the tricky logic
  stays deterministic and testable. Platform detail (recording, transcription,
  summary, retention) stays in the App layer or behind injected closures.
- **Retention is a product promise.** The app records audio, transcribes,
  summarizes, then deletes the audio + transcript by default, keeping only the
  summary. Any code that writes audio or transcripts to disk must go through the
  retention path so it is actually cleaned up. Do not leak files to the user's
  home directory or to unmanaged locations.

## Conventions

- Persistence layers (to be added) should be small and swappable; the view model
  never touches the file system directly. Keep an `inMemory()` seam for tests so
  the test suite never reads/writes the user's real files.
- Prefer fixing problems over surfacing them; validate end-to-end (the app should
  actually launch and run, not just compile and pass tests).
- Read `PLAN.md` before making non-trivial changes — it records the intended
  architecture, the phased roadmap, and the open product decisions.

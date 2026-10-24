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

## Standard processing path

- Fresh installs use **Whisper large-v3 Q5_0** for transcription and
  **Qwen 3.5 4B Q4_K_M** for summaries. Apple and cloud backends are explicit
  alternatives; preserve saved user selections and do not silently fall back
  to a different provider.
- **Weights and inference runtimes are not bundled.** Download the selected
  assets only when the user requests setup/downloads or first processes a
  meeting with that backend. Launching the app or changing a backend alone
  must not trigger a download. Reuse the verified cache for offline inference.
- Keep model revisions, exact sizes, runtime versions and SHA-256 checksums
  pinned. Update Whisper C declarations together with its runtime ABI. Do not
  introduce Homebrew, CMake, Python or Xcode as end-user prerequisites.
- Keep inference serialized across meetings, with bounded audio buffers,
  context and generation. Process every transcript section; do not omit the
  middle to fit a model. Keep the summary helper private to the app and disable
  idle prompt caching, agent tools, web UI and prompt logging.
- Save an opted-in transcript before summarization so summary retries can reuse
  it. Model downloads and caches are separate from retained meeting artifacts.
- [docs/LOCAL_MODELS.md](docs/LOCAL_MODELS.md) is the current model profile,
  asset lifecycle and validation reference. Historical alternatives in PLAN.md
  do not override this standard.

## Conventions

- Persistence layers should stay small and swappable; the view model
  never touches the file system directly (use MeetingArtifactManaging for cleanup). Keep an `inMemory()` seam for tests so
  the test suite never reads/writes the user's real files.
- Prefer fixing problems over surfacing them; validate end-to-end (the app should
  actually launch and run, not just compile and pass tests).
- Read `PLAN.md` before making non-trivial changes — it records the intended
  architecture, the phased roadmap, and the open product decisions.

- API keys live only in Keychain. Never log, serialize, or bundle them.
- Run `bash build.sh test` for Core assertions and actual media preparation
  checks. `Validation/run.sh` adds optional live checks and isolated UI fixtures;
  a skipped permission check is not a passing end-to-end recording test.
- Keep the test recordings root isolated for the entire harness. Resetting it to
  the real default can sweep or write the user's recordings from a unit test.
- Persist summaries and pending cleanup decisions before removing source files.
  Prepared mixes are always transient, including when original audio is kept.

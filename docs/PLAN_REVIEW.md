# Plan review — 23 October 2026

The implementation was reviewed against all eighteen sections of PLAN.md,
including the product promises and definition of done, rather than only the
remaining roadmap bullets. The main improvements were to make real capture,
durability, and retention match what the plan already promised.

## Capture and transcription — §§1, 6–8, 13, 16

The original system stream had no registered `SCStreamOutput`, and its callback
signature did not conform to that protocol. A stream could start without
writing the audio needed downstream. Capture now registers an audio output on
a serial queue, copies PCM with CoreMedia's supported buffer API, drains queued
writes before closing, and reports stream and write failures to the live UI.

Both transcription implementations previously selected an arbitrary first file
from the source dictionary. The real pipeline now prepares both tracks before
transcription, preserving their start offsets so a delayed permission prompt
does not shift the remote side over the opening of the microphone track. The
mixed file stays inside the meeting's managed directory and is removed after
success, failure, or cancellation. Cloud audio is exported as compressed M4A,
including single-source recordings, reducing upload size and avoiding reliance
on provider support for a raw CAF container.

The Start path now uses the configured source toggles. Duplicate starts and a Start overlapping Stop retain
the original session, and Stop is disabled until capture initialization finishes.
The microphone preference now enumerates real CoreAudio inputs and selects the
saved device UID; a disconnected device gives actionable guidance.

Local Speech now requests Speech authorization on use, includes its required
Info.plist purpose string, requires on-device recognition, and refuses to send
audio to Apple's servers when that language lacks an on-device model. It keeps
the recognition task alive, completes its continuation once, supports
cancellation, and groups Speech's actual word timestamps into readable utterances. The privacy claim is
therefore enforced rather than merely documented.

Deepgram requests now use `/v1/listen`, URL-encoded query parameters, numeric
speaker IDs, `end` timestamps, and punctuated words from the real response
schema. The earlier fake responses used string speakers and `dur`, which hid
the production mismatch. Tests now cover the actual provider shape.

**Intentional limit:** local speaker labels remain a pause-based approximation;
Deepgram is the available path for actual voice diarization. The README and
onboarding state this explicitly. Adding a bundled local speaker model remains
a separate product direction, not an unimplemented promise of the current
local backend.

## Summary quality and long meetings — §§6, 9, 16

A single 120,000-character budget is suitable only as a generous cloud guard;
it cannot be applied to Apple's much smaller on-device context window.
Local summaries now divide the complete transcript into bounded sections,
create a fresh model session for each, and merge chronological section gists,
key points, decisions, and action items. Duplicate structured items are removed.
The opening, middle, and closing all reach the model. Long local summaries may
therefore contain several section gists rather than a single four-sentence
paragraph.

Local requests bound response size and retry context-window failures with a
smaller view in a fresh session. If a dense section needs additional
truncation, the existing partial-view warning remains attached to the result,
detail view, and copied text. This uses the original macOS 26 API surface so
older usable SDKs can still compile the local path. Source audio is preserved
if the model cannot process a request. The built app weak-links FoundationModels,
so its presence is not required at launch on older macOS.

Empty speech and empty or incomplete structured model responses fail before
retention. Plain-text summary responses remain supported. Actual model names
are stored with summaries and shown in the detail pane. Changing summary
providers chooses a compatible default model while preserving an explicitly
supplied replacement in the same settings update. The Anthropic default is an
available Haiku 4.5 identifier rather than the retired 3.5-era alias; users can
choose another model.

Cloud retries now respect cancellation rather than continuing after a
cancelled backoff. The existing transient-failure policy and SDK fallback remain
intact.

References: [Apple's context-window guidance](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window),
[Deepgram's prerecorded API](https://developers.deepgram.com/reference/speech-to-text/listen-pre-recorded),
[Anthropic's Haiku model IDs](https://platform.claude.com/docs/en/models/haiku-4-5/overview).

## Persistence and retention — §§3–5, 10–12, 18

Fresh installations previously attempted to save into directories that did not
exist. Both stores now create their parent directories. `MeetingStore` recovers
from its backup when the live file is corrupt, and never replaces a good backup
with corrupt bytes during repair. In-memory stores now actually remain in
memory; they no longer write randomly named temporary backing files.

A meeting must be saved before recording starts. After processing, the summary
and exact pending deletion list are saved before any source file is destroyed.
If that durable write fails, the audio remains available. If cleanup fails,
the record keeps its source references and failure reason. Startup or Retry
can finish a saved cleanup decision without another transcription or model
request, even if the global retention settings have since changed.

Deleting a meeting removes retained artifacts immediately, refuses active
recording/processing deletions, asks for confirmation in the UI, and removes
the deleted record from the backup as well. If artifact deletion fails, the
record stays available instead of hiding unmanaged files.

Recording file references and start offsets are persisted during capture, so
an interrupted recording can be reconciled to a failed, retryable meeting.
Failure reasons now belong to the individual meeting and survive relaunch.
Meeting decoding supplies defaults for missing fields from older versions.

Filesystem cleanup is behind the `MeetingArtifactManaging` seam; the view model
no longer calls FileManager directly. Core lifecycle decisions still import no
platform recording, speech, UI, or networking frameworks.

The data folder is fixed for a running app session, matching the fixed meeting
store. Selecting a new location takes effect after restart. This avoids sending
new recordings to one directory while history still saves to another. Changing
locations does not migrate existing history; the Settings UI and README explain
that behavior.

## UI and onboarding — §§2, 11, 13, 17

The first-run card explains selected audio sources, microphone/Screen Recording/
Speech permissions, cloud transfer, local requirements, and retention. It links
to System Settings and the app's Settings. Setup remains accessible from the
header after the first meeting.

Search now uses the Core query across the entire structured summary, including
decisions and action items. The recording header and menu expose elapsed time. A single main window can
be reopened from the menu bar; the sidebar and detail use a native split view
without the overlapping toolbar insets found during visual validation.
The detail pane offers cancellation, retry, copy, Finder access for retained
audio, and confirmed deletion. Progress is tracked by meeting so one meeting's
stage does not appear on another's detail pane. Toast preferences now control
real completion/failure/delete messages.

The optional prompt-override field remains reserved; all backends use the
shared summary contract. Per-source gain and additional transcription providers
remain the optional alternatives described in the original plan.

The defaults are deliberately unchanged: local transcription and an OpenAI
summary requiring a key. Fully local processing is an option requiring a
suitable Apple Intelligence installation. The contradictory README claim that
the default was already fully offline has been corrected.

## Build, tests, and distribution — §§14, 17–18

`bash build.sh test` still uses `swiftc` only and preserves the SDK fallback.
The assertion harness adds production-shaped provider fixtures, fresh-install
storage, backup repair, interrupted cleanup recovery, cancellation, source
settings, search coverage, malformed summaries, and full-transcript chunking.
Every view-model test is isolated from the user's recordings directory, even
after an individual test resets its directory override.

The app-layer media checks use real AVFoundation export to verify both tracks
are audible and derived files are cleaned up. Optional validation helpers cover
isolated UI fixtures and live system audio / Apple Intelligence. SKIP results
remain explicitly separate from successful checks.

FoundationModels imports are conditional, allowing older SDKs to build an app
with an actionable local-summary availability error. Developer ID signing now
includes the hardened-runtime audio-input entitlement. Notarization archives
the complete bundle, uses the actual Apple ID/team options, and cleans up its
temporary archive. A separate check workflow runs the build, assertions, and media checks on
ordinary pull requests and main-branch pushes. The release workflow accepts a configured bundle ID and
removes its temporary API key file. The distribution runbook now matches these
commands rather than describing speculative certificate and sandbox steps.

## Scope decisions and acceptance limits

No cloud sync, editing, live transcription, export integration, additional
provider, or bundled model system was added. These remain the plan's stated
non-goals or alternatives. A reserved Whisper setting and its optional model
store are not presented as an available transcription backend.

Deterministic tests and real media export establish pipeline wiring and cleanup,
not diarization quality on an arbitrary call. Live system capture has been
verified with a spoken fixture after waking the display. A real local model has
returned a correct structured summary and action item. Live microphone capture and Speech remain unverified: the validation process
has not been granted those macOS permissions. An authenticated cloud recording-to-summary run and Developer ID /
notarization also remain unverified; no provider keys or distribution
credentials were used for these checks.

These are explicit acceptance limitations, not additional implementation tasks
that can be completed without the relevant macOS authorization or credentials.


Final local validation:

- `bash build.sh test`: 343 Core assertions and five real AVFoundation media checks.
- `swift run TranscriberTests`: the same 343 assertions pass.
- `swift build --sdk <working SDK> --product Transcriber`: the app also builds
  as separate SwiftPM Core and App modules.
- Isolated onboarding and seeded summary-detail windows launched and visually
  inspected; header controls and content no longer overlap.
- Live ScreenCaptureKit recorded audible spoken fixture output.
- Live Apple Intelligence returned the launch decision and Alex's release-notes
  action item.
- Live microphone capture and Speech: unverified without the relevant macOS
  authorization.
- Authenticated cloud calls and notarization: not run.

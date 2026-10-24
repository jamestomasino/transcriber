# Validation

`bash build.sh test` runs the assertion harness plus real AVFoundation media
checks. No permissions, network access, provider keys, or user data are needed.
All view-model tests use temporary recordings roots. In-memory stores do not
write backing files.

Storage checks migrate legacy inline libraries to dated summary/transcript files,
verify metadata-only indexes, recover matching content revisions, roll back failed
writes, and exercise retention and interrupted deletion. Migration/read failures
pause automatic cleanup so source recordings remain available.

The media checks create two tracks with sound in different halves, verify that
both survive mixing, check temporary-file cleanup after success and failure,
and verify compression for a single cloud-bound track. A 125-second audio fixture
also verifies full coverage by local Speech sections, absolute timestamps, and
transient-file cleanup after success, failure, and cancellation, without requiring
Speech permission. The detailed live summary check verifies action owners, deadlines,
priorities and a numeric finding across multiple transcript sections.

Optional live checks:

```bash
bash Validation/run.sh live
bash Validation/run.sh live --detailed-summary # multi-section audit detail and action coverage
```

This creates a spoken fixture with macOS `say`, plays it through `afplay`, and
records system output when screen permission and an awake display are available
on macOS 14.0–14.1. On macOS 14.2+, explicitly opt into the audio-only live
check with `bash Validation/run.sh live --system-audio`; this can request
System Audio Recording access for the launching host. It
also exercises Apple Intelligence with a real summary request. Speech is tested
only when the launching process already has Speech Recognition authorization.
The helper never uses cloud credentials; only `--system-audio` may request
audio permission. It prints
`SKIP` for unavailable capture or speech prerequisites; those lines are not
successful acceptance checks. All generated audio is removed on normal exit.

For isolated UI inspection:

```bash
bash Validation/run.sh preview --empty  # onboarding
bash Validation/run.sh preview          # seeded summary detail
bash Validation/run.sh preview --settings # local vocabulary and settings
bash Validation/run.sh preview --settings --cloud # cloud disclosures and key fields
bash Validation/run.sh preview --failed # summary retry with a saved transcript
bash Validation/run.sh preview --resume # interrupted attempt
bash Validation/run.sh preview --waiting # resource-related waiting
bash Validation/run.sh preview --queue --snapshot /tmp/transcriber-preview.png
```

The preview uses in-memory meetings/settings and a no-op artifact manager. It
never loads or sweeps the user's real data. A banner and window title identify
the sample meetings. Recording, downloads, credential reads/edits, and permission
requests are disabled. Close the previous preview before launching another; the
normal app can remain running. `--snapshot <path>` renders only the preview's own
content view and closes the preview automatically. It does not capture the desktop
or require screen-recording permission. These bitmap snapshots support copy/layout
inspection; native button/material compositing can differ from the displayed window.

`run.sh` reuses the SDK selected by the last `build.sh` invocation (recorded in
`build/sdk-path`). Run `bash build.sh test` again after changing installed SDKs.

Permission onboarding acceptance (use the normal app with permissions not yet
requested, or a separate test bundle ID; do not reset the user's permissions):

1. Open Setup and permissions before starting a meeting. Click Allow for
   Microphone and System Audio Recording (Screen Recording on macOS 14.0–14.1), and for Speech Recognition if using local
   transcription. Each must trigger its macOS permission request without
   creating a meeting or recording files.
2. Grant access and play sound in another app during the system audio check.
   A green checkmark requires actual audio; silence should show retry guidance.
   Return from System Settings to check that the panel refreshes. If macOS
   requires a relaunch, reopen the same app and check again. The request must
   survive relaunch without requiring another Allow click.
3. Deny access and verify that the row offers System Settings. For a previous
   system audio denial, the initial Allow attempt should reveal the
   Settings link even though macOS does not repeat the prompt.
4. Disable an audio source or switch to cloud transcription in app Settings and
   confirm that onboarding only offers the permissions needed by that setup.

Final manual acceptance in the normal app still requires a real recording with
microphone and system audio, Speech permission or a Deepgram key, and a usable
summary backend. Verify the resulting summary, retry/cancel behavior, removal of
raw artifacts, and persistence after relaunch. An authenticated cloud run is
separate from the deterministic fake-HTTP tests.

To check multiple utterances with the normal app's existing Speech permission,
close the normal app and launch `open build/Transcriber.app --args
--validate-local-speech`. This reopens the normal app and its history, then
transcribes a synthetic recording with three sentences separated by silence;
it does not create a fixture meeting or process a real recording. The fixture
audio stays in an isolated temporary folder and is removed on completion.
`transcriber-hosted-speech-check.json` in the system temporary directory records
whether the first, middle, and last markers and deadlines survived. On macOS
26+, this also checks the installed-model `SpeechAnalyzer` file path. A passing
short fixture still does not establish complete coverage of a real long meeting.

Downloaded local model validation is opt-in:

```bash
bash Validation/run.sh models --whisper-only
bash Validation/run.sh models --summary-only
bash Validation/run.sh models --catalog       # public metadata only; no weights downloaded
bash Validation/run.sh models --probe-current # switch-time synthetic check on the cached default
bash Validation/run.sh models --inspect-cleanup <UUID> # read-only retained transcript cleanup statistics
bash Validation/run.sh models --inspect-cleanup <UUID> --whisper-loops # also measure Whisper decoder loops
```

These checks download missing pinned public weights, then process synthetic
pharma speech and notes. They report term/action coverage, timings and host peak
memory without logging transcripts. `--meeting <UUID> --whisper-only` explicitly
checks a real retained recording excerpt; its transient audio stays in the
managed recording directory and is removed. Model download buttons are disabled
in the isolated UI preview. See [the model profile](../docs/LOCAL_MODELS.md).

For an explicitly requested full rerun, quit the normal app and launch it with
`open -n build/Transcriber.app --args --retranscribe-meeting <UUID>`. This uses
the user's current settings and updates the real meeting. Completed meetings
require retained audio; ordinary `--retry-meeting` does not restart them. The
same action is available as **Transcribe again** in the meeting detail view.
The 24 October acceptance run processed a complete 37-minute recording through
Whisper and the downloaded summarizer with saved vocabulary; see the model
profile for measured timings, outputs and accuracy limits.

Internal speaker-only diagnostics use `--relabel-speakers <UUID>` with automatic
count detection. This is an explicit real
meeting update, requires retained audio and transcript, and preserves transcript
wording, timing and the saved summary. There is no manual count picker or
speaker-update button in the product. Legacy saved count hints are ignored. Normal launches
do not rerun speaker matching. The default harness tests acoustic overlap
assignment, returning identities, unknown labels, metadata persistence, failure
preservation, managed PCM preparation and helper completion/cancellation.

## Background workload validation

```bash
bash build.sh test
bash Validation/run.sh preview --queue
bash Validation/run.sh background --run-models --threads 4 --rounds 2
build/validation-background --run-models --threads 2 --rounds 2
```

The opt-in background benchmark refuses to download missing assets. Explicitly
prepare the default Whisper/Qwen models in Settings first. It creates public
synthetic speech in an isolated temporary folder, verifies terminology and action
owners/deadlines, emits numeric timing/resource JSON, and removes its source.
It never loads the meeting library or changes selected models. Use the compiled
binary for additional profiles so compilation does not contaminate measurements.
Profiles change only CPU thread limits, not quantization or context. A fixed
benchmark-only seed controls sampling across comparisons; production generation
settings remain unchanged. Quality failures still emit numeric diagnostics and
return a failing exit status. The four-thread production limit remains unchanged pending longer tests.

Run profiles sequentially and repeat in reversed order to expose warm-cache and
thermal effects. Keep cold-start results separate. Compare queue wait, preparation,
model load, inference, token usage, retries and shutdown; include resource samples
alongside elapsed time. The resource sampler is optional validation code, not
production telemetry. Its main-actor delay is a scheduling proxy and cannot stand
in for testing a worker's foreground browser, document and video-call interaction.

The deterministic suite covers capture deferral, queued cancellation, stage-boundary
yield, recovery hysteresis, Low Power Mode, critical interruption and explicit
relaunch recovery. Actual-media/helper checks cover shared mixes, source validation,
TERM-ignoring child teardown, native admission protection, section reuse/invalidation
and default-retention isolation. The queue preview uses in-memory meetings and a
sleeping fake processor, with recording/model downloads disabled.

Before broad rollout, perform the section 30 PLAN.md workload gate: a 30–60 minute
meeting, at least three queued recordings, a fresh live capture, realistic foreground
work, sleep/wake, disk failures and relaunch. Require no lost recordings or unmanaged
artifacts, no overlapping model lifetimes, recoverable interruption, and no sustained
new swapping/critical pressure attributable to processing. Establish foreground
latency thresholds against that workload's baseline and report worst observed
latency as well as medians. Synthetic passes do not establish this acceptance.

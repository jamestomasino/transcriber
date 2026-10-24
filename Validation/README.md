# Validation

`bash build.sh test` runs the assertion harness plus real AVFoundation media
checks. No permissions, network access, provider keys, or user data are needed.
All view-model tests use temporary recordings roots. In-memory stores do not
write backing files.

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
```

The preview uses in-memory meetings/settings and a no-op artifact manager. It
never loads or sweeps the user's real data. Recording and provider-key edits
are disabled in the fixture. Close the previous preview before
launching another; the normal app can remain running.

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
```

These checks download missing pinned public weights, then process synthetic
pharma speech and notes. They report term/action coverage, timings and host peak
memory without logging transcripts. `--meeting <UUID> --whisper-only` explicitly
checks a real retained recording excerpt; its transient audio stays in the
managed recording directory and is removed. Model download buttons are disabled
in the isolated UI preview. See [the model profile](../docs/LOCAL_MODELS.md).

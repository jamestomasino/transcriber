# Validation

`bash build.sh test` runs the assertion harness plus real AVFoundation media
checks. No permissions, network access, provider keys, or user data are needed.
All view-model tests use temporary recordings roots. In-memory stores do not
write backing files.

The media checks create two tracks with sound in different halves, verify that
both survive mixing, check temporary-file cleanup after success and failure,
and verify compression for a single cloud-bound track.

Optional live checks:

```bash
bash Validation/run.sh live
```

This creates a spoken fixture with macOS `say`, plays it through `afplay`, and
records system output when permission and an awake display are available. It
also exercises Apple Intelligence with a real summary request. Speech is tested
only when the launching process already has Speech Recognition authorization.
The helper never requests permissions or uses cloud credentials. It prints
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

Final manual acceptance in the normal app still requires a real recording with
microphone and system audio, Speech permission or a Deepgram key, and a usable
summary backend. Verify the resulting summary, retry/cancel behavior, removal of
raw artifacts, and persistence after relaunch. An authenticated cloud run is
separate from the deterministic fake-HTTP tests.

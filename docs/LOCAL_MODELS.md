# Downloaded local inference

**Standard workflow, confirmed 24 October 2026:** Whisper transcription followed
by downloaded local-model summarization. Fresh installs select these backends;
existing saved Apple or cloud choices are preserved as explicit alternatives.

Neither model weights nor inference runtimes are bundled with the app. Launching
the app or selecting a backend does not fetch assets. Downloads start when the
user requests the selected models in Setup/Settings, or when a meeting first
reaches a processing stage whose selected assets are missing. Verified cached
assets are then reused offline; builds and normal startup do not download them.
No Homebrew, Python, model server installation, full Xcode, account or API key is required.
The app still builds with `swiftc` through `bash build.sh`.

| Stage | Model | Weights | Intended role |
| --- | --- | --- | --- |
| Transcription default | Whisper large-v3, Q5_0 | 1,081,140,203 bytes | Accuracy-oriented speech recognition with terminology hints |
| Transcription alternative | Whisper large-v3-turbo, Q5_0 | 574,041,195 bytes | Faster, smaller option; evaluate terminology accuracy before switching |
| Summary default | Qwen 3.5 4B, Q4_K_M | 3,013,027,808 bytes | Compact instruction model with schema-constrained meeting notes |

The summarizer uses an 8,192-token context, a 256-token prefill batch and
128-token microbatch, and at most 3,072 generated tokens per section. Idle prompt
RAM caching, context checkpoints and context shifting are explicitly disabled. Meetings
are split into complete sections rather than truncated. An output-limit response
splits the affected section again. Thinking is disabled for this extraction task.

Eight GB is the configured minimum for the summary model. Sixteen GB provides
more room for macOS and other applications; the same 4B model is the baseline
for recent Macs rather than automatically filling available memory. Larger
8–9B models are a future explicit quality tier, pending measurements and review.
Model files are not a measure of total runtime memory: caches and working buffers
also consume memory. Transcription and summarization run sequentially, including
across concurrent meetings in one app process, and release model weights between
stages. Whisper processes five-minute, overlapping PCM sections in memory, about
19 MB of audio per section, without writing a prepared WAV.

## Pharmaceutical terminology

Large v3 is a general speech model, not a pharma-specific fine-tune. Add relevant
drug names, trial identifiers, companies and acronyms in the terminology-hint
field. Keep this list short; it is a decoder hint, not a guaranteed correction.
The summary prompt preserves drug names, doses, units and endpoints as stated
and prohibits inferred corrections or medical decisions. Speaker labels remain
approximate; Whisper alone does not identify participants.

The live synthetic check uses pembrolizumab, pharmacokinetics and
pharmacovigilance plus three named tasks and deadlines separated by silence.
All three terms and deadlines survived with Large v3 and those hints. This does
not establish accuracy across real pharmaceutical meetings or all drug names.
A one-minute excerpt from the retained business meeting also transcribed locally
without changing the meeting. On the 8 GB Apple A18 Pro test machine this took
56 seconds including preparation, with approximately 1.9 GB host peak resident
memory. The synthetic run included runtime setup, so its 76-second timing is not
an inference-only benchmark. The summary fixture preserved all three action
owners/deadlines, priority P0, the drug name, 50 mg units and the explicit decision.
It took 80 seconds including cache verification, runtime startup and generation;
the model subprocess peaked at about 3.1 GiB resident memory (3,131 MiB sampled
once per second). These are single-machine measurements, not guarantees for
other Mac configurations. GPU allocations and other applications also contribute
to total system memory pressure. A subsequent cached run with idle RAM caching
and context checkpoints disabled completed the same fixture in 52 seconds. The
retained 6,010-word meeting transcript also completed as four full sections,
producing 41 key points and 10 action items. That recovery used the existing
transcript; it was not a full Whisper retranscription of the 37-minute recording.

## Assets and lifecycle

Whisper weights come from the [whisper.cpp model publisher](https://huggingface.co/ggerganov/whisper.cpp)
at revision `5359861c739e955e79d9a303bcbc70fb988958b1`.
The summary model is the [Qwen 3.5 4B model](https://huggingface.co/Qwen/Qwen3.5-4B)
with [Q4_K_M weights](https://huggingface.co/bartowski/Qwen_Qwen3.5-4B-GGUF/tree/4168f45a16a1290d65a4ec0fa312ae917a4c15d6)
at revision `4168f45a16a1290d65a4ec0fa312ae917a4c15d6`.
Model revisions, exact sizes and SHA-256 values are pinned in the catalog.

Runtimes are upstream whisper.cpp `b5454` and llama.cpp `b11840`. Downloads are
verified before installation; incomplete files are never loaded. Cached assets
are verified on first use in each process, with in-session reuse. URLSession
resume data supports retry after network failure or cancellation when available.
Models and runtimes live under Application Support/Transcriber/models, separately
from meeting recordings and their retention policy. The repository vendors the
pinned Whisper C ABI declarations; the app includes their MIT license. The
compiled framework is downloaded and dynamically loaded, so its ABI declarations
and archive checksum must be updated together.

The summary helper listens on a Unix socket inside a mode-0700 temporary folder.
It has no network listener, web UI, enabled agent tools, provider key, prompt log
or persistent prompt cache. Its environment is restricted to local runtime needs.
A parent-owned pipe stops the helper on normal cleanup or app exit. Cancellation
stops inference and retains the source artifacts. The usual durable-save-before-
deletion policy remains in effect. If transcript retention is enabled, a saved
transcript can be reused for **Retry summary**; **Transcribe again** replaces it
only after fresh transcription succeeds.

## Validation

`bash build.sh test` includes pure request/settings checks plus isolated model
cache integrity, audio conversion, private socket transport and cancellation
checks. These never download real weights or read user recordings.

Opt-in live checks download missing public assets:

```bash
bash Validation/run.sh models --whisper-only
bash Validation/run.sh models --summary-only
bash Validation/run.sh models
```

An explicit `--meeting <UUID> --whisper-only` additionally checks a one-minute
excerpt of that retained recording. Derived audio stays under the managed
recording directory and is removed; the meeting is not changed. Logs contain
counts and timing, not the recording or transcript. Never treat synthetic checks
as proof of long-meeting quality or coverage of real pharmaceutical terminology.

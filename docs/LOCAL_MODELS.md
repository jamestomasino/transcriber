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

## Domain vocabulary

Large v3 is a general speech model. Add relevant names, organizations, products,
projects and acronyms in **Settings → Local vocabulary**. Enter one canonical
name per line, for example `Acme`, `Project Atlas` and `Northstar`; commas and
semicolons are also accepted. The list is saved
automatically in local settings and reused across meetings. Duplicate names are
ignored case-insensitively, preserving the first spelling and order. Existing
terminology hints use the same saved field and need no migration.

Keep this list short; it is a decoder hint, not a guaranteed correction or a
search-and-replace dictionary. Whisper receives a bounded 1,000-character list
of complete names, repeated at each audio section. Settings shows how many
names fit and warns when the remaining entries are excluded. Put the most
relevant terms first. Whisper also has its own decoder token limit, so focused
lists work best. Other transcription backends do not currently use this list.

Changes affect future transcription, including **Transcribe again** for meetings
whose audio was retained. They do not rewrite saved transcripts or change
summary-only retries. No meeting text is added to the vocabulary automatically.
Completed meetings with retained audio also offer **Transcribe again**; this
explicitly runs both transcription and summarization using current settings.
The previous result stays saved until the replacement stages succeed.
The summary prompt preserves specialized names, numbers, units and technical
details as stated and prohibits inferred corrections or decisions. Speaker labels remain
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

A later explicit rerun on 24 October processed the complete 37-minute,
20-second recording with eight saved vocabulary entries, then generated a new
summary using both downloaded backends. Whisper produced 655 segments and
6,180 words, reaching 2,240.7 seconds. Preparation/transcription took about
16 minutes 40 seconds, followed by about 7 minutes 15 seconds for summarization
(about 24 minutes total on the same 8 GB A18 Pro). The durable summary contained
37 key points, 21 decision/rationale entries and four action items. The opted-in
audio and transcript remained, the transient mix was removed and the helper
exited. Several previously missed canonical names appeared in both outputs;
some spelling errors remained. The earlier transcript used Apple Speech, so
this comparison does not isolate the effect of vocabulary hints. These counts
and timings establish one complete run, not transcript or summary accuracy.

## Apple Silicon execution profile

Apple Silicon uses [unified physical memory shared by CPU and GPU](https://developer.apple.com/videos/play/wwdc2020/10686/),
not additive RAM and dedicated VRAM. The A18 Pro test Mac has 8 GB total.
Whisper explicitly enables Metal and Flash Attention; the real recording's
process sample showed Metal graph computation. The summary runtime uses
automatic layer offloading. A public-model-only startup audit with the app's
normal inference flags confirmed `has unified memory = true`, shared buffers,
34/34 layers offloaded, about 2,741 MiB of Metal-mapped model buffers and a
256 MiB GPU KV buffer. This verifies actual placement rather than only GPU
availability. Debug startup logging was enabled only for the audit, with no
meeting prompt; production prompt/runtime logging stays disabled.

Speaker matching currently uses two CPU threads per model. After stopping an
extra diarizer and finishing the build, two sequential timing rounds on the
56.861-second public four-speaker fixture measured these process wall times:

| Segmentation provider | Embedding provider | Wall seconds, rounds 1 / 2 |
| --- | --- | --- |
| CPU | CPU | 5.483 / 6.418 |
| CPU | CoreML | 7.720 / 8.391 |
| CoreML | CPU | 5.281 / 5.284 |
| CoreML | CoreML | 8.521 / 7.684 |

All eight runs returned the four reference identities with the same recurring
identity sequence. CoreML for segmentation alone is a possible modest gain;
changing both providers was slower. Keep the production CPU profile until a
long-recording comparison checks repeatable speed and attribution quality.
These are cached-asset, single-machine fixture timings, including process/model
startup. CoreML can partition work across supported hardware and fall back to
CPU; selecting it does not prove every operation uses GPU or Neural Engine.
The [ONNX Runtime CoreML provider documentation](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html)
describes those execution and operator constraints.

## Assets and lifecycle

### Summary model discovery and replacement

**Settings → Summary → Check available models** fetches public Hugging Face
metadata from Qwen and bartowski's direct Qwen conversions. It does not download
weights or send meeting content, vocabulary or hardware information. Scans are
explicit; there is no startup update request or silent upgrade. Whisper and
speaker assets remain pinned to their separate runtimes.
Equivalent conversions are consolidated into one picker entry, retaining the
active pinned download rather than silently switching to another publisher.

The picker offers standalone Q4_K_M GGUF chat models that fit the Mac's memory
profile. It omits split files, vision projectors, gated models, unrelated
publishers and specialist code/embedding/thinking-only releases. Each entry
pins a commit, exact file length and LFS SHA256. Future compatible releases can
appear without changing the app catalog; a new architecture can still require
an app/runtime update. The current working model stays selected until an
explicit **Download & switch** completes.

Recommendations are estimates, not accuracy rankings. Admission allows for
weights, bounded inference buffers and macOS/application headroom. Ranking
prefers known architectures, balanced parameter ranges and newer comparable
versions. The default 8 GB profile favors approximately 4B models; larger Macs
can see larger choices. Nothing is automatically sized up based on RAM.

Replacement runs under the shared inference queue while the app is idle:

1. Check space to keep both downloads during the transition.
2. Download and verify the candidate using the normal pinned cache.
3. Load it in the private local runtime and run a short, synthetic structured
   notes check for an action owner and deadline. No real meeting is used.
4. Persist its public catalog/check metadata, then durably save the new selected
   ID. Reject a stale selection or a recording/processing task that started
   during preparation.
5. Delete only the previous summary-weight file and its download-resume data.
   Speech models, shared runtimes, speaker models and recordings are untouched.

A failed download, local check, cancellation or settings save keeps the prior
model/selection. A newly downloaded failed candidate is discarded. If deleting
the old weights fails after activation, the new working selection remains and
the UI reports that old bytes remain. A successful small check establishes basic
runtime/task compatibility, not long-meeting quality or a general benchmark.

`models/summary-catalog.json` stores the public, integrity-pinned descriptors and
check records, enabling offline resolution of downloaded models across launches.
The built-in measured 4B profile remains available if there is no downloaded
catalog. Invalid entries are rejected; an unavailable selected entry reports an
error rather than silently choosing another model. Settings remembers the last
downloaded-model choice when switching to another summary provider and back.

Validation on 24 October: 439 Core assertions plus isolated filesystem, media,
cache and helper checks passed. Live discovery returned ten pinned choices for
the 8 GB test Mac without downloading weights. The cached default passed the
512-token switch-time check, and normal catalog-backed summarization passed the
owner/date/priority/unit fixture in 38 seconds. An isolated swap verified new
asset integrity, selection-before-deletion and offline catalog restoration.
The user's selected model and its weights were unchanged by these live checks.

Local transcription also uses downloaded acoustic speaker models: Pyannote 3.0
segmentation (MIT), [NeMo TitaNet Small embeddings](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/nemo/models/titanet_small)
(Apache-2.0 under the linked NeMo toolkit license), and the pinned
[sherpa-onnx 1.13.8 macOS runtime](https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.8)
(Apache-2.0). The weights/archive/runtime total
about 65 MB on Apple Silicon, separate from Whisper and the summary model.
They use the same verified download-on-demand cache; startup and selecting a
backend do not fetch them. Builds require no additional tools or model assets.

Speaker matching groups returning voices across the entire recording, rather
than treating each pause as another person. Count detection is automatic; the
product has no speaker-count picker or update-speaker button. Legacy saved count
hints are ignored. An internal diagnostic can update labels without repeating
transcription or summarization. Clusters do not identify participants by name. Profiles
are transient within the inference process and are not saved across meetings.

Speaker-only updates require retained audio and transcript. They preserve every
transcript word and timestamp and the existing summary. Failures preserve the
previous completed result. Legacy pause-based labels are marked unverified in
the UI, rather than displayed as a measured speaker count. Whole transcript
segments are assigned by maximum overlap with acoustic speaker turns; an
unmatched segment stays unknown and does not add to the count. A segment that
contains multiple speakers still has only its dominant speaker label.

Audio preparation streams 30-second sections into a managed transient
`speaker-analysis.wav` (16 kHz mono PCM). It is always removed after matching,
even when source recordings are retained; crash recovery also sweeps it. The
offline runtime currently accepts recordings up to two hours, bounding its
whole-file float buffer to about 460 MB. Longer recordings retain their sources
and report the unsupported speaker stage. Inference is serialized with Whisper
and summarization and uses two CPU threads per speaker model. The helper is
reaped after completion, cancellation, or parent-pipe EOF.

The public sherpa four-speaker fixture tests recurring identities across
separated turns, not just the resulting count. Automatic clustering thresholds
0.8 and 0.9 both returned the four reference identities on this fixture; the
upstream default of 0.5 over-split them. This fixture is not a general diarization
accuracy evaluation; accents, overlap, short turns and recording quality matter.
The app uses 0.8 for automatic clustering with the [upstream diarization API](https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/models.html).

Before manual controls were removed, the retained 37-minute recording was reprocessed for speakers only
with the user's seven-speaker hint. It saved seven voice groups; 16 of the 655
segments remained unknown where acoustic matching was insufficient. All 655
segments retained identical text and timestamps, the entire summary was
unchanged, original audio remained, derived audio was removed and the helper
exited. This verifies the update/retention path, not seven independently
identified people: supplying seven constrains clustering, and one resulting
group contained only a short acknowledgement. Individual voice assignments on
this real recording have not been checked against human-labelled ground truth.

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

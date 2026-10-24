# Distribution

The app builds with Command Line Tools and `swiftc`; full Xcode is not required.
`bash build.sh test` builds an ad-hoc signed app and runs the Core and media
checks. Developer ID signing and notarization are optional distribution steps.
They have not been exercised against Apple's service in this checkout.

## Credentials

Runtime provider keys belong in the app's Settings and macOS Keychain. They
are never bundled or read from `.env`.

Distribution credentials belong only on the developer machine or in CI secrets:

- A **Developer ID Application** certificate with its private key in Keychain.
- An App Store Connect API key (`.p8`, key ID, issuer), or an Apple ID,
  app-specific password, and team ID for notarization.

Create a certificate signing request in Keychain Access's Certificate Assistant,
submit it when creating the Developer ID Application certificate in the
[Apple Developer account](https://developer.apple.com/account/resources/certificates/list),
then import the issued certificate on the machine that created the request.
Export the paired certificate and private key as a password-protected `.p12`
only when another machine or CI needs them. Do not create a self-signed
certificate as a substitute for Developer ID.

## Local build

Copy `.env.example` to `.env`, fill in distribution credentials, and load it:

```bash
set -a
. ./.env
set +a
bash build.sh test
```

The relevant variables are:

| Variable | Purpose |
| --- | --- |
| `TRANSCRIBER_SIGN_IDENTITY` | Installed Developer ID Application identity. |
| `TRANSCRIBER_BUNDLE_ID` | Optional identifier you control; defaults to `local.transcriber`. |
| `TRANSCRIBER_NOTARIZE=1` | Submit the signed build and staple its ticket. |
| `TRANSCRIBER_ASC_KEY_PATH` | App Store Connect `.p8` path. |
| `TRANSCRIBER_ASC_KEY_ID` / `TRANSCRIBER_ASC_ISSUER` | API key ID and issuer. |
| `TRANSCRIBER_APPLE_ID` / `TRANSCRIBER_APPLE_PW` / `TRANSCRIBER_TEAM_ID` | Alternative Apple ID credentials. |

The script signs with hardened runtime and
[Resources/Transcriber.entitlements](../Resources/Transcriber.entitlements),
including audio input access. Microphone TCC authorization is still required.
[Apple's hardened runtime documentation](https://developer.apple.com/documentation/security/hardened-runtime)
describes why restricted resources need entitlements as well as user permission.

For notarization, the script creates a complete archive with `ditto`, runs
`notarytool submit --wait`, and staples the accepted ticket. Apple ID
credentials use `--apple-id`, `--team-id`, and `--password`, as described in
[Apple's notarytool migration note](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool).

Verify and package the result:

```bash
codesign --verify --deep --strict --verbose=2 build/Transcriber.app
spctl --assess --type execute --verbose=4 build/Transcriber.app
xcrun stapler validate build/Transcriber.app
ditto -c -k --keepParent build/Transcriber.app build/Transcriber.zip
```

Test the archive on another Mac: grant microphone, System Audio Recording (Screen Recording on macOS 14.0–14.1), and Speech
Recognition as needed, record both sides of a call, and confirm summary
persistence and retention after relaunch. Do not treat a successful notarization
as proof that recording permissions and the meeting pipeline work.

## CI

[.github/workflows/release.yml](../.github/workflows/release.yml) builds and tests,
imports the signing certificate, signs, notarizes, staples, and packages a
release on a version tag or manual invocation. Manual runs must target `main`
or a `v*` tag. The selected commit must belong to `main`; it is then checked out
by its exact SHA for signing. Signing waits for approval in the protected
`release` environment. It requires these **environment secrets**:

- `TRANSCRIBER_SIGN_IDENTITY`
- `TRANSCRIBER_P12_BASE64`, `TRANSCRIBER_P12_PASSWORD`
- `TRANSCRIBER_ASC_KEY_ID`, `TRANSCRIBER_ASC_ISSUER`, `TRANSCRIBER_ASC_KEY`

GitHub cannot return stored secret values. When migrating existing repository
secrets, re-enter all six values under Settings → Environments → release →
Environment secrets, verify all six names are present, then remove the matching
repository secrets. Keeping repository copies allows other workflows to bypass
the environment's approval gate. Do not paste credentials into issues or chat.
The environment settings are at
https://github.com/jamestomasino/transcriber/settings/environments.

The `release` environment permits only branch `main` and tags `v*`, requires
`jamestomasino` to approve, and disables administrator bypass. Self-approval is
allowed for the single-maintainer release process. Repository rules limit release
tag creation to administrators, prohibit updating or deleting release tags, and
prevent force pushes or deletion of `main`. Only tag reviewed commits already on
`main`; the ancestry check does not replace code review.

All actions are pinned to full commit SHAs whose metadata declares Node 24.
Build jobs use the macOS 26 image for the SpeechAnalyzer SDK while retaining
the macOS 14 deployment target and the CLT-only `swiftc` build.
The repository requires SHA pins. Checkouts do not persist credentials. Signing
runs with `contents: read`; credentials are deleted before packaging/upload, with
an `always()` cleanup fallback for failures. Hosted runner destruction provides
the final cleanup boundary if a runner is forcibly terminated.

Publishing runs on a separate Ubuntu runner, downloads the exact artifact ID
produced by the signing job, and fails on an artifact digest mismatch. Only that
job receives `contents: write`; it uses the runner's `gh` CLI without checking out
or executing repository code. Manual runs on `main` upload an artifact without
publishing. Tag runs create a release for the existing tag; an existing release
causes failure rather than overwriting its assets. Release runs for the same ref
are serialized and are not automatically cancelled.

Configure `TRANSCRIBER_BUNDLE_ID` as a repository variable if distributing under
a different identifier. Permission prompts are associated with application
identity: choose the identifier before distributing builds and keep it stable.
The workflow itself has not been dispatched during this work.

Mac App Store distribution would require a separate sandbox, provisioning, and
capture compatibility review. This repository currently targets direct
Developer ID distribution.

Downloaded local inference uses a pinned, checksum-verified Whisper framework
and a pinned llama.cpp helper. The runtime archives target macOS 13.3 or later,
so the app's macOS 14 deployment target is retained. Developer ID builds include
`com.apple.security.cs.disable-library-validation` so the separately downloaded
Whisper framework can load under the hardened runtime. Archive verification and
matching C ABI declarations are required; do not replace these with unpinned
runtime downloads. The Whisper MIT license is copied into the app resources;
llama.cpp's license ships with its downloaded runtime. Model source/license links
are shown beside downloads. See [local models](LOCAL_MODELS.md).

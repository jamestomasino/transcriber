# Distributing Transcriber (signing, notarization, CI)

How to turn the locally-built `.app` into a build that other Macs can run
without Gatekeeper warnings, using your Apple Developer account, plus a
GitHub Actions pipeline to do it automatically.

> Status: **runbook for a later phase.** The app currently builds ad-hoc signed
> (`bash build.sh`), which only runs on the machine that built it. Everything
> below is what we add when we ship to other people.

---

## 0. The one thing to get right first: two kinds of secrets

This is the mental model that makes the rest make sense. There are **two
separate kinds of secrets**, and they live in **two different places** for
**two different reasons**:

| Kind | What it is | Where it lives | Who needs it | When |
|------|-----------|----------------|--------------|------|
| **Runtime secrets** | OpenAI / Anthropic API keys | **macOS Keychain** on each user's Mac (already the case) | Each end user | Only if they pick the OpenAI/Anthropic summarizer |
| **Distribution secrets** | Developer ID cert + Apple notarization credentials | **Your machine** or **GitHub Secrets** | You (the developer) | Only at build/sign/notarize time |

### Runtime secrets are already handled — no `.env` needed to *use* the app

The app **does not bundle any secrets**. When a user chooses the OpenAI or
Anthropic summarizer in Settings, the key is written to the **macOS Keychain**
via `Keychain.set` and read back with `Keychain.get`. It is never written to
`settings.json`, never baked into the binary, and never appears in the repo.
(See `Sources/App/SettingsView.swift` and the Keychain helper.)

So a `.env` file is **not** required for anyone to *run* the app. The fully
local path (Local summarizer + on-device transcription) needs **no keys at
all**.

### Distribution secrets are only for *you*, at build time

To sign and notarize, you need credentials that prove it's **you** (Apple's
Developer ID) and that you can submit to Apple's notary service. Those are the
things that belong in a `.env` locally and in **GitHub Secrets** in CI. They
are build-time credentials, not app secrets, and they must **never** be
committed.

---

## 1. What you need from Apple (you already have the account)

Apple's **Developer ID** program (the paid $99/yr account you have) gives you
two distribution routes. Pick one:

- **Route A — Direct distribution (recommended for this app).** Users download
  a `.zip` containing `Transcriber.app` from anywhere (GitHub Releases, a
  website, AirDrop). Requires a **Developer ID Application** certificate plus
  **notarization**. No App Store, no sandbox. This is the best fit because the
  app wants to capture **system audio**, which is awkward (or blocked) under
  the App Store sandbox.
- **Route B — Mac App Store.** Requires an **App Store Distribution**
  certificate, an **App Sandbox** entitlement, and notarization is handled by
  the store. See §6 for the trade-offs — system-audio capture is the risk.

For Route A you need exactly these credentials:

1. **Developer ID Application certificate** (private key + cert), for signing.
2. **Notarization credentials** — either
   - an **App Store Connect API key** (`.p8` file + `ISSUER_ID` + `KEY_ID`), **or**
   - your **Apple ID** + an **app-specific password** (Settings → Security →
     App-Specific Passwords).

The API key is the cleaner option for CI (no password, no 2FA prompt).

---

## 2. Create the Developer ID Application certificate

One-time, on your Mac (or you can generate it in CI — see §5).

1. Go to <https://developer.apple.com/account/resources/certificates/list>.
2. Click **+** → **Developer ID Application** → Create.
3. Download the `.cer` file.
4. Double-click it to import into **Keychain Access** (it lands under
   *My Certificates*). It will show a small warning triangle — that just means
   the private key isn't there yet.
5. Generate the key on your Mac. In Keychain Access, under *My Certificates*,
   find "Apple Development: Developer ID Application: …". If it doesn't exist,
   create a **Certificate Signing Request** first:
   - Keychain Access → *Certificate Assistant* → *Create a Certificate…*
     → name it `Transcriber DevID` → *Identity Type: Self Signed Identity* →
     *Certificate Authority: Off* → Create.
   - Back on the Apple developer page, upload that `.certSigningRequest`
     instead of clicking Create, then download + import the resulting cert.
   - Now the Developer ID cert and the private key are **paired** under
     *My Certificates* (the triangle is gone).
6. **Export a `.p12`** (this is what CI and other machines consume):
   - Right-click the paired Developer ID cert → *Export…* → choose a strong
     password (you'll store it as a secret) → save as `transcriber-dev-id.p12`.

Keep the `.p12` and its password somewhere secret. Never commit them.

---

## 3. Local signing + notarization (no CI, on your Mac)

This is the manual loop. `build.sh` already honors a small set of environment
variables so you can do this without editing the script.

### 3.1 `.env` template

Copy `.env.example` to `.env` (already git-ignored) and fill it in:

```sh
# --- Transcriber distribution .env (DO NOT COMMIT) ---

# Identity to sign with. Run `security find-identity -v -p codesigning`
# to see the exact string. It looks like:
TRANSCRIBER_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID123)"

# Set to 1 to notarize after building. 0/empty = skip (ad-hoc, local only).
TRANSCRIBER_NOTARIZE=1

# --- Notarization credentials (pick ONE method) ---

# Method 1 (recommended): App Store Connect API key
TRANSCRIBER_ASC_KEY_PATH="$HOME/keys/AuthKey_ABC123.p8"
TRANSCRIBER_ASC_KEY_ID="ABC123XYZ"
TRANSCRIBER_ASC_ISSUER="12345678-1234-1234-1234-123456789abc"

# Method 2 (fallback): Apple ID + app-specific password
# TRANSCRIBER_APPLE_ID="you@example.com"
# TRANSCRIBER_APPLE_PW="abcd-efgh-ijkl-mnop"
```

### 3.2 Build, sign, notarize

```sh
cd /Users/tomasino/git/transcriber
set -a; . ./.env; set +a          # load .env into the environment
bash build.sh                      # builds + signs with your identity
# build.sh notarizes automatically when TRANSCRIBER_NOTARIZE=1
open build/Transcriber.app         # verify it runs
```

`build.sh` will, in order:
1. Build the `.app` (CLT-only, with the SDK fallback).
2. Sign with `TRANSCRIBER_SIGN_IDENTITY` **and** `--options runtime`
   (hardened runtime — required for notarization).
3. If `TRANSCRIBER_NOTARIZE=1`: zip it, submit to Apple's notary service,
   wait for the result, and **staple** the ticket so the app runs offline.

### 3.3 Verify it's properly signed

```sh
codesign -dv --verbose=4 build/Transcriber.app      # shows identity + flags
spctl -a -vvv -t install build/Transcriber.app       # Gatekeeper assessment
xcrun stapler validate build/Transcriber.app          # stapled ticket present?
```

`spctl` should report `accepted`. That's the green light that a fresh Mac will
run it without a warning.

### 3.4 Package for download

```sh
cd build && zip -r Transcriber.zip Transcriber.app
# hand Transcriber.zip to someone; double-click, drag to Applications, run.
```

Because the ticket is stapled, the first launch works with no network.

---

## 4. Bundle identifier

The current ID is `local.transcriber` (see `build.sh`). Before you sign for
real distribution, change it to an ID you **own** (Apple requires the prefix to
match your team), e.g. `com.yourname.transcriber`. It's one line in `build.sh`
(`BUNDLE_ID=`) and in the Info.plist it generates. Do this **before** you
notarize, not after — the ID is part of the signed identity.

---

## 5. GitHub Actions pipeline (the "secrets in CI" part)

This is where **GitHub Secrets** replace the `.env` file. You create the same
values as *repository secrets* (Settings → Secrets and variables → Actions),
and the workflow injects them at build time. They never appear in the repo.

### 5.1 GitHub Secrets to create

| Secret name | Value |
|-------------|-------|
| `TRANSCRIBER_SIGN_IDENTITY` | `Developer ID Application: Your Name (TEAMID123)` |
| `TRANSCRIBER_P12_BASE64` | `base64 < transcriber-dev-id.p12 \| tr -d '\n'` |
| `TRANSCRIBER_P12_PASSWORD` | the `.p12` export password |
| `TRANSCRIBER_ASC_KEY_ID` | `ABC123XYZ` |
| `TRANSCRIBER_ASC_ISSUER` | `12345678-…` |
| `TRANSCRIBER_ASC_KEY` | the raw contents of the `.p8` key file |

### 5.2 Workflow (`.github/workflows/release.yml`)

Copy-paste ready. It builds with `build.sh`, imports the cert, signs,
notarizes, staples, and uploads the `.zip` as a release artifact.

```yaml
name: Release

on:
  push:
    tags: [ "v*" ]          # run on version tags, e.g. v0.1.0
  workflow_dispatch: {}     # and allow manual runs

permissions:
  contents: write           # needed to create the GitHub Release

jobs:
  build-sign-notarize:
    runs-on: macos-15        # needs Xcode/CLT + notarytool
    steps:
      - uses: actions/checkout@v4

      - name: Build + test
        run: bash build.sh test

      - name: Build app
        run: bash build.sh

      - name: Import Developer ID certificate
        env:
          P12_BASE64: ${{ secrets.TRANSCRIBER_P12_BASE64 }}
          P12_PASSWORD: ${{ secrets.TRANSCRIBER_P12_PASSWORD }}
          IDENTITY: ${{ secrets.TRANSCRIBER_SIGN_IDENTITY }}
        run: |
          echo "$P12_BASE64" | base64 --decode > cert.p12
          KEYCHAIN_PATH=$RUNNER_TEMP/app-signing.keychain-db
          security create-keychain -p "$P12_PASSWORD" "$KEYCHAIN_PATH"
          security unlock-keychain -p "$P12_PASSWORD" "$KEYCHAIN_PATH"
          security import cert.p12 -P "$P12_PASSWORD" \
            -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
          security set-key-partition-list -S apple-tool:,apple: \
            -k "$P12_PASSWORD" "$KEYCHAIN_PATH"
          security list-keychains -d user -s "$KEYCHAIN_PATH" \
            $(security list-keychains -d user | tr -d '"' | tr '\n' ' ')
          echo "TRANSCRIBER_SIGN_IDENTITY=$IDENTITY" >> "$GITHUB_ENV"
          echo "TRANSCRIBER_NOTARIZE=1" >> "$GITHUB_ENV"

      - name: Sign (with identity) + notarize + staple
        run: |
          # build.sh already signed ad-hoc; re-sign with the real identity and
          # run the notarization block.
          TRANSCRIBER_SIGN_IDENTITY="$TRANSCRIBER_SIGN_IDENTITY" \
          TRANSCRIBER_NOTARIZE=1 \
          TRANSCRIBER_ASC_KEY_ID="$TRANSCRIBER_ASC_KEY_ID" \
          TRANSCRIBER_ASC_ISSUER="$TRANSCRIBER_ASC_ISSUER" \
          TRANSCRIBER_ASC_KEY_PATH="$(mktemp /tmp/AuthKey.XXXX.p8)" \
          bash -c 'printf "%s" "$TRANSCRIBER_ASC_KEY" > "$TRANSCRIBER_ASC_KEY_PATH"; bash build.sh sign'
        env:
          TRANSCRIBER_ASC_KEY_ID: ${{ secrets.TRANSCRIBER_ASC_KEY_ID }}
          TRANSCRIBER_ASC_ISSUER: ${{ secrets.TRANSCRIBER_ASC_ISSUER }}
          TRANSCRIBER_ASC_KEY: ${{ secrets.TRANSCRIBER_ASC_KEY }}

      - name: Package
        run: |
          cd build && zip -r Transcriber.zip Transcriber.app

      - name: Upload to release
        uses: softprops/action-gh-release@v2
        with:
          files: build/Transcriber.zip
          generate_release_notes: true
```

> The workflow's "Sign + notarize" step just calls `bash build.sh` with the
> credentials in the environment. `build.sh` reads `TRANSCRIBER_SIGN_IDENTITY`
> and the `TRANSCRIBER_ASC_*` / `TRANSCRIBER_APPLE_*` vars and does the
> sign → notarize → staple steps itself (see its `sign_app` / `notarize_app`
> functions). So local and CI sign identically, and the logic lives in one
> place.

---

## 6. App Store route (Route B) — read before choosing

If you'd rather distribute through the Mac App Store instead:

- Use an **App Store Distribution** certificate (different from Developer ID)
  and an **App ID + provisioning profile** (or the newer App Store Connect
  signing).
- The app **must run in the App Sandbox** (`com.apple.security.app-sandbox`).
  Add entitlements for microphone (`com.apple.security.device.audio-input`)
  and outbound network (`com.apple.security.network.client`).
- **The catch:** the "capture system audio" feature (tapping the system output
  via CoreAudio) is the part that fights the sandbox. Microphone capture is
  fine; system-wide audio is the risk. If that feature is essential, Route A
  (Developer ID, no sandbox) is the pragmatic choice.
- Notarization is handled by the store; you still sign with the App Store
  certificate and upload via `xcrun altool`/Transporter or Xcode.

Recommendation: **ship Route A first** (works with the current architecture),
and treat the App Store as a later option if you decide to drop/rework
system-audio capture.

---

## 7. Entitlements (only if you need them)

The current app needs **no entitlements file** for Route A: outbound network
is allowed under hardened runtime by default, and microphone access is
gated by the `NSMicrophoneUsageDescription` string (already in the
Info.plist) + the TCC prompt.

If you later add a feature that needs one (e.g. AppleScript automation), add a
`Transcriber.entitlements` and pass it to `codesign --entitlements`. For the
App Store route, the sandbox entitlement is mandatory — see §6.

---

## 8. Checklist (copy this when you actually do it)

- [ ] Change `BUNDLE_ID` in `build.sh` to an ID you own (e.g. `com.yourname.transcriber`).
- [ ] Create + import the **Developer ID Application** certificate; export a `.p12`.
- [ ] Create an **App Store Connect API key** (or an app-specific password).
- [ ] Fill in a local `.env` (from `.env.example`) and run
      `bash build.sh` with `TRANSCRIBER_NOTARIZE=1`.
- [ ] Verify: `codesign -dv`, `spctl -a -vvv`, `xcrun stapler validate`.
- [ ] Zip the `.app` and hand it to a **fresh Mac**; confirm no Gatekeeper warning.
- [ ] Create the GitHub Secrets from §5.1.
- [ ] Add `.github/workflows/release.yml` (§5.2).
- [ ] Tag `v0.1.0` and confirm the workflow publishes a notarized `.zip`.

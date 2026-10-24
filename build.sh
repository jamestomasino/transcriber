#!/usr/bin/env bash
#
# build.sh — compile the Transcriber app and its tests using swiftc only
# (no Xcode required). Produces build/Transcriber.app and runs the test suite.
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Transcriber"
BUNDLE_ID="${TRANSCRIBER_BUNDLE_ID:-local.transcriber}"
MIN_MACOS="14.0"
# Build for the host architecture (Apple Silicon or Intel) rather than hardcoding arm64.
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx${MIN_MACOS}"
BUILD="build"
APP_DIR="${BUILD}/${APP_NAME}.app"
BIN_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"

CORE_SRC=(
  Sources/Core/Meeting.swift
  Sources/Core/MeetingPresentation.swift
  Sources/Core/BackgroundProcessing.swift
  Sources/Core/TranscriptCleanup.swift
  Sources/Core/MeetingEngine.swift
  Sources/Core/MeetingStore.swift
  Sources/Core/TranscriberViewModel.swift
  Sources/Core/AudioCapture.swift
  Sources/Core/Pipeline.swift
  Sources/Core/Models.swift
  Sources/Core/Settings.swift
  Sources/Core/HTTP.swift
  Sources/Core/Summary.swift
  Sources/Core/LLM.swift
  Sources/Core/CloudTranscriber.swift
)
APP_SRC=(
  Sources/App/TranscriberApp.swift
  Sources/App/AppStorage.swift
  Sources/App/ContentView.swift
  Sources/App/MeetingDetailView.swift
  Sources/App/SettingsView.swift
  Sources/App/RealAudioCapture.swift
  Sources/App/SystemAudioTap.swift
  Sources/App/HTTPClient.swift
  Sources/App/AudioDevices.swift
  Sources/App/AudioPreparation.swift
  Sources/App/OnboardingView.swift
  Sources/App/LocalTranscriber.swift
  Sources/App/LocalSummarizer.swift
  Sources/App/LocalModelAssets.swift
  Sources/App/BackgroundResourceMonitor.swift
  Sources/App/WhisperTranscriber.swift
  Sources/App/LocalSummaryServer.swift
  Sources/App/SummarySectionStore.swift
  Sources/App/SummaryModelManager.swift
  Sources/App/LocalSpeakerDiarizer.swift
  Sources/App/LocalModelSetupView.swift
  Sources/App/ProcessorFactory.swift
  Sources/App/Notifications.swift
)
TEST_SRC=(
  Tests/main.swift
)

echo "==> Cleaning build dir"
rm -rf "$BUILD"
mkdir -p "$BIN_DIR" "$RES_DIR"

# Recent Command Line Tools SDKs (e.g. 27.0) declare SwiftUI's @State/@Observable
# as external macros backed by a "SwiftUIMacros" plugin that is not always
# installed, so compiling any SwiftUI view fails with:
#   external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
# Older SDKs (e.g. 26.5) still compile the same code. We only pay for this probe
# when the default SDK fails, so healthy machines build exactly as before.
find_working_sdk() {
  local probe
  probe="$(mktemp -t suiprobe).swift"
  printf 'import SwiftUI\nstruct V: View { @State var x = 0; var body: some View { Text(\"\\(x)\") } }\n' > "$probe"
  local candidates=()
  local d
  while IFS= read -r d; do
    [ -n "$d" ] && candidates+=("$d")
  done < <(ls -1d \
      /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk \
      /Applications/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.sdk \
      2>/dev/null | sort -V -r)
  local sdk
  for sdk in "${candidates[@]}"; do
    if swiftc -parse-as-library -target "$TARGET" -sdk "$sdk" -typecheck "$probe" >/dev/null 2>&1; then
      rm -f "$probe"
      printf '%s\n' "$sdk"
      return 0
    fi
  done
  rm -f "$probe"
  return 1
}

echo "==> Building app (target ${TARGET})"
build_app_with_sdk() {
  local sdk="$1"
  swiftc \
    -O \
    -parse-as-library \
    -I Sources/CWhisper/include \
    -target "$TARGET" \
    -sdk "$sdk" \
    -module-name "$APP_NAME" \
    -o "$BIN_DIR/${APP_NAME}" \
    "${CORE_SRC[@]}" "${APP_SRC[@]}"
}

DEFAULT_SDK="$(xcrun --sdk macosx --show-sdk-path)"
if ! build_app_with_sdk "$DEFAULT_SDK"; then
  echo "    Default SDK ($DEFAULT_SDK) could not compile SwiftUI; searching for a working SDK…"
  if WORKING_SDK="$(find_working_sdk)"; then
    echo "    Using SDK: $WORKING_SDK"
    build_app_with_sdk "$WORKING_SDK"
  else
    echo "    ERROR: no installed SDK could compile SwiftUI." >&2
    exit 1
  fi
fi

printf '%s\n' "${WORKING_SDK:-$DEFAULT_SDK}" > "${BUILD}/sdk-path"

echo "==> Writing Info.plist"
cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Transcriber</string>
    <key>CFBundleDisplayName</key>     <string>Transcriber</string>
    <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>${MIN_MACOS}</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.productivity</string>
    <key>NSSpeechRecognitionUsageDescription</key> <string>Transcriber uses on-device speech recognition to turn meeting audio into text.</string>
    <key>NSAudioCaptureUsageDescription</key> <string>Transcriber records system audio to transcribe other people’s voices in meetings. No screen or video is captured.</string>
    <key>NSMicrophoneUsageDescription</key> <string>Transcriber records your microphone so it can transcribe what you say during a meeting.</string>
</dict>
</plist>
PLIST

cp Sources/CWhisper/LICENSE "$RES_DIR/Whisper-LICENSE"

# Build the app icon from the SVG source. Primary path uses only system tools
# (qlmanage + sips + iconutil), so the CLT-only build stays intact and no Homebrew
# dependency is needed. If a committed .icns exists and is newer than the SVG,
# reuse it (fast path); otherwise regenerate. Falls back to the committed .icns
# if rendering fails, so a machine without qlmanage can still build.
build_icon() {
  local svg="Resources/AppIcon-mac.svg"
  local committed="Resources/AppIcon.icns"
  local out="$RES_DIR/AppIcon.icns"

  # Fast path: reuse the committed icon when the SVG hasn't changed.
  if [ -f "$committed" ] && [ "$committed" -nt "$svg" ]; then
    cp "$committed" "$out"
    return 0
  fi

  if [ ! -f "$svg" ]; then
    [ -f "$committed" ] && cp "$committed" "$out"
    echo "    (no $svg and no committed icon; app will use the default icon)"
    return 0
  fi

  local work iconset
  work="$(mktemp -d "${TMPDIR:-/tmp}/transcriber-icon.XXXXXX")"
  iconset="$work/AppIcon.iconset"
  mkdir -p "$iconset"

  # Standard macOS iconset: 1x and 2x at each base size.
  local entries=(
    "icon_16x16.png:16"      "icon_16x16@2x.png:32"
    "icon_32x32.png:32"      "icon_32x32@2x.png:64"
    "icon_128x128.png:128"   "icon_128x128@2x.png:256"
    "icon_256x256.png:256"   "icon_256x256@2x.png:512"
    "icon_512x512.png:512"   "icon_512x512@2x.png:1024"
  )
  local e pair px dir src
  for e in "${entries[@]}"; do
    pair="${e%%:*}"; px="${e##*:}"
    dir="$(mktemp -d "$work/ql.XXXXXX")"
    qlmanage -t -s "$px" -o "$dir" "$svg" >/dev/null 2>&1 || true
    src="$(find "$dir" -name '*.png' 2>/dev/null | head -1)"
    if [ -z "$src" ] || [ ! -f "$src" ]; then
      echo "    icon render failed at ${px}px; falling back to committed .icns"
      rm -rf "$work"
      [ -f "$committed" ] && cp "$committed" "$out"
      return 0
    fi
    sips -z "$px" "$px" "$src" --out "${iconset}/${pair}" >/dev/null 2>&1
  done

  if iconutil -c icns "$iconset" -o "$out" 2>/dev/null; then
    echo "==> Built app icon from $svg (system tools)"
  else
    echo "    iconutil failed; falling back to committed .icns"
    [ -f "$committed" ] && cp "$committed" "$out"
  fi
  rm -rf "$work"
}
build_icon

echo "==> Writing PkgInfo"
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

# Sign the .app. Defaults to ad-hoc (runs only on the machine that built it).
# If TRANSCRIBER_SIGN_IDENTITY is set, sign with that identity + hardened
# runtime — the path needed for notarization and distribution to other Macs.
# See docs/DISTRIBUTION.md.
sign_app() {
  local app="$1"
  if [ -n "${TRANSCRIBER_SIGN_IDENTITY:-}" ]; then
    echo "==> Code signing with: ${TRANSCRIBER_SIGN_IDENTITY} (hardened runtime)"
    codesign --force --deep --options runtime --entitlements Resources/Transcriber.entitlements --sign "${TRANSCRIBER_SIGN_IDENTITY}" "${app}"
  else
    echo "==> Ad-hoc code signing (runs only on this machine; set TRANSCRIBER_SIGN_IDENTITY to distribute)"
    codesign --force --deep --sign - "${app}" 2>/dev/null || \
      echo "    (codesign skipped/failed; app may still run)"
  fi
}

# Notarize + staple an already-signed .app. Requires TRANSCRIBER_SIGN_IDENTITY
# to have been used (hardened runtime) and one notarization credential set.
notarize_app() {
  local app="$1"
  local staging zip result=0
  local credentials=()
  if [ -n "${TRANSCRIBER_ASC_KEY_PATH:-}" ]; then
    credentials=(--key "${TRANSCRIBER_ASC_KEY_PATH}"
      --key-id "${TRANSCRIBER_ASC_KEY_ID:?TRANSCRIBER_ASC_KEY_ID required}"
      --issuer "${TRANSCRIBER_ASC_ISSUER:?TRANSCRIBER_ASC_ISSUER required}")
  elif [ -n "${TRANSCRIBER_APPLE_ID:-}" ]; then
    credentials=(--apple-id "${TRANSCRIBER_APPLE_ID}"
      --team-id "${TRANSCRIBER_TEAM_ID:?TRANSCRIBER_TEAM_ID required}"
      --password "${TRANSCRIBER_APPLE_PW:?TRANSCRIBER_APPLE_PW required}")
  else
    echo "    ERROR: no notarization credentials. Set TRANSCRIBER_ASC_* or TRANSCRIBER_APPLE_ID." >&2
    return 1
  fi
  staging="$(mktemp -d /tmp/transcriber-notary.XXXXXX)"
  zip="${staging}/Transcriber.zip"
  # A recursive archive is essential: zipping only the directory entry sends
  # Apple an empty app. ditto also preserves bundle metadata and symlinks.
  if ditto -c -k --keepParent "$app" "$zip"; then
    echo "==> Notarizing $(basename "${app}") …"
    xcrun notarytool submit "$zip" "${credentials[@]}" --wait || result=$?
    if [ "$result" -eq 0 ]; then
      echo "==> Stapling ticket"
      xcrun stapler staple "$app" || result=$?
    fi
  else
    result=$?
  fi
  rm -rf "$staging"
  return "$result"
}

sign_app "${APP_DIR}"

# If we just built with a real identity and notarization is enabled, do it now.
if [ -n "${TRANSCRIBER_SIGN_IDENTITY:-}" ] && [ "${TRANSCRIBER_NOTARIZE:-0}" = "1" ]; then
  notarize_app "${APP_DIR}"
fi

MODE="${1:-build}"

if [ "$MODE" = "test" ]; then
  echo "==> Building + running tests"
  swiftc \
    -target "$TARGET" \
    -module-name "${APP_NAME}Tests" \
    -o "${BUILD}/tests" \
    "${CORE_SRC[@]}" "${TEST_SRC[@]}"
  echo "==> Running test executable"
  "${BUILD}/tests"
  echo "==> Building + running media checks"
  swiftc -parse-as-library -I Sources/CWhisper/include -target "$TARGET" -sdk "${WORKING_SDK:-$DEFAULT_SDK}" \
    -o "${BUILD}/app-checks" "${CORE_SRC[@]}" \
    Sources/App/AppStorage.swift Sources/App/AudioPreparation.swift Sources/App/LocalTranscriber.swift Sources/App/SystemAudioTap.swift Sources/App/LocalModelAssets.swift Sources/App/WhisperTranscriber.swift Sources/App/LocalSummaryServer.swift Sources/App/SummarySectionStore.swift Sources/App/SummaryModelManager.swift Sources/App/HTTPClient.swift Sources/App/LocalSpeakerDiarizer.swift Validation/AppChecks.swift
  "${BUILD}/app-checks"
  echo
  echo "    Tests: ${BUILD}/tests"
fi

echo
echo "==> Done."
echo "    App:  ${APP_DIR}"
echo "    Run:  open ${APP_DIR}"
echo
echo "Usage:  bash build.sh          # build the app"
echo "        bash build.sh test     # build the app + run the test suite"

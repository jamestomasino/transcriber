#!/usr/bin/env bash
#
# build.sh — compile the Transcriber app and its tests using swiftc only
# (no Xcode required). Produces build/Transcriber.app and runs the test suite.
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Transcriber"
BUNDLE_ID="local.transcriber"
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
  Sources/Core/MeetingEngine.swift
  Sources/Core/TranscriberViewModel.swift
  Sources/Core/AudioCapture.swift
)
APP_SRC=(
  Sources/App/TranscriberApp.swift
  Sources/App/ContentView.swift
  Sources/App/RealAudioCapture.swift
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
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>${MIN_MACOS}</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.productivity</string>
    <key>NSMicrophoneUsageDescription</key> <string>Transcriber records your microphone so it can transcribe what you say during a meeting.</string>
</dict>
</plist>
PLIST

echo "==> Writing PkgInfo"
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

echo "==> Ad-hoc code signing (required to launch a GUI app)"
codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || \
  echo "    (codesign skipped/failed; app may still run)"

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

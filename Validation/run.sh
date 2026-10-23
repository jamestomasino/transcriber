#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-live}"
case "$MODE" in
  live) APP_SRC=(Sources/App/AudioDevices.swift Sources/App/RealAudioCapture.swift Sources/App/LocalTranscriber.swift Sources/App/LocalSummarizer.swift); ENTRY=Validation/LiveChecks.swift ;;
  preview) APP_SRC=(Sources/App/ContentView.swift Sources/App/MeetingDetailView.swift Sources/App/SettingsView.swift Sources/App/OnboardingView.swift Sources/App/AudioDevices.swift Sources/App/HTTPClient.swift); ENTRY=Validation/Preview.swift ;;
  *) echo 'Usage: bash Validation/run.sh live|preview [--empty]' >&2; exit 1 ;;
esac
if [ ! -f build/sdk-path ]; then bash build.sh test; fi
IFS= read -r VALIDATION_SDK < build/sdk-path
BIN="build/validation-${MODE}"
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" -sdk "$VALIDATION_SDK" \
  -o "$BIN" Sources/Core/*.swift "${APP_SRC[@]}" "$ENTRY"
if [ "$MODE" = live ]; then
  "$BIN"
else
  BUNDLE=build/TranscriberValidation.app
  mkdir -p "$BUNDLE/Contents/MacOS"
  cp "$BIN" "$BUNDLE/Contents/MacOS/TranscriberValidation"
  cp build/Transcriber.app/Contents/Info.plist "$BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.transcriber.validation' "$BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable TranscriberValidation' "$BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName Transcriber Validation' "$BUNDLE/Contents/Info.plist"
  codesign --force --sign - "$BUNDLE"
  open -n "$BUNDLE" --args "${@:2}"
fi

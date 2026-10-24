#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-live}"
case "$MODE" in
  live) APP_SRC=(Sources/App/AudioDevices.swift Sources/App/RealAudioCapture.swift Sources/App/SystemAudioTap.swift Sources/App/LocalTranscriber.swift Sources/App/LocalSummarizer.swift); ENTRY=Validation/LiveChecks.swift ;;
  models) APP_SRC=(Sources/App/LocalModelAssets.swift Sources/App/SummaryModelManager.swift Sources/App/HTTPClient.swift Sources/App/WhisperTranscriber.swift Sources/App/LocalSummaryServer.swift Sources/App/AudioPreparation.swift Sources/App/LocalTranscriber.swift); ENTRY=Validation/LocalInferenceChecks.swift ;;
  preview) APP_SRC=(Sources/App/LocalModelAssets.swift Sources/App/SummaryModelManager.swift Sources/App/LocalSummaryServer.swift Sources/App/LocalModelSetupView.swift Sources/App/LocalSpeakerDiarizer.swift Sources/App/WhisperTranscriber.swift Sources/App/AudioPreparation.swift Sources/App/LocalTranscriber.swift Sources/App/ContentView.swift Sources/App/MeetingDetailView.swift Sources/App/SettingsView.swift Sources/App/OnboardingView.swift Sources/App/SystemAudioTap.swift Sources/App/AudioDevices.swift Sources/App/HTTPClient.swift); ENTRY=Validation/Preview.swift ;;
  *) echo 'Usage: bash Validation/run.sh live [--system-audio] | preview [--empty]' >&2; exit 1 ;;
esac
if [ ! -f build/sdk-path ]; then bash build.sh test; fi
IFS= read -r VALIDATION_SDK < build/sdk-path
BIN="build/validation-${MODE}"
LINK_FLAGS=()
if [ "$MODE" = live ]; then
  # A console helper also needs the audio usage description before opting in.
  LIVE_PLIST=build/validation-live-info.plist
  cp build/Transcriber.app/Contents/Info.plist "$LIVE_PLIST"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.transcriber.live-validation' "$LIVE_PLIST"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable validation-live' "$LIVE_PLIST"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName Transcriber Live Validation' "$LIVE_PLIST"
  LINK_FLAGS=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist
    -Xlinker "$LIVE_PLIST")
fi
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" -sdk "$VALIDATION_SDK" \
  -I Sources/CWhisper/include "${LINK_FLAGS[@]}" -o "$BIN" Sources/Core/*.swift "${APP_SRC[@]}" "$ENTRY"
if [ "$MODE" = live ] || [ "$MODE" = models ]; then
  "$BIN" "${@:2}"
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

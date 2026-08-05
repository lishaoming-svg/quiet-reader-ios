#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

xcodegen generate
SIMULATOR_ID="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ {print $2; exit}')"
if [[ -z "$SIMULATOR_ID" ]]; then
  echo "没有可用的 iPhone 模拟器" >&2
  exit 1
fi

RUN_LIVE_SOURCE_TESTS=1 xcodebuild \
  -project QuietReader.xcodeproj \
  -scheme QuietReader \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath build/live-source-tests \
  -only-testing:QuietReaderTests/DalanglangLiveIntegrationTests \
  CODE_SIGNING_ALLOWED=NO \
  test

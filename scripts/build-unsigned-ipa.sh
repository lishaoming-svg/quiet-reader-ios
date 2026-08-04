#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

xcodegen generate
xcodebuild \
  -project QuietReader.xcodeproj \
  -scheme QuietReader \
  -configuration Debug \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/device \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP_PATH="$(find build/device/Build/Products/Debug-iphoneos -maxdepth 1 -name '*.app' -print -quit)"
if [[ -z "$APP_PATH" ]]; then
  echo "未找到设备构建产物" >&2
  exit 1
fi

rm -rf build/package build/QuietReader-unsigned.ipa
mkdir -p build/package/Payload
cp -R "$APP_PATH" build/package/Payload/

cd build/package
/usr/bin/zip -qry ../QuietReader-unsigned.ipa Payload
echo "已生成 build/QuietReader-unsigned.ipa"

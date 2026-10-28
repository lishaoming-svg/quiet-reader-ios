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

for resource in community-sources.json demo-source.json Assets.car; do
  if [[ ! -e "$APP_PATH/$resource" ]]; then
    echo "应用包缺少资源：$resource" >&2
    exit 1
  fi
done

# Dynamic Swift packages must be inside the app, not just available in Xcode's build directory.
KINDLE_FRAMEWORK="$APP_PATH/Frameworks/KindleDocumentKit.framework/KindleDocumentKit"
if [[ ! -f "$KINDLE_FRAMEWORK" ]]; then
  echo "应用包缺少 KindleDocumentKit 动态库，无法在设备上独立启动" >&2
  exit 1
fi
APP_BINARY="$APP_PATH/QuietReader"
if [[ -f "$APP_PATH/QuietReader.debug.dylib" ]]; then
  APP_BINARY="$APP_PATH/QuietReader.debug.dylib"
fi
/usr/bin/otool -L "$APP_BINARY" | /usr/bin/grep 'KindleDocumentKit.framework/KindleDocumentKit'

rm -rf build/package build/QuietReader-unsigned.ipa
mkdir -p build/package/Payload
cp -R "$APP_PATH" build/package/Payload/

cd build/package
/usr/bin/zip -qry ../QuietReader-unsigned.ipa Payload
echo "已生成 build/QuietReader-unsigned.ipa"

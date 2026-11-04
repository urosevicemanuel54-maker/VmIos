#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/ios/VirtualiOS.xcodeproj"
SCHEME="VirtualiOS"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/VirtualiOS.app"
PACKAGE_DIR="$ROOT_DIR/build/package"
IPA_PATH="$ROOT_DIR/build/VirtualiOS-unsigned.ipa"

if [[ ! -d "$PROJECT" ]]; then
  echo "error: Xcode project not found: $PROJECT" >&2
  exit 1
fi

bash "$ROOT_DIR/scripts/build-qemu-ios.sh"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app product was not created: $APP_PATH" >&2
  exit 1
fi

QEMU_SYSROOT="$ROOT_DIR/build/utm-qemu/UTM/sysroot-iOS-TCI-arm64"
FRAMEWORKS_PATH="$APP_PATH/Frameworks"
mkdir -p "$FRAMEWORKS_PATH"
while IFS= read -r -d '' library; do
  cp -pL "$library" "$FRAMEWORKS_PATH/"
done < <(find "$QEMU_SYSROOT" -name '*.dylib' -print0)

rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR/Payload"
ditto "$APP_PATH" "$PACKAGE_DIR/Payload/VirtualiOS.app"

(
  cd "$PACKAGE_DIR"
  /usr/bin/zip -qry "$IPA_PATH" Payload
)

if [[ ! -s "$IPA_PATH" ]]; then
  echo "error: IPA packaging failed" >&2
  exit 1
fi

echo "Created unsigned IPA: $IPA_PATH"
echo "This IPA requires signing with a valid iOS signing identity before installation."

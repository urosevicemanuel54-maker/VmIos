#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Vortex.xcodeproj"
SCHEME="Vortex"
BUILD_ROOT="$ROOT_DIR/build"
DERIVED_DATA="$BUILD_ROOT/VortexDerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/Vortex.app"
IPA_PATH="$BUILD_ROOT/Vortex-unsigned.ipa"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild is required; run this script on macOS with Xcode installed" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: xcrun is required; install Xcode and select it with xcode-select" >&2
  exit 1
fi

if [[ ! -d "$PROJECT" ]]; then
  echo "error: Xcode project not found: $PROJECT" >&2
  exit 1
fi

SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
SDK_MAJOR="${SDK_VERSION%%.*}"
if [[ ! "$SDK_MAJOR" =~ ^[0-9]+$ ]] || (( SDK_MAJOR < 26 )); then
  echo "error: iOS 26 SDK or newer is required; found $SDK_VERSION" >&2
  exit 1
fi

mkdir -p "$BUILD_ROOT"
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

PACKAGE_DIR="$(mktemp -d "$BUILD_ROOT/vortex-package.XXXXXX")"
trap 'rm -rf "$PACKAGE_DIR"' EXIT
mkdir -p "$PACKAGE_DIR/Payload"
ditto "$APP_PATH" "$PACKAGE_DIR/Payload/Vortex.app"
(
  cd "$PACKAGE_DIR"
  /usr/bin/zip -qry "$IPA_PATH" Payload
)

if [[ ! -s "$IPA_PATH" ]]; then
  echo "error: IPA packaging failed" >&2
  exit 1
fi

echo "Created unsigned IPA: $IPA_PATH"
echo "This IPA must be signed with a development or distribution identity before installation."

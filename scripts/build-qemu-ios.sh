#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$ROOT_DIR/build/utm-qemu"
UTM_SOURCE="$BUILD_ROOT/UTM"
PYTHON_ENV="$BUILD_ROOT/python-env"
UTM_REF="a6e0c06957ab5a32b960499ba3a286c37852e37a"

brew install \
  autoconf \
  automake \
  cmake \
  gettext \
  glib-utils \
  libgpg-error \
  libtool \
  libxcb \
  libxrandr \
  llvm \
  meson \
  nasm \
  ninja \
  pkg-config \
  spirv-llvm-translator

export PATH="$(brew --prefix llvm)/bin:$PATH"

mkdir -p "$BUILD_ROOT"
python3 -m venv "$PYTHON_ENV"
"$PYTHON_ENV/bin/python3" -m pip install \
  distlib \
  mako \
  pyyaml \
  pyparsing \
  setuptools \
  six

if [[ ! -d "$UTM_SOURCE/.git" ]]; then
  git init "$UTM_SOURCE"
  git -C "$UTM_SOURCE" remote add origin https://github.com/utmapp/UTM.git
fi

git -C "$UTM_SOURCE" fetch --depth 1 origin "$UTM_REF"
git -C "$UTM_SOURCE" checkout --detach FETCH_HEAD

source "$PYTHON_ENV/bin/activate"
(
  cd "$UTM_SOURCE"
  bash scripts/build_dependencies.sh -p ios-tci -a arm64
)

QEMU_SYSROOT="$UTM_SOURCE/sysroot-iOS-TCI-arm64"
if [[ ! -d "$QEMU_SYSROOT" ]]; then
  echo "error: expected iOS QEMU sysroot was not created: $QEMU_SYSROOT" >&2
  exit 1
fi

QEMU_LIBRARY="$(find "$QEMU_SYSROOT" -type f -name '*qemu*.dylib' -print -quit)"
if [[ -z "$QEMU_LIBRARY" ]]; then
  echo "error: no QEMU dynamic library was created in $QEMU_SYSROOT" >&2
  find "$QEMU_SYSROOT" -type f -iname '*qemu*' -print >&2
  exit 1
fi

if ! xcrun lipo -verify_arch arm64 "$QEMU_LIBRARY"; then
  echo "error: QEMU library is not built for iOS arm64: $QEMU_LIBRARY" >&2
  exit 1
fi

QEMU_OUTPUT_DIR="$ROOT_DIR/build/VirtualiOS-QEMU"
mkdir -p "$QEMU_OUTPUT_DIR"
cp "$QEMU_LIBRARY" "$QEMU_OUTPUT_DIR/"

echo "Built iOS ARM64 QEMU TCI library: $QEMU_LIBRARY"
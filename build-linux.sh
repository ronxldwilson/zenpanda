#!/usr/bin/env bash
set -euo pipefail

# Build ZenPanda for Linux from macOS using native resources (full RAM).
# Produces: dist/zenpanda (Linux arm64 or amd64 binary)
# Usage:    ./build-linux.sh [aarch64|x86_64]

ARCH="${1:-aarch64}"
V8_VERSION="14.0.365.4"
ZIG_V8_TAG="v0.4.5"
DIST_DIR="dist"

case "$ARCH" in
  aarch64) RUST_TARGET="aarch64-unknown-linux-gnu" ; ZIG_TARGET="aarch64-linux-gnu" ;;
  x86_64)  RUST_TARGET="x86_64-unknown-linux-gnu"  ; ZIG_TARGET="x86_64-linux-gnu" ;;
  *) echo "Usage: $0 [aarch64|x86_64]"; exit 1 ;;
esac

ZIG_VERSION=$(grep '\.minimum_zig_version = "' build.zig.zon | cut -d'"' -f2)
echo "==> Zig version required: $ZIG_VERSION"
echo "==> Target: ${ZIG_TARGET}"

# --- 1. Install Zig if needed ---
ZIG_CMD=""
if command -v zig &>/dev/null && [[ "$(zig version)" == "$ZIG_VERSION" ]]; then
  echo "==> Zig $ZIG_VERSION already installed"
  ZIG_CMD="zig"
else
  ZIG_OS_ARCH="$(uname -m)"
  [[ "$ZIG_OS_ARCH" == "arm64" ]] && ZIG_OS_ARCH="aarch64"
  ZIG_DIR=".toolchain/zig-${ZIG_OS_ARCH}-macos-${ZIG_VERSION}"
  ZIG_CMD="$(pwd)/${ZIG_DIR}/zig"

  if [ -x "$ZIG_CMD" ]; then
    echo "==> Zig $ZIG_VERSION already in .toolchain"
  else
    echo "==> Installing Zig $ZIG_VERSION..."
    ZIG_TARBALL="zig-${ZIG_OS_ARCH}-macos-${ZIG_VERSION}.tar.xz"
    ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TARBALL}"
    mkdir -p .toolchain
    curl --fail -L --retry 3 --retry-delay 2 -o ".toolchain/${ZIG_TARBALL}" "$ZIG_URL"
    tar xf ".toolchain/${ZIG_TARBALL}" -C .toolchain
    rm ".toolchain/${ZIG_TARBALL}"
    echo "==> Zig installed at ${ZIG_DIR}"
  fi
fi

# --- 2. Download Linux V8 prebuilt if needed ---
V8_FILE="v8/libc_v8_linux_${ARCH}.a"
mkdir -p v8
if [ -f "$V8_FILE" ]; then
  echo "==> Linux V8 already downloaded"
else
  echo "==> Downloading Linux V8 (${ARCH})..."
  curl --fail -L --retry 3 --retry-delay 2 \
    -o "$V8_FILE" \
    "https://github.com/lightpanda-io/zig-v8-fork/releases/download/${ZIG_V8_TAG}/libc_v8_${V8_VERSION}_linux_${ARCH}.a"
  echo "==> V8 downloaded ($(du -h "$V8_FILE" | cut -f1))"
fi

# --- 3. Build html5ever for Linux via cargo-zigbuild ---
HTML5EVER_LIB=".html5ever-linux/${RUST_TARGET}/release/liblitefetch_html5ever.a"
if [ -f "$HTML5EVER_LIB" ]; then
  echo "==> html5ever already built for ${RUST_TARGET}"
else
  echo "==> Building html5ever for Linux (${RUST_TARGET})..."
  if ! command -v cargo-zigbuild &>/dev/null; then
    echo "==> Installing cargo-zigbuild..."
    cargo install cargo-zigbuild
  fi
  rustup target add "$RUST_TARGET" 2>/dev/null || true

  PATH="$(dirname "$ZIG_CMD"):$PATH" cargo zigbuild --release \
    --target "$RUST_TARGET" \
    --manifest-path src/html5ever/Cargo.toml \
    --target-dir .html5ever-linux
  echo "==> html5ever built"
fi

# --- 4. Build snapshot (runs on host, needs macOS V8) ---
if [ -f "src/snapshot.bin" ]; then
  echo "==> snapshot.bin already exists, skipping"
else
  echo "==> Building snapshot creator (native)..."
  MACOS_ARCH="$(uname -m)"
  [[ "$MACOS_ARCH" == "arm64" ]] && MACOS_ARCH="aarch64"
  MACOS_V8="v8/libc_v8_macos_${MACOS_ARCH}.a"

  if [ ! -f "$MACOS_V8" ]; then
    echo "==> Downloading macOS V8 for snapshot creator..."
    curl --fail -L --retry 3 --retry-delay 2 \
      -o "$MACOS_V8" \
      "https://github.com/lightpanda-io/zig-v8-fork/releases/download/${ZIG_V8_TAG}/libc_v8_${V8_VERSION}_macos_${MACOS_ARCH}.a"
    echo "==> macOS V8 downloaded ($(du -h "$MACOS_V8" | cut -f1))"
  fi

  "$ZIG_CMD" build -Doptimize=ReleaseFast \
    -Dprebuilt_v8_path="$MACOS_V8" \
    snapshot_creator -- src/snapshot.bin
  echo "==> snapshot.bin created"
fi

# --- 5. Build main binary (cross-compile to Linux) ---
echo "==> Building zenpanda for Linux (${ZIG_TARGET})..."
"$ZIG_CMD" build \
  -Dtarget="${ZIG_TARGET}" \
  -Doptimize=ReleaseFast \
  -Dsnapshot_path=../../snapshot.bin \
  -Dprebuilt_v8_path="$V8_FILE" \
  -Dprebuilt_html5ever_path="$HTML5EVER_LIB"

# --- 6. Copy to dist ---
mkdir -p "$DIST_DIR"
cp "zig-out/bin/zenpanda" "${DIST_DIR}/zenpanda"
echo ""
echo "==> Build complete: ${DIST_DIR}/zenpanda ($(du -h "${DIST_DIR}/zenpanda" | cut -f1))"
echo "==> Now run: docker build -f Dockerfile.package -t zenpanda:dev ."

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUTPUT_DIR_INPUT="${1:-dist/desktop/flutter/linux}"
case "$OUTPUT_DIR_INPUT" in
  /*) OUTPUT_DIR="$OUTPUT_DIR_INPUT" ;;
  *) OUTPUT_DIR="$ROOT/$OUTPUT_DIR_INPUT" ;;
esac

if command -v flutter >/dev/null 2>&1; then
  FLUTTER=(flutter)
elif [ -x "$ROOT/flutter/bin/flutter" ]; then
  FLUTTER=("$ROOT/flutter/bin/flutter")
else
  echo "[ERROR] 未找到 flutter 命令，也未找到仓库内 SDK：$ROOT/flutter/bin/flutter" >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "[ERROR] 未找到 cargo 命令，无法构建 furry_ffi" >&2
  exit 1
fi

if ! command -v clang++ >/dev/null 2>&1; then
  echo "[ERROR] 未找到 clang++，无法构建 Flutter Linux 桌面包。请先安装 clang。" >&2
  exit 1
fi

"$ROOT/apps/furry_flutter/create_flutter_app.sh" --no-android

cargo --version
rustc --version
cargo build --release -p furry_ffi -v

cd "$ROOT/apps/furry_flutter/furry_flutter_app"
"${FLUTTER[@]}" config --enable-linux-desktop
"${FLUTTER[@]}" analyze
"${FLUTTER[@]}" build linux --release --verbose

LIB_SRC="$ROOT/target/release/libfurry_ffi.so"
LIB_DST="build/linux/x64/release/bundle/libfurry_ffi.so"
if [ ! -f "$LIB_SRC" ]; then
  echo "[ERROR] Missing furry_ffi library: $LIB_SRC" >&2
  exit 1
fi

cp -f "$LIB_SRC" "$LIB_DST"
test -f "$LIB_DST"

mkdir -p "$OUTPUT_DIR"
tar -C build/linux/x64/release -czf "$OUTPUT_DIR/furry_flutter_linux.tar.gz" bundle

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/apps/furry_flutter/furry_flutter_app"

want_android=0
want_linux=0
want_analyze=1
want_debug=1

usage() {
  cat <<EOF
Usage: $0 [--android] [--linux] [--no-analyze] [--release]

Runs local verification for the generated Flutter app:
- creates/refreshes apps/furry_flutter/furry_flutter_app from templates
- runs flutter analyze (default)
- builds requested targets

Examples:
  $0 --linux
  $0 --android --release
  $0 --android --linux
EOF
}

while [ "${1:-}" != "" ]; do
  case "$1" in
    --android) want_android=1 ;;
    --linux) want_linux=1 ;;
    --no-analyze) want_analyze=0 ;;
    --release) want_debug=0 ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "[ERROR] Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

if [ "$want_android" -eq 0 ] && [ "$want_linux" -eq 0 ]; then
  want_linux=1
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "[ERROR] flutter not found in PATH" >&2
  exit 1
fi

cd "$ROOT"

if [ "$want_android" -eq 1 ]; then
  echo "[INFO] Android verify..."
  ./apps/furry_flutter/create_flutter_app.sh --no-ffi
  (
    cd "$APP_DIR"
    [ "$want_analyze" -eq 1 ] && flutter analyze
    if [ "$want_debug" -eq 1 ]; then
      flutter build apk --debug
    else
      flutter build apk --release
    fi
  )
fi

if [ "$want_linux" -eq 1 ]; then
  echo "[INFO] Linux desktop verify..."
  ./apps/furry_flutter/create_flutter_app.sh --no-android
  cargo build --release -p furry_ffi
  (
    cd "$APP_DIR"
    flutter config --enable-linux-desktop
    [ "$want_analyze" -eq 1 ] && flutter analyze
    flutter build linux --release
    cp -f "$ROOT/target/release/libfurry_ffi.so" build/linux/x64/release/bundle/
    test -f build/linux/x64/release/bundle/libfurry_ffi.so
  )
fi

echo "[INFO] OK"


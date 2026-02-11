#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MODE="${1:-}"
OUTPUT_DIR_INPUT="${2:-dist/android/flutter}"

usage() {
  cat <<USAGE
Usage: $0 <debug|release> [output_dir]

debug:   Build app-debug.apk
release: Build release APKs + app-release.aab (requires signing env vars)
USAGE
}

if [ -z "$MODE" ]; then
  usage >&2
  exit 2
fi

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

APP_DIR="$ROOT/apps/furry_flutter/furry_flutter_app"
mkdir -p "$OUTPUT_DIR"

"$ROOT/apps/furry_flutter/create_flutter_app.sh" --no-ffi

pushd "$APP_DIR" >/dev/null
case "$MODE" in
  debug)
    "${FLUTTER[@]}" analyze
    "${FLUTTER[@]}" build apk --debug --verbose
    cp -f build/app/outputs/flutter-apk/app-debug.apk "$OUTPUT_DIR/"
    ;;
  release)
    required_vars=(
      ANDROID_KEYSTORE_BASE64
      ANDROID_KEYSTORE_PASSWORD
      ANDROID_KEY_ALIAS
      ANDROID_KEY_PASSWORD
    )
    for var_name in "${required_vars[@]}"; do
      if [ -z "${!var_name:-}" ]; then
        echo "[ERROR] Missing required signing env: $var_name" >&2
        echo "        See docs/github_actions.md for required secrets." >&2
        exit 2
      fi
    done

    mkdir -p android/app
    printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 -d > android/app/upload-keystore.jks
    cat > android/key.properties <<KEYS
storePassword=$ANDROID_KEYSTORE_PASSWORD
keyPassword=$ANDROID_KEY_PASSWORD
keyAlias=$ANDROID_KEY_ALIAS
storeFile=upload-keystore.jks
KEYS

    "${FLUTTER[@]}" analyze
    "${FLUTTER[@]}" build apk --release --split-per-abi --verbose
    "${FLUTTER[@]}" build appbundle --release --verbose

    cp -f build/app/outputs/flutter-apk/app-*-release.apk "$OUTPUT_DIR/" || true
    cp -f build/app/outputs/bundle/release/app-release.aab "$OUTPUT_DIR/"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
popd >/dev/null

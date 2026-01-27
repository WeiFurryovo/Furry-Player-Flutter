#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT/apps/furry_flutter/furry_flutter_app"

if ! command -v flutter >/dev/null 2>&1; then
  if [ -x "$ROOT/flutter/bin/flutter" ]; then
    export PATH="$ROOT/flutter/bin:$PATH"
  fi
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "[ERROR] 未找到 flutter 命令。请先安装 Flutter SDK，并确保 flutter 在 PATH 中。" >&2
  exit 1
fi

if [ ! -d "$APP_DIR" ]; then
  echo "[ERROR] 未找到生成的 Flutter 工程：$APP_DIR" >&2
  echo "先运行：./apps/furry_flutter/create_flutter_app.sh" >&2
  exit 1
fi

cd "$APP_DIR"

echo "[INFO] pub get"
flutter pub get >/dev/null

echo "[INFO] build appbundle (recommended)"
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols

echo "[INFO] build per-abi apks (for sideload)"
flutter build apk --release --split-per-abi --obfuscate --split-debug-info=build/symbols

echo "[INFO] outputs:"
ls -la build/app/outputs/bundle/release || true
ls -la build/app/outputs/flutter-apk || true


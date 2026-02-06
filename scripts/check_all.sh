#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "[INFO] Formatting Flutter template..."
"$ROOT/flutter/bin/dart" format "$ROOT/apps/furry_flutter/templates/lib/main.dart"

echo "[INFO] Regenerating Flutter app..."
"$ROOT/apps/furry_flutter/create_flutter_app.sh" --no-android --no-ffi

echo "[INFO] Running Flutter analyze..."
(
  cd "$ROOT/apps/furry_flutter/furry_flutter_app"
  "$ROOT/flutter/bin/flutter" analyze
)

echo "[INFO] Running Rust tests..."
(
  cd "$ROOT"
  cargo test
)

echo "[INFO] All checks passed."


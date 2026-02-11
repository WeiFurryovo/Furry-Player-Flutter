#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

if command -v flutter >/dev/null 2>&1; then
  FLUTTER=(flutter)
elif [ -x "$ROOT/flutter/bin/flutter" ]; then
  FLUTTER=("$ROOT/flutter/bin/flutter")
else
  echo "[ERROR] 未找到 flutter 命令，也未找到仓库内 SDK：$ROOT/flutter/bin/flutter" >&2
  exit 1
fi

"$ROOT/apps/furry_flutter/create_flutter_app.sh" --no-android --no-ffi
"$ROOT/apps/furry_flutter/scripts/verify_template_sync.sh"

cd "$ROOT/apps/furry_flutter/furry_flutter_app"
"${FLUTTER[@]}" analyze
"${FLUTTER[@]}" test

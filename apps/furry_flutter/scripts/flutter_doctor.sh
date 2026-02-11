#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
STRICT=0

usage() {
  cat <<USAGE
Usage: $0 [--strict]

--strict  Exit non-zero when \'flutter doctor -v\' reports issues.
USAGE
}

while [ "${1:-}" != "" ]; do
  case "$1" in
    --strict) STRICT=1 ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "[ERROR] Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if command -v flutter >/dev/null 2>&1; then
  FLUTTER=(flutter)
elif [ -x "$ROOT/flutter/bin/flutter" ]; then
  FLUTTER=("$ROOT/flutter/bin/flutter")
else
  echo "[ERROR] 未找到 flutter 命令，也未找到仓库内 SDK：$ROOT/flutter/bin/flutter" >&2
  exit 1
fi

if [ "$STRICT" -eq 1 ]; then
  "${FLUTTER[@]}" doctor -v
  exit $?
fi

set +e
"${FLUTTER[@]}" doctor -v
code=$?
set -e
if [ "$code" -ne 0 ]; then
  echo "[WARN] flutter doctor exited with code $code; continuing as non-strict." >&2
fi

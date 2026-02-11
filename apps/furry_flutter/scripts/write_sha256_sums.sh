#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 <output_file> <file1> [file2 ...]

Example:
  $0 dist/android/flutter/SHA256SUMS.txt dist/android/flutter/app-debug.apk
USAGE
}

if [ "$#" -lt 2 ]; then
  usage >&2
  exit 2
fi

output_file="$1"
shift

mkdir -p "$(dirname "$output_file")"
: > "$output_file"
for file in "$@"; do
  if [ ! -f "$file" ]; then
    echo "[ERROR] Missing file for checksum: $file" >&2
    exit 1
  fi

  hash="$(sha256sum "$file" | cut -d ' ' -f1)"
  printf '%s  %s\n' "$hash" "$(basename "$file")" >> "$output_file"
done

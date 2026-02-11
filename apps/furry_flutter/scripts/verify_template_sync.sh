#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TEMPLATES_DIR="$ROOT/apps/furry_flutter/templates"
APP_DIR="$ROOT/apps/furry_flutter/furry_flutter_app"

if [ ! -d "$APP_DIR/lib" ]; then
  echo "[ERROR] Flutter 工程不存在，无法校验模板同步：$APP_DIR" >&2
  exit 1
fi

check_dir_sync() {
  local src="$1"
  local dst="$2"
  if [ ! -d "$src" ]; then
    return 0
  fi
  if [ ! -d "$dst" ]; then
    echo "[ERROR] 目标目录缺失：$dst" >&2
    exit 1
  fi
  if ! diff -ru --strip-trailing-cr "$src" "$dst"; then
    echo "[ERROR] 模板目录与生成工程不一致：$src <-> $dst" >&2
    exit 1
  fi
}

check_file_sync() {
  local src="$1"
  local dst="$2"
  if [ ! -f "$src" ]; then
    return 0
  fi
  if [ ! -f "$dst" ]; then
    echo "[ERROR] 目标文件缺失：$dst" >&2
    exit 1
  fi
  if ! cmp -s "$src" "$dst"; then
    echo "[ERROR] 模板文件与生成工程不一致：$src <-> $dst" >&2
    diff -u "$src" "$dst" || true
    exit 1
  fi
}

check_dir_sync "$TEMPLATES_DIR/lib" "$APP_DIR/lib"
check_dir_sync "$TEMPLATES_DIR/test" "$APP_DIR/test"
check_file_sync "$TEMPLATES_DIR/analysis_options.yaml" "$APP_DIR/analysis_options.yaml"

echo "[INFO] 模板同步检查通过"

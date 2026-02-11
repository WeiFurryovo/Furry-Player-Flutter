#!/usr/bin/env bash
set -euo pipefail

if ! command -v apt-get >/dev/null 2>&1; then
  echo "[ERROR] 未找到 apt-get，当前脚本仅适用于 Debian/Ubuntu 环境。" >&2
  exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
  APT=(apt-get)
else
  APT=(sudo apt-get)
fi

"${APT[@]}" update
"${APT[@]}" install -y \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev libblkid-dev liblzma-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev

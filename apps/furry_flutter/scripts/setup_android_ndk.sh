#!/usr/bin/env bash
set -euo pipefail

NDK_VERSION="${1:-26.1.10909125}"

if [ -z "${ANDROID_SDK_ROOT:-}" ] && [ -z "${ANDROID_HOME:-}" ]; then
  echo "[ERROR] ANDROID_SDK_ROOT / ANDROID_HOME 未设置，无法安装 Android NDK" >&2
  exit 1
fi

export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME}}"

mkdir -p ~/.android
touch ~/.android/repositories.cfg

sdkmanager --version
sdkmanager --sdk_root="${ANDROID_SDK_ROOT}" --install "cmdline-tools;latest"

# `yes | sdkmanager --licenses` may end with `yes: Broken pipe` under pipefail;
# only enforce sdkmanager's exit code.
set +o pipefail
yes | sdkmanager --sdk_root="${ANDROID_SDK_ROOT}" --licenses >/dev/null
status="${PIPESTATUS[1]}"
set -o pipefail
test "$status" -eq 0

sdkmanager --sdk_root="${ANDROID_SDK_ROOT}" --install "ndk;${NDK_VERSION}"
sdkmanager --sdk_root="${ANDROID_SDK_ROOT}" --list | sed -n '1,120p'

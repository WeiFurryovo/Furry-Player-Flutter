#!/usr/bin/env bash
# Unified release builder for Furry Player (Flutter-first)
#
# Outputs:
# - dist/android/: rust JNI libs; and optionally Flutter APK/AAB if flutter is installed
# - dist/desktop/flutter/: Flutter desktop bundles (linux/windows best-effort)
#
# Legacy (optional):
# - dist/linux/: furry_gui, furry-cli, libfurry_ffi.so
# - dist/windows/: furry-cli.exe, furry_ffi.dll

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; exit 1; }

ensure_cargo() { command -v cargo >/dev/null 2>&1 || err "Rust/cargo 未安装"; }

build_linux() {
  ensure_cargo
  info "Build Linux (legacy Rust GUI + CLI)…"
  cargo build --release -p furry_gui -p furry_cli
  mkdir -p dist/linux
  cp -f target/release/furry_gui dist/linux/
  cp -f target/release/furry-cli dist/linux/
  info "Linux done: dist/linux/"
}

build_linux_ffi() {
  ensure_cargo
  info "Build Linux FFI (for Flutter desktop)…"
  cargo build --release -p furry_ffi
  mkdir -p dist/linux
  cp -f target/release/libfurry_ffi.so dist/linux/ 2>/dev/null || true
}

build_windows_cli() {
  ensure_cargo
  info "Build Windows CLI (legacy, cross)…"

  if ! rustup target list --installed | grep -q "^x86_64-pc-windows-gnu$"; then
    info "Add Rust target x86_64-pc-windows-gnu"
    rustup target add x86_64-pc-windows-gnu
  fi

  if ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
    warn "未找到 mingw-w64-gcc（x86_64-w64-mingw32-gcc），跳过 Windows 交叉编译"
    warn "Ubuntu: sudo apt install gcc-mingw-w64-x86-64"
    warn "Arch: sudo pacman -S mingw-w64-gcc"
    return 0
  fi

  cargo build --release --target x86_64-pc-windows-gnu -p furry_cli
  mkdir -p dist/windows
  cp -f target/x86_64-pc-windows-gnu/release/furry-cli.exe dist/windows/
  info "Windows CLI done: dist/windows/"
}

build_windows_ffi() {
  ensure_cargo
  info "Build Windows FFI (cross)…"

  if ! rustup target list --installed | grep -q "^x86_64-pc-windows-gnu$"; then
    info "Add Rust target x86_64-pc-windows-gnu"
    rustup target add x86_64-pc-windows-gnu
  fi

  if ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
    warn "未找到 mingw-w64-gcc，跳过 Windows FFI 交叉编译"
    return 0
  fi

  cargo build --release --target x86_64-pc-windows-gnu -p furry_ffi
  mkdir -p dist/windows
  cp -f target/x86_64-pc-windows-gnu/release/furry_ffi.dll dist/windows/ 2>/dev/null || true
}

build_android_rust() {
  info "Build Android Rust JNI libs…"
  "$ROOT/build.sh" android
  info "Android Rust libs done: dist/android/"
}

build_android_flutter() {
  if ! command -v flutter >/dev/null 2>&1; then
    warn "flutter 未安装，跳过 Flutter Android APK/AAB 构建"
    warn "安装 Flutter 后运行：./apps/furry_flutter/create_flutter_app.sh"
    return 0
  fi

  info "Create/refresh Flutter app + copy JNI libs…"
  "$ROOT/apps/furry_flutter/create_flutter_app.sh" --no-ffi

  local APP_DIR="$ROOT/apps/furry_flutter/furry_flutter_app"
  if [ ! -d "$APP_DIR" ]; then
    warn "Flutter 工程不存在：$APP_DIR"
    return 0
  fi

  info "Build Flutter Android (APK + AAB)…"
  (cd "$APP_DIR" && flutter build apk --release)
  (cd "$APP_DIR" && flutter build appbundle --release)

  mkdir -p dist/android/flutter
  cp -f "$APP_DIR/build/app/outputs/flutter-apk/app-release.apk" dist/android/flutter/ 2>/dev/null || true
  cp -f "$APP_DIR/build/app/outputs/bundle/release/app-release.aab" dist/android/flutter/ 2>/dev/null || true
  info "Flutter Android done: dist/android/flutter/"
}

build_desktop_flutter() {
  if ! command -v flutter >/dev/null 2>&1; then
    warn "flutter 未安装，跳过 Flutter 桌面构建"
    return 0
  fi

  info "Create/refresh Flutter app…"
  "$ROOT/apps/furry_flutter/create_flutter_app.sh" --no-android || true

  local APP_DIR="$ROOT/apps/furry_flutter/furry_flutter_app"
  if [ ! -d "$APP_DIR" ]; then
    warn "Flutter 工程不存在：$APP_DIR"
    return 0
  fi

  if command -v cargo >/dev/null 2>&1; then
    build_linux_ffi || true
    build_windows_ffi || true
  fi

  info "Build Flutter desktop (linux/windows if enabled)…"
  (cd "$APP_DIR" && flutter build linux --release) || true
  (cd "$APP_DIR" && flutter build windows --release) || true

  # Copy native libs next to the runner executable (best-effort).
  if [ -f "$ROOT/dist/linux/libfurry_ffi.so" ]; then
    cp -f "$ROOT/dist/linux/libfurry_ffi.so" \
      "$APP_DIR/build/linux/x64/release/bundle/" 2>/dev/null || true
  fi
  if [ -f "$ROOT/dist/windows/furry_ffi.dll" ]; then
    cp -f "$ROOT/dist/windows/furry_ffi.dll" \
      "$APP_DIR/build/windows/x64/runner/Release/" 2>/dev/null || true
  fi

  mkdir -p dist/desktop/flutter
  cp -a "$APP_DIR/build/linux/x64/release/bundle" dist/desktop/flutter/linux 2>/dev/null || true
  cp -a "$APP_DIR/build/windows/x64/runner/Release" dist/desktop/flutter/windows 2>/dev/null || true
  info "Flutter desktop done: dist/desktop/flutter/"
}

usage() {
  cat <<EOF
Usage: $0 [flutter-android|flutter-desktop|flutter-all|legacy-linux|legacy-windows|legacy-all]

flutter-android  Build Rust JNI libs + Flutter APK/AAB
flutter-desktop  Build Flutter desktop (linux/windows best-effort) + Rust FFI libs
flutter-all      flutter-android + flutter-desktop (default)

legacy-linux     Build legacy Rust GUI + CLI (Linux)
legacy-windows   Build legacy Windows CLI + FFI (cross, needs mingw-w64)
legacy-all       legacy-linux + legacy-windows
EOF
}

main() {
  local cmd="${1:-flutter-all}"
  case "$cmd" in
    flutter-android)
      build_android_rust
      build_android_flutter
      ;;
    flutter-desktop) build_desktop_flutter ;;
    flutter-all)
      build_android_rust
      build_android_flutter
      build_desktop_flutter
      ;;
    legacy-linux)
      build_linux
      build_linux_ffi || true
      ;;
    legacy-windows)
      build_windows_cli
      build_windows_ffi
      ;;
    legacy-all)
      build_linux
      build_linux_ffi || true
      build_windows_cli
      build_windows_ffi
      ;;
    -h|--help|help) usage ;;
    *) usage; err "Unknown cmd: $cmd" ;;
  esac
}

main "$@"

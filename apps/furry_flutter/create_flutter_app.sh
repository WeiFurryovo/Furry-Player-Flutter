#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT/apps/furry_flutter/furry_flutter_app"
TEMPLATES_DIR="$ROOT/apps/furry_flutter/templates"

BUILD_ANDROID=1
BUILD_FFI=1

usage() {
  cat <<EOF
Usage: $0 [--no-android] [--no-ffi]

--no-android  Skip building/copying Android JNI libs (for desktop CI)
--no-ffi      Skip building Rust FFI library (Android-only CI)
EOF
}

while [ "${1:-}" != "" ]; do
  case "$1" in
    --no-android) BUILD_ANDROID=0 ;;
    --no-ffi) BUILD_FFI=0 ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "[ERROR] Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

if ! command -v flutter >/dev/null 2>&1; then
  echo "[ERROR] 未找到 flutter 命令。请先安装 Flutter SDK，并确保 flutter 在 PATH 中。" >&2
  exit 1
fi

if [ ! -d "$OUT_DIR" ]; then
  echo "[INFO] 创建 Flutter 工程: $OUT_DIR"
  mkdir -p "$(dirname "$OUT_DIR")"
  (cd "$(dirname "$OUT_DIR")" && flutter create --org com.furry --project-name furry_flutter_app --android-language kotlin furry_flutter_app)
else
  echo "[INFO] Flutter 工程已存在，跳过 flutter create"
fi

echo "[INFO] 添加依赖（pub add）"
(cd "$OUT_DIR" && flutter pub add file_picker path_provider just_audio path ffi)

echo "[INFO] 覆盖模板代码"
cp -a "$TEMPLATES_DIR/lib/." "$OUT_DIR/lib/"
cp -a "$TEMPLATES_DIR/android/." "$OUT_DIR/android/"
if [ -d "$TEMPLATES_DIR/test" ]; then
  mkdir -p "$OUT_DIR/test"
  cp -a "$TEMPLATES_DIR/test/." "$OUT_DIR/test/"
fi
if [ -f "$TEMPLATES_DIR/analysis_options.yaml" ]; then
  cp -f "$TEMPLATES_DIR/analysis_options.yaml" "$OUT_DIR/analysis_options.yaml"
fi

if [ "$BUILD_ANDROID" -eq 1 ]; then
  echo "[INFO] 构建 Rust Android 动态库（需要 ANDROID_NDK_HOME）"
  (cd "$ROOT" && ./build.sh android)

  echo "[INFO] 拷贝 libfurry_android.so 到 Flutter jniLibs/"
  mkdir -p "$OUT_DIR/android/app/src/main/jniLibs"
  for ABI in arm64-v8a armeabi-v7a x86_64; do
    if [ -f "$ROOT/dist/android/$ABI/libfurry_android.so" ]; then
      mkdir -p "$OUT_DIR/android/app/src/main/jniLibs/$ABI"
      cp -f "$ROOT/dist/android/$ABI/libfurry_android.so" "$OUT_DIR/android/app/src/main/jniLibs/$ABI/"
    fi
  done
else
  echo "[INFO] 跳过 Android JNI 构建/拷贝（--no-android）"
fi

if [ "$BUILD_FFI" -eq 1 ] && command -v cargo >/dev/null 2>&1; then
  echo "[INFO] 构建 Rust 桌面 FFI 动态库（用于 Flutter Windows/Linux）"
  (cd "$ROOT" && cargo build --release -p furry_ffi) || true
elif [ "$BUILD_FFI" -eq 1 ]; then
  echo "[WARN] 未找到 cargo，跳过桌面 FFI 动态库构建"
else
  echo "[INFO] 跳过桌面 FFI 动态库构建（--no-ffi）"
fi

echo "[INFO] 完成。现在可以运行："
echo "  cd apps/furry_flutter/furry_flutter_app && flutter run"

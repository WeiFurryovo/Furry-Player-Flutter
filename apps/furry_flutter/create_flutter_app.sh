#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT/apps/furry_flutter/furry_flutter_app"
TEMPLATES_DIR="$ROOT/apps/furry_flutter/templates"

BUILD_ANDROID=1
BUILD_FFI=1

patch_android_manifest_for_audio_service() {
  local manifest_file="$OUT_DIR/android/app/src/main/AndroidManifest.xml"
  if [ ! -f "$manifest_file" ]; then
    echo "[WARN] 未找到 AndroidManifest.xml，跳过 audio_service 配置：$manifest_file" >&2
    return 0
  fi

  python3 - "$manifest_file" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, "r", encoding="utf-8").read()
original = text

m_app = re.search(r"\n([ \t]*)<application\b", text)
if not m_app:
  raise SystemExit("AndroidManifest.xml missing <application>")
app_indent = m_app.group(1)
insert_permissions_at = m_app.start() + 1  # after newline, before indentation

m_app_end = re.search(r"\n([ \t]*)</application>", text)
if not m_app_end:
  raise SystemExit("AndroidManifest.xml missing </application>")
insert_service_at = m_app_end.start() + 1  # after newline, before indentation

service_indent = m_app_end.group(1) + (" " * 4)
service_snippet = (
  f"{service_indent}<service\n"
  f"{service_indent}    android:name=\"com.ryanheise.audioservice.AudioService\"\n"
  f"{service_indent}    android:exported=\"false\"\n"
  f"{service_indent}    android:foregroundServiceType=\"mediaPlayback\" />\n"
  "\n"
)

permissions = [
  f"{app_indent}<uses-permission android:name=\"android.permission.POST_NOTIFICATIONS\" />\n",
  f"{app_indent}<uses-permission android:name=\"android.permission.FOREGROUND_SERVICE\" />\n",
  f"{app_indent}<uses-permission android:name=\"android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK\" />\n",
  f"{app_indent}<uses-permission android:name=\"android.permission.WAKE_LOCK\" />\n",
]

if "com.ryanheise.audioservice.AudioService" not in text:
  text = text[:insert_service_at] + service_snippet + text[insert_service_at:]
  # If we inserted service before the application close tag, permission insertion index stays valid.

for p in permissions:
  if p.strip() not in text:
    text = text[:insert_permissions_at] + p + text[insert_permissions_at:]
    insert_permissions_at += len(p)

if text != original:
  open(path, "w", encoding="utf-8").write(text)
PY
}

patch_android_gradle_for_release_shrink() {
  local gradle_file="$OUT_DIR/android/app/build.gradle"
  if [ ! -f "$gradle_file" ]; then
    echo "[WARN] 未找到 android/app/build.gradle，跳过 R8/资源压缩配置：$gradle_file" >&2
    return 0
  fi

  # Ensure a proguard rules file exists (required when enabling minify).
  local proguard_file="$OUT_DIR/android/app/proguard-rules.pro"
  if [ ! -f "$proguard_file" ]; then
    cat >"$proguard_file" <<'EOF'
# Keep Flutter classes referenced via reflection.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
EOF
  fi

  python3 - "$gradle_file" <<'PY'
import sys

path = sys.argv[1]
text = open(path, "r", encoding="utf-8").read()
original = text

def find_block_start(needle: str, start: int = 0) -> int:
  idx = text.find(needle, start)
  return idx

def find_matching_brace(open_brace_idx: int) -> int:
  depth = 0
  i = open_brace_idx
  while i < len(text):
    c = text[i]
    if c == "{":
      depth += 1
    elif c == "}":
      depth -= 1
      if depth == 0:
        return i
    i += 1
  return -1

bt_idx = find_block_start("buildTypes")
if bt_idx == -1:
  sys.exit(0)

bt_brace = text.find("{", bt_idx)
if bt_brace == -1:
  sys.exit(0)

bt_end = find_matching_brace(bt_brace)
if bt_end == -1:
  sys.exit(0)

rel_idx = text.find("release", bt_brace, bt_end)
if rel_idx == -1:
  sys.exit(0)

rel_brace = text.find("{", rel_idx, bt_end)
if rel_brace == -1:
  sys.exit(0)

rel_end = find_matching_brace(rel_brace)
if rel_end == -1:
  sys.exit(0)

release_block = text[rel_brace:rel_end + 1]

def has_line(substr: str) -> bool:
  return substr in release_block

lines_to_ensure = [
  "minifyEnabled true",
  "shrinkResources true",
  "proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'",
]

missing = [l for l in lines_to_ensure if not has_line(l)]
if not missing:
  sys.exit(0)

# Indent: take indentation of the release line and add 4 spaces.
line_start = text.rfind("\n", 0, rel_idx) + 1
line_prefix = text[line_start:rel_idx]
base_indent = line_prefix + "    "

insert_at = text.find("\n", rel_brace) + 1
to_insert = "".join(f"{base_indent}{l}\n" for l in missing)
text = text[:insert_at] + to_insert + text[insert_at:]

if text != original:
  open(path, "w", encoding="utf-8").write(text)
PY
}

patch_android_gradle_properties_for_size() {
  local props_file="$OUT_DIR/android/gradle.properties"
  if [ ! -f "$props_file" ]; then
    echo "[WARN] 未找到 android/gradle.properties，跳过 Gradle 体积优化：$props_file" >&2
    return 0
  fi

  python3 - "$props_file" <<'PY'
import sys

path = sys.argv[1]
text = open(path, "r", encoding="utf-8").read()
original = text

def ensure_line(line: str) -> None:
  global text
  if line in text:
    return
  if not text.endswith("\n"):
    text += "\n"
  text += line + "\n"

# Full mode can yield better shrinking/obfuscation results for R8.
ensure_line("android.enableR8.fullMode=true")
# Compress native libs in app bundles for smaller download size.
ensure_line("android.bundle.enableUncompressedNativeLibs=false")

if text != original:
  open(path, "w", encoding="utf-8").write(text)
PY
}

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
# Remove deps that are no longer used by the template (keeps pubspec stable
# across template upgrades).
echo "[INFO] 移除已废弃依赖（pub remove）"
(cd "$OUT_DIR" && flutter pub remove \
  just_audio_background \
  just_audio_platform_interface \
  mpris \
  > /dev/null 2>&1 || true)

# Pin versions to avoid breaking API changes (e.g. file_picker v10 removed FilePicker.platform).
(cd "$OUT_DIR" && flutter pub add \
  file_picker:^8.3.2 \
  path_provider:^2.1.5 \
  just_audio:^0.9.46 \
  audio_session:^0.1.25 \
  path:any \
  ffi:^2.1.3 \
  audio_service:^0.18.17 \
  smtc_windows:^1.0.0 \
  dbus:^0.7.11)

echo "[INFO] 覆盖模板代码"
cp -a "$TEMPLATES_DIR/lib/." "$OUT_DIR/lib/"
cp -a "$TEMPLATES_DIR/android/." "$OUT_DIR/android/"
# Ensure Flutter generates plugin registrant for the current dependency set.
rm -f "$OUT_DIR/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java" || true
if [ -d "$TEMPLATES_DIR/test" ]; then
  mkdir -p "$OUT_DIR/test"
  cp -a "$TEMPLATES_DIR/test/." "$OUT_DIR/test/"
fi
if [ -f "$TEMPLATES_DIR/analysis_options.yaml" ]; then
  cp -f "$TEMPLATES_DIR/analysis_options.yaml" "$OUT_DIR/analysis_options.yaml"
fi

echo "[INFO] 配置 Android AudioService（用于 just_audio_background / audio_service）"
patch_android_manifest_for_audio_service

echo "[INFO] 配置 Android release 体积优化（R8 + 资源压缩）"
patch_android_gradle_for_release_shrink
patch_android_gradle_properties_for_size

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

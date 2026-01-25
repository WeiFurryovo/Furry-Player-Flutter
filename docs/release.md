# Release（Windows / Linux / Android）

本仓库推荐使用 **Flutter** 作为统一 UI：
- Android：Flutter → Kotlin(MethodChannel) → JNI → Rust（`apps/furry_android`）
- Windows/Linux：Flutter → Dart FFI → Rust（`apps/furry_ffi`）

## 一键构建（推荐）

在仓库根目录：
```sh
./release.sh
```

输出目录：
- `dist/android/`：`libfurry_android.so`（各 ABI）
- `dist/android/flutter/`：`app-release.apk` / `app-release.aab`（需要 Flutter）
- `dist/desktop/flutter/`：Flutter 桌面 bundle（linux/windows best-effort）

## CI 自动发版（GitHub Actions）
见：`docs/github_actions.md`

## 分平台说明

### Linux
- Flutter 桌面：`./release.sh flutter-desktop`

### Windows
- Flutter 桌面：`./release.sh flutter-desktop`

### Flutter 桌面端（Windows/Linux）
本项目的 Flutter App（`apps/furry_flutter/furry_flutter_app`）在：
- Android：走 `MethodChannel` → Kotlin → JNI → `apps/furry_android`
- Windows/Linux：走 `dart:ffi` → `apps/furry_ffi`（`cdylib`）

构建（尽力而为，取决于你本机 Flutter 是否启用桌面）：
```sh
./release.sh flutter-desktop
```

动态库投放规则（必须在可被加载的位置）：
- Windows：把 `furry_ffi.dll` 放到 `xxx.exe` 同目录
- Linux：把 `libfurry_ffi.so` 放到可执行文件同目录（或在 `LD_LIBRARY_PATH`）

### Android（Rust JNI + Flutter）
前置条件：
- Android NDK：设置 `ANDROID_NDK_HOME`
- Flutter SDK：本机 `flutter` 命令可用

构建：
```sh
./release.sh flutter-android
```

如果只想生成 Flutter 工程（不打包）：
```sh
./apps/furry_flutter/create_flutter_app.sh
```

## Legacy（可选）
如果你还想要原来的 Rust 桌面 GUI/CLI：
- Linux：`./release.sh legacy-linux`
- Windows：`./release.sh legacy-windows`
- 全部：`./release.sh legacy-all`

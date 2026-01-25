## Furry Player → Flutter（改造方案 + 脚手架）

这个仓库的核心能力在 Rust：
- `crates/furry_crypto` / `crates/furry_format` / `crates/furry_converter`：`.furry` 打包/解包、加密、格式
- `apps/furry_android`：把上述能力通过 **JNI** 暴露给 Android（产物 `libfurry_android.so`）
- `apps/furry_gui`：桌面端 GUI（egui）
- `apps/furry_android_app`：Android WebView 示例前端（Kotlin + WebView）

本目录提供的目标是：**用 Flutter 替换前端 UI**，并在 Android 端复用现有 `apps/furry_android` 的 JNI 动态库。

### 你将得到什么
- 一个 Flutter Android App（UI：选择文件 → 打包为 `.furry`；选择音频/`.furry` → 播放）
- 通过 `MethodChannel("furry/native")` 调用 Kotlin → JNI → Rust
- 通过 `build.sh android` 生成并拷贝 `libfurry_android.so` 到 Flutter 工程 `jniLibs/`

### 一键生成 Flutter 工程
前置条件：
- 安装 Flutter SDK（本机 `flutter` 命令可用）
- Android SDK/NDK 可用，并设置 `ANDROID_NDK_HOME`（用于构建 Rust Android 动态库）

在仓库根目录执行：
```sh
./apps/furry_flutter/create_flutter_app.sh
```

生成的 Flutter 工程路径：
- `apps/furry_flutter/furry_flutter_app/`

### 运行
```sh
cd apps/furry_flutter/furry_flutter_app
flutter run
```

### 常见问题
- `./build.sh android` 提示找不到 NDK：设置 `ANDROID_NDK_HOME`，例如 `export ANDROID_NDK_HOME=~/Android/Sdk/ndk/26.1.10909125`
- Flutter 端文件选择为 `withData: true`（直接读入内存再写入临时文件），大文件会占用较多内存；要做“真·流式”读取，需要在 Android 侧处理 `content://` URI（后续可以加）
- 目前只接了 Android；桌面/iOS 还没做 Rust 绑定

### 当前实现范围（可迭代）
- Android：已接通 `packToFurry / unpackFromFurryToBytes / isValidFurryFile / getOriginalFormat`
- 桌面（Windows/Linux）：已加 `dart:ffi` 绑定（Rust 侧为 `apps/furry_ffi`），需要把动态库放到可执行文件同目录
- iOS/macOS：未验证（FFI 预留了 `.dylib` 名称）

# 架构概览（Furry Player）

本仓库包含 Rust 核心与多端 UI（Flutter、Egui GUI、CLI、Android glue）。目标是提供一个本地音乐播放器与 `.furry` 格式的封装/解包/播放体验。

## 目录结构

- `crates/`
  - `furry_format/`：`.furry` 文件格式定义与读写（Header / Chunk / Index）。
  - `furry_crypto/`：加密与密钥派生（HKDF + AES-GCM），以及 META 混淆相关逻辑。
  - `furry_converter/`：把原始音频封装为 `.furry`，或从 `.furry` 解包。
  - `furry_player/`：播放引擎（解码 + 输出），暴露命令/事件通道给 UI。
- `apps/`
  - `furry_flutter/`：Flutter 相关脚本与模板源码。
    - `templates/`：Flutter 源码模板（建议在这里修改）。
    - `furry_flutter_app/`：可运行 Flutter 工程，通常由脚本生成/覆盖。
  - `furry_ffi/`：桌面端 C ABI（供 Flutter/Dart FFI 调用）。
  - `furry_android/`：Android 侧 Rust glue（供原生层调用）。
  - `furry_gui/`：Egui 桌面 GUI（Rust）。
  - `furry_cli/`：命令行工具（Rust）。
- `flutter/`：Flutter SDK（体积很大，不建议改动）。

## Flutter（Material 3 Expressive UI）

Flutter UI 以 “模板 → 生成工程” 的方式维护：

1. 修改 `apps/furry_flutter/templates/lib/` 下的源码（如 `main.dart`）。
2. 运行 `apps/furry_flutter/create_flutter_app.sh` 覆盖生成 `apps/furry_flutter/furry_flutter_app/`。
3. 在 `apps/furry_flutter/furry_flutter_app/` 下执行 `flutter analyze` / `flutter run`。

跨平台能力通过 `FurryApi` 注入：

- Android：`MethodChannel`（`furry_api_android.dart`）
- Desktop：Dart FFI（`furry_api_ffi.dart` → `apps/furry_ffi` 动态库）

## Rust 数据流（`.furry`）

简化路径如下：

1. **封装（pack）**：原始音频 + META → `furry_converter` → `furry_format` 写入结构 → `furry_crypto` 加密各 chunk。
2. **读取（read）**：`furry_format::FurryReader` 解析 header/index → 通过 file keys 解密 index / chunk。
3. **播放（play）**：`furry_player::VirtualAudioStream` 将分段 AUDIO chunk 映射为连续、可 seek 的字节流 → `symphonia` 解码 → `AudioOutput` 播放。

## 主密钥配置

- 运行时入口（CLI / GUI / Android JNI / Desktop FFI）优先读取环境变量 `FURRY_MASTER_KEY_HEX`。
- 该值必须是 32 字节主密钥的 64 位十六进制字符串。
- 如果未设置，会回退到内置开发密钥以保持兼容；生产环境不应依赖该回退。
- 设置 `FURRY_REQUIRE_MASTER_KEY=1` 后，运行时会拒绝该回退并直接报错。

## 注释/文档原则

- 优先写“为什么这样做”而不是重复代码本身。
- 对外暴露的接口（FFI、MethodChannel、公共 struct/enum）必须有清晰语义与约束说明。
- 生成物/依赖（如 `flutter/`、构建产物）不建议补注释或改动。

import 'dart:typed_data';

/// Furry 平台能力抽象层。
///
/// Flutter UI 不直接依赖 Rust/平台实现，而是通过该接口完成：
/// - 把音频封装为 `.furry`（写入封面/标签等 META）
/// - 从 `.furry` 解包为音频字节/文件
/// - 读取 `.furry` 元信息（原始格式、标签 JSON、封面）
///
/// 具体实现：
/// - Android：`MethodChannel`（见 `furry_api_android.dart`）
/// - Desktop：Dart FFI 调用 Rust 动态库（见 `furry_api_ffi.dart`）
///
/// 注意：所有实现都应该避免在 UI isolate 上做重活（如解包/封装）。
abstract class FurryApi {
  /// 初始化底层能力（如加载动态库、建立 channel 等）。
  Future<void> init();

  /// 将原始音频封装为 `.furry` 文件。
  ///
  /// `paddingKb` 用于在输出尾部额外填充空间，便于后续写入更大的 META。
  Future<int> packToFurry({
    required String inputPath,
    required String outputPath,
    required int paddingKb,
  });

  /// 将 `.furry` 解包为内存字节（用于直接播放或临时处理）。
  Future<Uint8List?> unpackFromFurryToBytes({required String inputPath});

  /// Decrypts `.furry` to a file, returns 0 on success.
  Future<int> unpackToFile(
      {required String inputPath, required String outputPath});

  /// 快速校验：文件是否为合法 `.furry`（至少做 magic / 结构校验）。
  Future<bool> isValidFurryFile({required String filePath});

  /// 读取 `.furry` 内记录的原始格式（不含点号，如 `mp3`）。
  Future<String> getOriginalFormat({required String filePath});

  /// Returns tags JSON stored in `.furry` (may be empty string if absent).
  Future<String> getTagsJson({required String filePath});

  /// Returns cover art payload bytes stored in `.furry` (may be null).
  /// Payload format: `mime\\0<image-bytes>`.
  Future<Uint8List?> getCoverArt({required String filePath});
}

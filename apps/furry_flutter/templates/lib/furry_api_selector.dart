import 'dart:io';
import 'dart:typed_data';

import 'furry_api.dart';
import 'furry_api_android.dart';
import 'furry_api_ffi.dart';

/// 根据运行平台选择合适的 `FurryApi` 实现。
///
/// - Android：`MethodChannel`
/// - Windows/Linux/macOS：Dart FFI 动态库
/// - 测试：返回 Noop，避免在测试环境依赖动态库/平台通道
FurryApi createFurryApi() {
  if (const bool.fromEnvironment('FLUTTER_TEST')) {
    return _FurryApiNoop();
  }
  if (Platform.isAndroid) {
    return FurryApiAndroid();
  }
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    return FurryApiFfi();
  }
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

/// 测试用空实现：所有操作都返回失败/空值。
///
/// 目的：
/// - 让 widget/unit tests 可以运行，而不需要真实的 Rust/平台能力
/// - 避免 CI 上缺少动态库导致测试挂掉
class _FurryApiNoop implements FurryApi {
  @override
  Future<void> init() async {}

  @override
  Future<int> packToFurry({
    required String inputPath,
    required String outputPath,
    required int paddingKb,
  }) async {
    return -999;
  }

  @override
  Future<Uint8List?> unpackFromFurryToBytes({required String inputPath}) async {
    return null;
  }

  @override
  Future<int> unpackToFile(
      {required String inputPath, required String outputPath}) async {
    return -999;
  }

  @override
  Future<bool> isValidFurryFile({required String filePath}) async {
    return false;
  }

  @override
  Future<String> getOriginalFormat({required String filePath}) async {
    return '';
  }

  @override
  Future<String> getTagsJson({required String filePath}) async {
    return '';
  }

  @override
  Future<Uint8List?> getCoverArt({required String filePath}) async {
    return null;
  }
}

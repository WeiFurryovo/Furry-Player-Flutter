import 'package:flutter/services.dart';

import 'furry_api.dart';

/// Android 平台实现：通过 `MethodChannel` 调用 Kotlin/Java 原生层。
///
/// 该实现适用于移动端（不依赖桌面动态库），且可在原生层处理文件 IO、
/// 访问媒体能力等。方法名与参数结构需要与 Android 工程保持一致。
class FurryApiAndroid implements FurryApi {
  static const MethodChannel _channel = MethodChannel('furry/native');

  @override
  Future<void> init() => _channel.invokeMethod<void>('init');

  @override
  Future<int> packToFurry({
    required String inputPath,
    required String outputPath,
    required int paddingKb,
  }) async {
    final rc = await _channel.invokeMethod<int>('packToFurry', {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'paddingKb': paddingKb,
    });
    return rc ?? -999;
  }

  @override
  Future<Uint8List?> unpackFromFurryToBytes({required String inputPath}) {
    return _channel.invokeMethod<Uint8List>('unpackFromFurryToBytes', {
      'inputPath': inputPath,
    });
  }

  @override
  Future<int> unpackToFile(
      {required String inputPath, required String outputPath}) async {
    final rc = await _channel.invokeMethod<int>('unpackToFile', {
      'inputPath': inputPath,
      'outputPath': outputPath,
    });
    return rc ?? -999;
  }

  @override
  Future<bool> isValidFurryFile({required String filePath}) async {
    final ok = await _channel.invokeMethod<bool>('isValidFurryFile', {
      'filePath': filePath,
    });
    return ok ?? false;
  }

  @override
  Future<String> getOriginalFormat({required String filePath}) async {
    final ext = await _channel.invokeMethod<String>('getOriginalFormat', {
      'filePath': filePath,
    });
    return ext ?? '';
  }

  @override
  Future<String> getTagsJson({required String filePath}) async {
    final json = await _channel.invokeMethod<String>('getTagsJson', {
      'filePath': filePath,
    });
    return json ?? '';
  }

  @override
  Future<Uint8List?> getCoverArt({required String filePath}) {
    return _channel.invokeMethod<Uint8List>('getCoverArt', {
      'filePath': filePath,
    });
  }
}

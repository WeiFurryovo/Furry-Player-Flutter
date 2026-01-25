import 'dart:io';
import 'dart:typed_data';

import 'furry_api.dart';
import 'furry_api_android.dart';
import 'furry_api_ffi.dart';

FurryApi createFurryApi() {
  if (const bool.fromEnvironment('FLUTTER_TEST')) return _FurryApiNoop();
  if (Platform.isAndroid) return FurryApiAndroid();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) return FurryApiFfi();
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

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
  Future<int> unpackToFile({required String inputPath, required String outputPath}) async {
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

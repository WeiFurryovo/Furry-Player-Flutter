import 'dart:typed_data';

abstract class FurryApi {
  Future<void> init();

  Future<int> packToFurry({
    required String inputPath,
    required String outputPath,
    required int paddingKb,
  });

  Future<Uint8List?> unpackFromFurryToBytes({required String inputPath});

  Future<bool> isValidFurryFile({required String filePath});

  Future<String> getOriginalFormat({required String filePath});
}


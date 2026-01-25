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

  /// Returns tags JSON stored in `.furry` (may be empty string if absent).
  Future<String> getTagsJson({required String filePath});

  /// Returns cover art payload bytes stored in `.furry` (may be null).
  /// Payload format: `mime\\0<image-bytes>`.
  Future<Uint8List?> getCoverArt({required String filePath});
}

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'furry_api.dart';

class FurryApiFfi implements FurryApi {
  FurryApiFfi()
      : _lib = _openLib(),
        _isValid = _openLib().lookupFunction<_IsValidC, _IsValidDart>('furry_is_valid_furry_file'),
        _getOriginalFormat =
            _openLib().lookupFunction<_GetOriginalFormatC, _GetOriginalFormatDart>(
          'furry_get_original_format',
        );

  final ffi.DynamicLibrary _lib;

  late final _IsValidDart _isValid;
  late final _GetOriginalFormatDart _getOriginalFormat;

  static ffi.DynamicLibrary _openLib() {
    if (Platform.isWindows) return ffi.DynamicLibrary.open('furry_ffi.dll');
    if (Platform.isLinux) return ffi.DynamicLibrary.open('libfurry_ffi.so');
    if (Platform.isMacOS) return ffi.DynamicLibrary.open('libfurry_ffi.dylib');
    return ffi.DynamicLibrary.process();
  }

  @override
  Future<void> init() async {}

  @override
  Future<int> packToFurry({
    required String inputPath,
    required String outputPath,
    required int paddingKb,
  }) async {
    // Avoid blocking UI isolate on desktop.
    return Isolate.run(() => _ffiPackToFurryWorker((inputPath, outputPath, paddingKb)));
  }

  @override
  Future<bool> isValidFurryFile({required String filePath}) async {
    final p = filePath.toNativeUtf8();
    try {
      return _isValid(p.cast());
    } finally {
      malloc.free(p);
    }
  }

  @override
  Future<String> getOriginalFormat({required String filePath}) async {
    final p = filePath.toNativeUtf8();
    final out = calloc<ffi.Char>(16);
    try {
      final rc = _getOriginalFormat(p.cast(), out, 16);
      if (rc != 0) return '';
      return out.cast<Utf8>().toDartString();
    } finally {
      malloc.free(p);
      calloc.free(out);
    }
  }

  @override
  Future<Uint8List?> unpackFromFurryToBytes({required String inputPath}) async {
    // Avoid blocking UI isolate on desktop.
    return Isolate.run(() => _ffiUnpackToBytesWorker(inputPath));
  }

  @override
  Future<int> unpackToFile({required String inputPath, required String outputPath}) async {
    // Avoid blocking UI isolate on desktop.
    return Isolate.run(() => _ffiUnpackToFileWorker((inputPath, outputPath)));
  }

  @override
  Future<String> getTagsJson({required String filePath}) async {
    return Isolate.run(() => _ffiGetTagsJsonWorker(filePath));
  }

  @override
  Future<Uint8List?> getCoverArt({required String filePath}) async {
    return Isolate.run(() => _ffiGetCoverArtWorker(filePath));
  }
}

typedef _PackArgs = (String inputPath, String outputPath, int paddingKb);
typedef _UnpackFileArgs = (String inputPath, String outputPath);

int _ffiPackToFurryWorker(_PackArgs args) {
  final lib = FurryApiFfi._openLib();
  final pack = lib.lookupFunction<_PackToFurryC, _PackToFurryDart>('furry_pack_to_furry');
  final (inputPath, outputPath, paddingKb) = args;

  final inPtr = inputPath.toNativeUtf8();
  final outPtr = outputPath.toNativeUtf8();
  try {
    return pack(inPtr.cast(), outPtr.cast(), paddingKb);
  } finally {
    malloc.free(inPtr);
    malloc.free(outPtr);
  }
}

Uint8List? _ffiUnpackToBytesWorker(String inputPath) {
  final lib = FurryApiFfi._openLib();
  final unpack =
      lib.lookupFunction<_UnpackToBytesC, _UnpackToBytesDart>('furry_unpack_from_furry_to_bytes');
  final freeBytes = lib.lookupFunction<_FreeBytesC, _FreeBytesDart>('furry_free_bytes');

  final p = inputPath.toNativeUtf8();
  final outPtr = calloc<ffi.Pointer<ffi.Uint8>>();
  final outLen = calloc<ffi.Size>();
  try {
    final rc = unpack(p.cast(), outPtr, outLen);
    if (rc != 0) return null;
    final ptr = outPtr.value;
    final len = outLen.value;
    if (ptr.address == 0 || len == 0) return Uint8List(0);
    final bytes = ptr.asTypedList(len);
    final copy = Uint8List.fromList(bytes);
    freeBytes(ptr, len);
    return copy;
  } finally {
    malloc.free(p);
    calloc.free(outPtr);
    calloc.free(outLen);
  }
}

int _ffiUnpackToFileWorker(_UnpackFileArgs args) {
  final lib = FurryApiFfi._openLib();
  final unpackToFile =
      lib.lookupFunction<_UnpackToFileC, _UnpackToFileDart>('furry_unpack_from_furry_to_file');
  final (inputPath, outputPath) = args;

  final inPtr = inputPath.toNativeUtf8();
  final outPtr = outputPath.toNativeUtf8();
  try {
    return unpackToFile(inPtr.cast(), outPtr.cast());
  } finally {
    malloc.free(inPtr);
    malloc.free(outPtr);
  }
}

String _ffiGetTagsJsonWorker(String filePath) {
  final lib = FurryApiFfi._openLib();
  final getTagsJsonToBytes = lib.lookupFunction<_GetTagsJsonToBytesC, _GetTagsJsonToBytesDart>(
    'furry_get_tags_json_to_bytes',
  );
  final freeBytes = lib.lookupFunction<_FreeBytesC, _FreeBytesDart>('furry_free_bytes');

  final p = filePath.toNativeUtf8();
  final outPtr = calloc<ffi.Pointer<ffi.Uint8>>();
  final outLen = calloc<ffi.Size>();
  try {
    final rc = getTagsJsonToBytes(p.cast(), outPtr, outLen);
    if (rc != 0) return '';
    final ptr = outPtr.value;
    final len = outLen.value;
    if (ptr.address == 0 || len == 0) return '';
    final bytes = ptr.asTypedList(len);
    final copy = Uint8List.fromList(bytes);
    freeBytes(ptr, len);
    return String.fromCharCodes(copy);
  } finally {
    malloc.free(p);
    calloc.free(outPtr);
    calloc.free(outLen);
  }
}

Uint8List? _ffiGetCoverArtWorker(String filePath) {
  final lib = FurryApiFfi._openLib();
  final getCoverArtToBytes = lib.lookupFunction<_GetCoverArtToBytesC, _GetCoverArtToBytesDart>(
    'furry_get_cover_art_to_bytes',
  );
  final freeBytes = lib.lookupFunction<_FreeBytesC, _FreeBytesDart>('furry_free_bytes');

  final p = filePath.toNativeUtf8();
  final outPtr = calloc<ffi.Pointer<ffi.Uint8>>();
  final outLen = calloc<ffi.Size>();
  try {
    final rc = getCoverArtToBytes(p.cast(), outPtr, outLen);
    if (rc != 0) return null;
    final ptr = outPtr.value;
    final len = outLen.value;
    if (ptr.address == 0 || len == 0) return null;
    final bytes = ptr.asTypedList(len);
    final copy = Uint8List.fromList(bytes);
    freeBytes(ptr, len);
    return copy;
  } finally {
    malloc.free(p);
    calloc.free(outPtr);
    calloc.free(outLen);
  }
}

typedef _PackToFurryC = ffi.Int32 Function(
  ffi.Pointer<ffi.Char>,
  ffi.Pointer<ffi.Char>,
  ffi.Uint64,
);
typedef _PackToFurryDart = int Function(
  ffi.Pointer<ffi.Char>,
  ffi.Pointer<ffi.Char>,
  int,
);

typedef _IsValidC = ffi.Bool Function(ffi.Pointer<ffi.Char>);
typedef _IsValidDart = bool Function(ffi.Pointer<ffi.Char>);

typedef _GetOriginalFormatC = ffi.Int32 Function(
  ffi.Pointer<ffi.Char>,
  ffi.Pointer<ffi.Char>,
  ffi.Size,
);
typedef _GetOriginalFormatDart = int Function(
  ffi.Pointer<ffi.Char>,
  ffi.Pointer<ffi.Char>,
  int,
);

typedef _UnpackToBytesC = ffi.Int32 Function(
  ffi.Pointer<ffi.Char>,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
  ffi.Pointer<ffi.Size>,
);
typedef _UnpackToBytesDart = int Function(
  ffi.Pointer<ffi.Char>,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
  ffi.Pointer<ffi.Size>,
);

typedef _UnpackToFileC = ffi.Int32 Function(
  ffi.Pointer<ffi.Char>,
  ffi.Pointer<ffi.Char>,
);
typedef _UnpackToFileDart = int Function(
  ffi.Pointer<ffi.Char>,
  ffi.Pointer<ffi.Char>,
);

typedef _GetTagsJsonToBytesC = ffi.Int32 Function(
  ffi.Pointer<ffi.Char>,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
  ffi.Pointer<ffi.Size>,
);
typedef _GetTagsJsonToBytesDart = int Function(
  ffi.Pointer<ffi.Char>,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
  ffi.Pointer<ffi.Size>,
);

typedef _GetCoverArtToBytesC = ffi.Int32 Function(
  ffi.Pointer<ffi.Char>,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
  ffi.Pointer<ffi.Size>,
);
typedef _GetCoverArtToBytesDart = int Function(
  ffi.Pointer<ffi.Char>,
  ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
  ffi.Pointer<ffi.Size>,
);

typedef _FreeBytesC = ffi.Void Function(ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef _FreeBytesDart = void Function(ffi.Pointer<ffi.Uint8>, int);

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'furry_api.dart';

class FurryApiFfi implements FurryApi {
  FurryApiFfi() : _lib = _openLib() {
    _packToFurry = _lib.lookupFunction<_PackToFurryC, _PackToFurryDart>('furry_pack_to_furry');
    _isValid =
        _lib.lookupFunction<_IsValidC, _IsValidDart>('furry_is_valid_furry_file');
    _getOriginalFormat = _lib.lookupFunction<_GetOriginalFormatC, _GetOriginalFormatDart>(
      'furry_get_original_format',
    );
    _unpackToBytes =
        _lib.lookupFunction<_UnpackToBytesC, _UnpackToBytesDart>('furry_unpack_from_furry_to_bytes');
    _freeBytes = _lib.lookupFunction<_FreeBytesC, _FreeBytesDart>('furry_free_bytes');
  }

  final ffi.DynamicLibrary _lib;

  late final _PackToFurryDart _packToFurry;
  late final _IsValidDart _isValid;
  late final _GetOriginalFormatDart _getOriginalFormat;
  late final _UnpackToBytesDart _unpackToBytes;
  late final _FreeBytesDart _freeBytes;

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
    final inPtr = inputPath.toNativeUtf8();
    final outPtr = outputPath.toNativeUtf8();
    try {
      return _packToFurry(inPtr.cast(), outPtr.cast(), paddingKb);
    } finally {
      malloc.free(inPtr);
      malloc.free(outPtr);
    }
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
    final p = inputPath.toNativeUtf8();
    final outPtr = calloc<ffi.Pointer<ffi.Uint8>>();
    final outLen = calloc<ffi.Size>();
    try {
      final rc = _unpackToBytes(p.cast(), outPtr, outLen);
      if (rc != 0) return null;
      final ptr = outPtr.value;
      final len = outLen.value;
      if (ptr.address == 0 || len == 0) return Uint8List(0);
      final bytes = ptr.asTypedList(len);
      final copy = Uint8List.fromList(bytes);
      _freeBytes(ptr, len);
      return copy;
    } finally {
      malloc.free(p);
      calloc.free(outPtr);
      calloc.free(outLen);
    }
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

typedef _FreeBytesC = ffi.Void Function(ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef _FreeBytesDart = void Function(ffi.Pointer<ffi.Uint8>, int);

part of '../main.dart';

({int start, int length}) diagnosticsLogTailWindowForTest({
  required int fileLength,
  required int keepBytes,
}) {
  final safeLength = fileLength < 0 ? 0 : fileLength;
  final safeKeep = keepBytes < 0 ? 0 : keepBytes;
  final length = safeLength < safeKeep ? safeLength : safeKeep;
  return (start: safeLength - length, length: length);
}

class _DiagnosticsLog {
  static File? _file;
  static Future<void> _writeChain = Future<void>.value();

  static const int _maxBytes = 512 * 1024; // 512 KiB
  static const int _keepBytes = 256 * 1024; // 256 KiB

  /// 初始化诊断日志文件（`ApplicationSupportDirectory/diagnostics.log`）。
  ///
  /// 该文件用于收集启动阶段与运行阶段的关键错误信息，便于用户反馈问题。
  /// 为避免日志无限增长，这里会在写入时做大小裁剪（保留尾部 `_keepBytes`）。
  static Future<void> init() async {
    if (_file != null) return;
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    _file = File(p.join(dir.path, 'diagnostics.log'));
  }

  static Future<String> readAll() async {
    try {
      await init();
      final f = _file!;
      if (!await f.exists()) return '';
      return _readTailText(f, keepBytes: _keepBytes);
    } catch (_) {
      return '';
    }
  }

  static Future<void> appendLine(String msg) async {
    try {
      await init();
      final line = '${DateTime.now().toIso8601String()}  $msg\n';
      _writeChain = _writeChain.then((_) async {
        final f = _file!;
        await f.writeAsString(line, mode: FileMode.append, flush: true);
        final len = await f.length();
        if (len <= _maxBytes) return;
        await _trimFileToTail(f, keepBytes: _keepBytes);
      });
      await _writeChain;
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      await init();
      _writeChain = _writeChain.then((_) async {
        final f = _file!;
        await f.writeAsString('', flush: true);
      });
      await _writeChain;
    } catch (_) {}
  }

  static Future<String?> exportToDocuments() async {
    try {
      await init();
      final src = _file!;
      if (!await src.exists()) return null;
      final docs = await getApplicationDocumentsDirectory();
      await docs.create(recursive: true);
      final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
      final out = File(p.join(docs.path, 'furry_diagnostics_$ts.log'));
      await src.copy(out.path);
      return out.path;
    } catch (_) {
      return null;
    }
  }

  static ({int start, int length}) _tailWindow(
    int fileLength, {
    required int keepBytes,
  }) {
    return diagnosticsLogTailWindowForTest(
      fileLength: fileLength,
      keepBytes: keepBytes,
    );
  }

  static Future<List<int>> _readTailBytes(
    File file, {
    required int keepBytes,
  }) async {
    final fileLength = await file.length();
    final window = _tailWindow(fileLength, keepBytes: keepBytes);
    if (window.length <= 0) return const <int>[];

    final reader = await file.open(mode: FileMode.read);
    try {
      await reader.setPosition(window.start);
      return await reader.read(window.length);
    } finally {
      await reader.close();
    }
  }

  static Future<String> _readTailText(
    File file, {
    required int keepBytes,
  }) async {
    final bytes = await _readTailBytes(file, keepBytes: keepBytes);
    if (bytes.isEmpty) return '';
    return utf8.decode(bytes, allowMalformed: true);
  }

  static Future<void> _trimFileToTail(
    File file, {
    required int keepBytes,
  }) async {
    final bytes = await _readTailBytes(file, keepBytes: keepBytes);
    await file.writeAsBytes(bytes, flush: true);
  }
}

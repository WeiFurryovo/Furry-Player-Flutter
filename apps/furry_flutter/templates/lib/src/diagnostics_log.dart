part of '../main.dart';

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
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) return '';
      final start = bytes.length > _keepBytes ? bytes.length - _keepBytes : 0;
      return utf8.decode(bytes.sublist(start), allowMalformed: true);
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
        final bytes = await f.readAsBytes();
        final start = bytes.length > _keepBytes ? bytes.length - _keepBytes : 0;
        await f.writeAsBytes(bytes.sublist(start), flush: true);
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
}

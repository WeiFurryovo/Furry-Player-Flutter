// Furry Player Flutter UI（模板）。
//
// 说明：
// - 该仓库同时包含 Rust 核心（`.furry` 格式/加密/转换/播放引擎）与多端 UI。
// - Flutter 工程的“源码入口”是 `apps/furry_flutter/templates/`，运行工程
//   `apps/furry_flutter/furry_flutter_app/` 通常由脚本覆盖生成（见
//   `apps/furry_flutter/create_flutter_app.sh`）。
//
// 交互/设计目标：
// - UI 以 Material 3 Expressive 为基线（层级清晰、触达舒适、对比度可读）。
// - 播放器逻辑集中在 `_AppController`，页面只消费状态并触发意图。
// - 跨平台能力通过 `FurryApi`（Android MethodChannel / Desktop FFI）注入。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show lerpDouble;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audio_session/audio_session.dart';
import 'package:audio_service/audio_service.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'furry_api.dart';
import 'furry_api_selector.dart';
import 'in_memory_audio_source.dart';
import 'system_media_bridge.dart';

part 'src/audio_handler.dart';
part 'src/diagnostics_log.dart';
part 'src/expressive_theme.dart';
part 'src/app_shell.dart';

/// 启动阶段日志（用于诊断启动失败/权限问题等）。
final List<String> _startupDiagnostics = <String>[];

/// 全局共享播放器实例。
///
/// 原因：系统媒体中心/AudioService/各页面都需要统一的播放状态与队列。
late final AudioPlayer _sharedPlayer;

Color _withOpacityCompat(Color color, double opacity) =>
    color.withAlpha((opacity * 255).round().clamp(0, 255));

void _startupLog(String msg) {
  _startupDiagnostics.add(msg);
  debugPrint(msg);
  unawaited(_DiagnosticsLog.appendLine(msg));
}

List<String> _takeStartupDiagnostics() {
  final out = List<String>.from(_startupDiagnostics);
  _startupDiagnostics.clear();
  return out;
}

/// 应用入口。
///
/// 启动顺序（高层）：
/// 1) 初始化持久化诊断日志 + 全局错误钩子（便于收集崩溃信息）
/// 2) 创建全局共享 `AudioPlayer`
/// 3) Android 上初始化 `AudioService`（通知栏/锁屏媒体控件）
/// 4) 移动端配置 `AudioSession`（与系统音频焦点/混音策略协作）
/// 5) 进入 `FurryApp`（Material 3 Expressive UI）
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _DiagnosticsLog.init();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _startupLog('FlutterError: ${details.exception}\n${details.stack}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _startupLog('Uncaught error: $error\n$stack');
    return true;
  };

  _sharedPlayer = AudioPlayer();

  if (!kIsWeb && Platform.isAndroid) {
    try {
      await AudioService.init(
        builder: () => _FurryAudioHandler(_sharedPlayer),
        config: const AudioServiceConfig(
          androidNotificationChannelId:
              'com.furry.furry_flutter_app.channel.audio',
          androidNotificationChannelName: 'Furry Player',
          // Don’t publish a STOP action; keep controls in sync with the app UI.
          // Also keep the notification dismissible to avoid OEM “stop” affordances.
          androidNotificationOngoing: false,
          androidStopForegroundOnPause: true,
          androidShowNotificationBadge: false,
        ),
      );
      _startupLog('AudioService init ok');
    } catch (e, st) {
      _startupLog('AudioService init failed: $e\n$st');
    }
  }

  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      _startupLog('AudioSession configured');
    } catch (e, st) {
      _startupLog('AudioSession configure failed: $e\n$st');
    }
  }
  runApp(FurryApp(player: _sharedPlayer));
}

/// MaterialApp 外壳：动态色（如 Android 12+）+ M3 Expressive 主题。
///
/// 说明：
/// - 主题构建集中在 `_ExpressiveTheme`，以保证全局一致的层级与可读性
/// - `AppShell` 承载 3 个主 tab 与底部迷你播放器浮层
class FurryApp extends StatelessWidget {
  const FurryApp({super.key, required this.player});

  final AudioPlayer player;

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        return MaterialApp(
          title: 'Furry Player (Flutter)',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.system,
          theme: _ExpressiveTheme.build(
            Brightness.light,
            schemeOverride: lightDynamic,
          ),
          darkTheme: _ExpressiveTheme.build(
            Brightness.dark,
            schemeOverride: darkDynamic,
          ),
          home: AppShell(player: player),
        );
      },
    );
  }
}

/// 应用核心控制器（UI 只发出意图，状态由这里统一协调）。
///
/// 主要职责：
/// - 播放：驱动 `just_audio`，维护播放队列与当前曲目（`nowPlaying` / `queueState`）
/// - 跨平台能力：通过 `FurryApi` 进行 `.furry` 的封装/解包/读取元数据
/// - 系统媒体中心：通过 `SystemMediaBridge` 同步标题/封面/进度，并绑定上一首/下一首
/// - 页面协作：用 `requestedTab` 支持跨 tab 跳转（例如从搜索建议“去转换”）
/// - 数据缓存：封面/标签等元信息通过 `_metaPreviewCache` 做有界缓存
class _MetaPreviewCacheEntry {
  final DateTime modified;
  final Future<_MetaPreview> future;

  const _MetaPreviewCacheEntry({
    required this.modified,
    required this.future,
  });
}

class _TrackEntryCacheEntry {
  final DateTime modified;
  final int bytes;
  final _TrackEntry track;

  const _TrackEntryCacheEntry({
    required this.modified,
    required this.bytes,
    required this.track,
  });
}

class _LibraryIndexCacheEntry {
  final int signature;
  final _LibraryIndex index;

  const _LibraryIndexCacheEntry({
    required this.signature,
    required this.index,
  });
}

class _AppController {
  _AppController(this.player);

  final AudioPlayer player;
  final FurryApi api = createFurryApi();
  late final SystemMediaBridge systemMedia = SystemMediaBridge(player);

  Stream<PlayerState> get playerStateStream => player.playerStateStream;
  Stream<Duration?> get durationStream => player.durationStream;
  Stream<Duration> get positionStream => player.positionStream;

  StreamSubscription<dynamic>? _playbackErrorsSub;
  StreamSubscription<dynamic>? _playerStateSub;
  StreamSubscription<int?>? _currentIndexSub;
  Timer? _rssTimer;
  bool _handlingCompletion = false;

  final ValueNotifier<_NowPlaying?> nowPlaying =
      ValueNotifier<_NowPlaying?>(null);
  final ValueNotifier<int?> requestedTab = ValueNotifier<int?>(null);
  final ValueNotifier<_QueueState> queueState =
      ValueNotifier<_QueueState>(const _QueueState(queue: <File>[], index: -1));
  final ValueNotifier<List<File>> furryOutputs =
      ValueNotifier<List<File>>(<File>[]);
  final ValueNotifier<String> log = ValueNotifier<String>('');

  List<File>? _queue;
  int _queueIndex = -1;
  bool _androidPlaylistActive = false;
  DateTime? _lastPreviousPressedAt;
  static const Duration _previousDoublePressWindow = Duration(seconds: 2);

  // Keep this bounded to avoid unbounded RAM growth (cover bytes can be large).
  final Map<String, _MetaPreviewCacheEntry> _metaPreviewCache =
      <String, _MetaPreviewCacheEntry>{};
  final Map<String, _TrackEntryCacheEntry> _trackEntryCache =
      <String, _TrackEntryCacheEntry>{};
  _LibraryIndexCacheEntry? _libraryIndexCache;
  static const int _metaPreviewCacheLimit = 64;

  int paddingKb = 0;

  File? pickedForPack;
  String? pickedForPackName;

  /// 初始化控制器：加载平台能力、绑定系统媒体中心、恢复/刷新数据并写入诊断日志。
  Future<void> init() async {
    final persisted = await _DiagnosticsLog.readAll();
    if (persisted.trim().isNotEmpty) {
      log.value = persisted;
    }
    appendLog('Process: pid=$pid');
    try {
      await api.init();
      await systemMedia.init();
      systemMedia.bindQueueControls(
        onNext: playNextTrack,
        onPrevious: playPreviousTrack,
      );
      unawaited(systemMedia.setQueueAvailability(
        canGoNext: canPlayNextTrack,
        canGoPrevious: canPlayPreviousTrack,
      ));
      _wirePlayerDiagnostics();
      for (final line in _takeStartupDiagnostics()) {
        appendLog(line);
      }
      await cleanupTempArtifacts();
      await refreshOutputs();
      appendLog('Native init ok');
    } catch (e) {
      appendLog('Native init failed: $e');
    }
  }

  void _publishQueueState() {
    final q = _queue;
    if (q == null || q.isEmpty) {
      queueState.value = const _QueueState(queue: <File>[], index: -1);
      return;
    }
    queueState.value = _QueueState(
      queue: List<File>.unmodifiable(q),
      index: _queueIndex,
    );
  }

  void requestTabIndex(int index) {
    requestedTab.value = index;
  }

  Future<void> cleanupTempArtifacts() async {
    try {
      final tmp = await getTemporaryDirectory();

      // Cleanup unpacked audio files from `.furry` (keep recent ones).
      final unpackDir = Directory(p.join(tmp.path, 'furry_unpacked'));
      if (await unpackDir.exists()) {
        final files = unpackDir.listSync().whereType<File>().toList()
          ..sort(
              (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
        const keep = 12;
        final cutoff = DateTime.now().subtract(const Duration(days: 2));
        for (var i = 0; i < files.length; i++) {
          final f = files[i];
          final m = f.lastModifiedSync();
          if (i >= keep || m.isBefore(cutoff)) {
            try {
              await f.delete();
            } catch (_) {}
          }
        }
      }

      // Cleanup imported temp files created from picker streams/bytes.
      final rootFiles = tmp.listSync().whereType<File>().toList();
      final importCutoff = DateTime.now().subtract(const Duration(days: 2));
      for (final f in rootFiles) {
        final base = p.basename(f.path);
        if (!base.startsWith('import_')) continue;
        if (f.lastModifiedSync().isBefore(importCutoff)) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }

      // Cleanup cover art temp files.
      final artDir = Directory(p.join(tmp.path, 'furry_media_art'));
      if (await artDir.exists()) {
        final cutoff = DateTime.now().subtract(const Duration(days: 7));
        final artFiles = artDir.listSync().whereType<File>().toList();
        for (final f in artFiles) {
          if (f.lastModifiedSync().isBefore(cutoff)) {
            try {
              await f.delete();
            } catch (_) {}
          }
        }

        // Cap total cover cache size (LRU by modified time).
        const maxArtCacheBytes = 256 * 1024 * 1024; // 256 MiB
        var totalBytes = 0;
        final alive = <File>[];
        for (final file in artFiles) {
          try {
            if (!file.existsSync()) continue;
            totalBytes += file.lengthSync();
            alive.add(file);
          } catch (_) {}
        }
        if (totalBytes > maxArtCacheBytes) {
          alive.sort(
              (a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
          for (final file in alive) {
            if (totalBytes <= maxArtCacheBytes) break;
            try {
              final size = file.lengthSync();
              await file.delete();
              totalBytes -= size;
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  Future<_MetaPreview> getMetaPreviewForFurry(
    File furryFile, {
    DateTime? modified,
  }) async {
    final effectiveModified = modified ?? (await furryFile.stat()).modified;
    return _getMetaPreviewForFurryCached(furryFile, effectiveModified);
  }

  Future<_MetaPreview> _getMetaPreviewForFurryCached(
    File furryFile,
    DateTime modified,
  ) {
    final key = furryFile.path;
    final existing = _metaPreviewCache[key];
    if (existing != null && existing.modified == modified) {
      return existing.future;
    }

    final future = () async {
      final fallbackTitle = p.basename(furryFile.path);

      String title = '';
      String artist = '';
      String album = '';

      try {
        final jsonStr = await api.getTagsJson(filePath: furryFile.path);
        if (jsonStr.trim().isNotEmpty) {
          final m = jsonDecode(jsonStr);
          if (m is Map<String, dynamic>) {
            title = (m['title'] as String?)?.trim() ?? '';
            artist = (m['artist'] as String?)?.trim() ?? '';
            album = (m['album'] as String?)?.trim() ?? '';
          }
        }
      } catch (_) {}

      Uri? artUri;
      int? coverBytesLen;
      try {
        final payload = await api.getCoverArt(filePath: furryFile.path);
        if (payload != null && payload.isNotEmpty) {
          final sep = payload.indexOf(0);
          if (sep > 0 && sep < payload.length - 1) {
            final coverMime = String.fromCharCodes(payload.sublist(0, sep));
            final bytes = payload.sublist(sep + 1);
            coverBytesLen = bytes.length;
            artUri = await _writeCoverPayloadToTempUri(
                mime: coverMime, bytes: bytes);
          }
        }
      } catch (_) {}

      final subtitleParts = <String>[
        if (artist.isNotEmpty) artist,
        if (album.isNotEmpty) album,
      ];

      return _MetaPreview(
        title: title.isNotEmpty ? title : fallbackTitle,
        artist: artist,
        album: album,
        subtitle: subtitleParts.join(' · '),
        artUri: artUri,
        coverBytesLen: coverBytesLen,
      );
    }();

    _metaPreviewCache[key] = _MetaPreviewCacheEntry(
      modified: modified,
      future: future,
    );
    if (_metaPreviewCache.length > _metaPreviewCacheLimit) {
      final firstKey = _metaPreviewCache.keys.first;
      _metaPreviewCache.remove(firstKey);
    }
    return future;
  }

  void dispose() {
    _playbackErrorsSub?.cancel();
    _playerStateSub?.cancel();
    _currentIndexSub?.cancel();
    _rssTimer?.cancel();
    player.dispose();
    systemMedia.dispose();
    nowPlaying.dispose();
    requestedTab.dispose();
    queueState.dispose();
    furryOutputs.dispose();
    log.dispose();
  }

  void _wirePlayerDiagnostics() {
    _playbackErrorsSub?.cancel();
    _playerStateSub?.cancel();
    _currentIndexSub?.cancel();
    _playbackErrorsSub = player.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace st) {
        appendLog('Playback event error: $e\n$st');
      },
    );
    _playerStateSub = player.playerStateStream.listen((state) {
      final shouldLogMem = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
      if (state.processingState == ProcessingState.completed) {
        appendLog('Playback completed');
        // At end of the last track, just_audio can remain in an "at end" state
        // where a first Play press does not restart cleanly. Normalize by
        // rewinding to 0 while staying paused so the next Play is a true replay.
        if (!_handlingCompletion && !player.hasNext) {
          _handlingCompletion = true;
          unawaited(() async {
            try {
              await player.pause();
              await player.seek(Duration.zero, index: player.currentIndex);
            } catch (e, st) {
              appendLog('Completion rewind failed: $e\n$st');
            } finally {
              _handlingCompletion = false;
            }
          }());
        }
      }
      if (!shouldLogMem) return;
      if (state.playing) {
        _rssTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
          try {
            final rss = ProcessInfo.currentRss;
            appendLog(
                'Mem: rss=${(rss / (1024 * 1024)).toStringAsFixed(1)}MiB');
          } catch (_) {}
        });
      } else {
        _rssTimer?.cancel();
        _rssTimer = null;
      }
    });

    _currentIndexSub = player.currentIndexStream.distinct().listen((idx) {
      final queue = _queue;
      if (queue == null) return;
      if (idx == null) return;
      if (idx < 0 || idx >= queue.length) return;
      if (idx == _queueIndex) return;
      _lastPreviousPressedAt = null;
      _queueIndex = idx;
      _publishQueueState();
      unawaited(_syncNowPlayingFromQueueIndex(idx));
      unawaited(systemMedia.setQueueAvailability(
        canGoNext: canPlayNextTrack,
        canGoPrevious: canPlayPreviousTrack,
      ));
    });
  }

  Future<void> _syncNowPlayingFromQueueIndex(int idx) async {
    final queue = _queue;
    if (queue == null) return;
    if (idx < 0 || idx >= queue.length) return;
    final f = queue[idx];
    final name = p.basename(f.path);
    try {
      final ext = p.extension(name).toLowerCase();
      final isFurry =
          ext == '.furry' || await api.isValidFurryFile(filePath: f.path);
      if (isFurry) {
        final originalExt = await api.getOriginalFormat(filePath: f.path);
        final meta = await getMetaPreviewForFurry(f);
        nowPlaying.value = _NowPlaying(
          title: meta.title.isEmpty ? name : meta.title,
          subtitle:
              meta.subtitle.isEmpty ? '.furry → $originalExt' : meta.subtitle,
          sourcePath: f.path,
          artUri: meta.artUri,
        );
      } else {
        nowPlaying.value = _NowPlaying(
          title: name,
          subtitle: '本地文件',
          sourcePath: f.path,
          artUri: null,
        );
      }
    } catch (e, st) {
      appendLog('Queue sync failed: $e\n$st');
    }
  }

  Future<Uri?> _writeCoverPayloadToTempUri({
    required String mime,
    required Uint8List bytes,
  }) async {
    if (bytes.isEmpty) return null;

    final tmp = await getTemporaryDirectory();
    final artDir = Directory(p.join(tmp.path, 'furry_media_art'));
    if (!await artDir.exists()) await artDir.create(recursive: true);

    final m = mime.toLowerCase();
    final ext = m.contains('png')
        ? 'png'
        : m.contains('webp')
            ? 'webp'
            : 'jpg';

    // IMPORTANT: Use a stable name based on *content* so we don't re-write
    // identical cover arts over and over across sessions. `Uint8List.hashCode`
    // is identity-based and would explode disk usage.
    final out = File(p.join(
      artDir.path,
      'cover_${bytes.length}_${_fnv1a64Hex(bytes)}.$ext',
    ));
    if (!await out.exists()) {
      await out.writeAsBytes(bytes, flush: true);
    }
    return out.uri;
  }

  static String _fnv1a64Hex(Uint8List bytes) {
    const int fnvOffset = 0xcbf29ce484222325;
    const int fnvPrime = 0x100000001b3;
    const int mask64 = 0xFFFFFFFFFFFFFFFF;
    const int maxSamples = 65536; // ~65k ops, safe on mobile

    final len = bytes.length;
    if (len == 0) return '0'.padLeft(16, '0');

    final sampleCount = len <= maxSamples ? len : maxSamples;
    final stride = (len / sampleCount).floor().clamp(1, len);

    var hash = fnvOffset;
    var idx = 0;
    for (var i = 0; i < sampleCount; i++) {
      hash ^= bytes[idx];
      hash = (hash * fnvPrime) & mask64;
      idx += stride;
      if (idx >= len) idx = len - 1;
    }

    // Mix in length for better collision resistance on short samples.
    hash ^= len;
    hash = (hash * fnvPrime) & mask64;

    return hash.toRadixString(16).padLeft(16, '0');
  }

  void appendLog(String msg) {
    log.value = '${DateTime.now().toIso8601String()}  $msg\n${log.value}';
    // Keep in-memory log bounded; otherwise the UI string can grow without limit and bloat RSS.
    const maxChars = 200000; // ~200KB (chars), conservative for mobile
    if (log.value.length > maxChars) {
      log.value = log.value.substring(0, maxChars);
    }
    unawaited(_DiagnosticsLog.appendLine(msg));
  }

  Future<void> clearLog() async {
    log.value = '';
    await _DiagnosticsLog.clear();
  }

  Future<String?> exportLog() async {
    final path = await _DiagnosticsLog.exportToDocuments();
    if (path != null) {
      appendLog('Log exported: $path');
    }
    return path;
  }

  Future<Directory> outputsDir() async {
    final doc = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(doc.path, 'outputs'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> writePickedBytesToTemp({
    required String filenameHint,
    required Uint8List bytes,
  }) async {
    final tmp = await getTemporaryDirectory();
    final safeName = filenameHint.isEmpty ? 'input.bin' : filenameHint;
    final out = File(p.join(
        tmp.path, 'import_${DateTime.now().millisecondsSinceEpoch}_$safeName'));
    await out.writeAsBytes(bytes, flush: true);
    return out;
  }

  Future<File> writePickedStreamToTemp({
    required String filenameHint,
    required Stream<List<int>> stream,
  }) async {
    final tmp = await getTemporaryDirectory();
    final safeName = filenameHint.isEmpty ? 'input.bin' : filenameHint;
    final out = File(p.join(
        tmp.path, 'import_${DateTime.now().millisecondsSinceEpoch}_$safeName'));
    final sink = out.openWrite();
    await sink.addStream(stream);
    await sink.flush();
    await sink.close();
    return out;
  }

  Future<File?> materializePickedFile(PlatformFile file) async {
    final path = file.path;
    if (path != null && path.isNotEmpty) return File(path);
    if (file.readStream != null) {
      return writePickedStreamToTemp(
          filenameHint: file.name, stream: file.readStream!);
    }
    if (file.bytes != null) {
      return writePickedBytesToTemp(
          filenameHint: file.name, bytes: file.bytes!);
    }
    return null;
  }

  Future<void> pickForPack() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      withData: false,
      withReadStream: true,
    );
    final file = result?.files.single;
    if (file == null) return;
    final realFile = await materializePickedFile(file);
    if (realFile == null) {
      appendLog(
          'Pick failed: file path/stream unavailable (try a different picker / storage)');
      return;
    }
    pickedForPack = realFile;
    pickedForPackName =
        file.name.isEmpty ? p.basename(realFile.path) : file.name;
    appendLog('Picked for pack: ${pickedForPackName!}');
  }

  Future<void> startPack() async {
    final input = pickedForPack;
    if (input == null) {
      appendLog('No pack input selected');
      return;
    }

    final outDir = await outputsDir();
    final base = p.basenameWithoutExtension(pickedForPackName ?? input.path);
    final outPath = p.join(outDir.path, '$base.furry');

    appendLog('Packing…');
    final rc = await api.packToFurry(
      inputPath: input.path,
      outputPath: outPath,
      paddingKb: paddingKb,
    );
    if (rc == 0) {
      appendLog('Pack ok: ${p.basename(outPath)}');
      await refreshOutputs();
    } else {
      appendLog('Pack failed: rc=$rc');
    }
  }

  Future<void> refreshOutputs() async {
    final outDir = await outputsDir();
    final files = outDir
        .listSync()
        .whereType<File>()
        .where((f) => p.extension(f.path).toLowerCase() == '.furry')
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    furryOutputs.value = files;
  }

  Future<File?> pickForPlay() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['mp3', 'wav', 'ogg', 'flac', 'furry'],
      withData: false,
      withReadStream: true,
    );
    final file = result?.files.single;
    if (file == null) return null;
    final realFile = await materializePickedFile(file);
    if (realFile == null) {
      appendLog(
          'Pick failed: file path/stream unavailable (try a different picker / storage)');
      return null;
    }
    appendLog(
        'Picked for play: ${file.name.isEmpty ? p.basename(realFile.path) : file.name}');
    return realFile;
  }

  Future<void> playFile({
    required File file,
    String? displayName,
  }) async {
    final name = displayName ?? p.basename(file.path);

    // If this file belongs to the current queue, keep queue navigation working.
    final queue = _queue;
    if (queue != null) {
      final idx = queue.indexWhere((f) => f.path == file.path);
      if (idx >= 0) {
        _queueIndex = idx;
      } else {
        _queue = null;
        _queueIndex = -1;
        _androidPlaylistActive = false;
      }
    } else {
      _queueIndex = -1;
      _androidPlaylistActive = false;
    }
    _publishQueueState();
    unawaited(systemMedia.setQueueAvailability(
      canGoNext: canPlayNextTrack,
      canGoPrevious: canPlayPreviousTrack,
    ));

    nowPlaying.value = _NowPlaying(
      title: name,
      subtitle: '正在加载…',
      sourcePath: file.path,
      artUri: nowPlaying.value?.sourcePath == file.path
          ? nowPlaying.value?.artUri
          : null,
    );
    try {
      final ext = p.extension(name).toLowerCase();
      final isFurry =
          ext == '.furry' || await api.isValidFurryFile(filePath: file.path);

      if (isFurry) {
        await cleanupTempArtifacts();
        final originalExt = await api.getOriginalFormat(filePath: file.path);
        final tmp = await getTemporaryDirectory();
        final outDir = Directory(p.join(tmp.path, 'furry_unpacked'));
        if (!await outDir.exists()) await outDir.create(recursive: true);
        final outExt = originalExt.trim().isEmpty ? 'bin' : originalExt.trim();
        final outPath = p.join(
          outDir.path,
          'unpacked_${file.path.hashCode}_${DateTime.now().millisecondsSinceEpoch}.$outExt',
        );
        appendLog('Unpacking .furry → $outExt…');
        final rc =
            await api.unpackToFile(inputPath: file.path, outputPath: outPath);
        File? unpacked;
        if (rc == 0) {
          final f = File(outPath);
          if (await f.exists()) {
            unpacked = f;
          } else {
            appendLog('Unpack ok but output missing: $outPath');
          }
        } else {
          appendLog('Unpack-to-file failed: rc=$rc (fallback to bytes)');
        }

        final meta = await getMetaPreviewForFurry(file);
        final artUriUi = meta.artUri;
        final artUriSystem = artUriUi;
        nowPlaying.value = _NowPlaying(
          title: meta.title.isEmpty ? name : meta.title,
          subtitle: meta.subtitle.isEmpty
              ? '.furry → $originalExt（准备播放…）'
              : meta.subtitle,
          sourcePath: file.path,
          artUri: artUriUi,
        );
        final mediaItem = MediaItem(
          id: file.path,
          title: meta.title.isEmpty ? name : meta.title,
          artist: meta.artist.isNotEmpty ? meta.artist : meta.subtitle,
          artUri: artUriSystem,
        );
        if (unpacked != null) {
          await player.setAudioSource(
            AudioSource.uri(unpacked.uri, tag: mediaItem),
          );
        } else {
          final bytes = await api.unpackFromFurryToBytes(inputPath: file.path);
          if (bytes == null) {
            appendLog('Unpack-to-bytes failed: null');
            return;
          }
          // Prefer writing to a temp file to avoid OOM for large audio.
          final fallbackPath = p.join(
            outDir.path,
            'unpacked_mem_${file.path.hashCode}_${DateTime.now().millisecondsSinceEpoch}.$outExt',
          );
          try {
            final f = File(fallbackPath);
            await f.writeAsBytes(bytes, flush: true);
            unpacked = f;
            await player.setAudioSource(
              AudioSource.uri(unpacked.uri, tag: mediaItem),
            );
          } catch (e, st) {
            appendLog('Write-bytes fallback failed: $e\n$st');
            String? mime;
            switch (originalExt.trim().toLowerCase()) {
              case 'mp3':
                mime = 'audio/mpeg';
                break;
              case 'wav':
                mime = 'audio/wav';
                break;
              case 'ogg':
                mime = 'audio/ogg';
                break;
              case 'flac':
                mime = 'audio/flac';
                break;
            }
            await player.setAudioSource(
              InMemoryAudioSource(
                bytes: bytes,
                contentType: mime,
                tag: mediaItem,
              ),
            );
          }
        }
        await play();
        final title = meta.title.isEmpty ? name : meta.title;
        nowPlaying.value = _NowPlaying(
          title: title,
          subtitle:
              meta.subtitle.isEmpty ? '.furry → $originalExt' : meta.subtitle,
          sourcePath: file.path,
          artUri: artUriUi,
        );
        await systemMedia.setMetadata(
          SystemMediaMetadata(
            title: title,
            artist: meta.subtitle,
            album: '',
            artUri: artUriSystem,
            duration: player.duration,
          ),
        );
        if (unpacked != null) {
          appendLog(
              'Playing (.furry → $originalExt): ${p.basename(unpacked.path)}');
        } else {
          appendLog('Playing (.furry → $originalExt): in-memory');
        }
      } else {
        final mediaItem = MediaItem(
          id: file.path,
          title: name,
          artist: '',
          artUri: null,
        );
        await player.setAudioSource(AudioSource.uri(file.uri, tag: mediaItem));
        await play();
        nowPlaying.value = _NowPlaying(
            title: name, subtitle: '本地文件', sourcePath: file.path, artUri: null);
        await systemMedia.setMetadata(
          SystemMediaMetadata(
            title: name,
            artist: '',
            album: '',
            artUri: null,
            duration: player.duration,
          ),
        );
        appendLog('Playing (raw): $name');
      }
    } catch (e, st) {
      appendLog('Play failed: $e\n$st');
    }
  }

  Future<void> playFromQueue({
    required List<File> queue,
    required int index,
    String? displayName,
  }) async {
    if (queue.isEmpty) return;
    if (index < 0 || index >= queue.length) return;

    // On Android, use a playlist so audio_service can expose next/previous in the
    // system notification/lockscreen controls.
    if (!kIsWeb && Platform.isAndroid && queue.length > 1) {
      _queue = List<File>.from(queue);
      _queueIndex = index;
      _androidPlaylistActive = true;
      _publishQueueState();
      unawaited(systemMedia.setQueueAvailability(
        canGoNext: canPlayNextTrack,
        canGoPrevious: canPlayPreviousTrack,
      ));

      final name = displayName ?? p.basename(queue[index].path);
      nowPlaying.value = _NowPlaying(
        title: name,
        subtitle: '正在加载…',
        sourcePath: queue[index].path,
        artUri: null,
      );
      // Don't wait for the whole playlist to be prepared before showing metadata
      // for the selected track; otherwise users see "loading" until a second tap.
      unawaited(_syncNowPlayingFromQueueIndex(index));

      await cleanupTempArtifacts();
      final tmp = await getTemporaryDirectory();
      final outDir = Directory(p.join(tmp.path, 'furry_unpacked'));
      if (!await outDir.exists()) await outDir.create(recursive: true);

      Future<File> ensurePlayableFileForFurry(File furryFile) async {
        final originalExt =
            await api.getOriginalFormat(filePath: furryFile.path);
        final outExt = originalExt.trim().isEmpty ? 'bin' : originalExt.trim();
        final outPath = p.join(
          outDir.path,
          'unpacked_${furryFile.path.hashCode}_${DateTime.now().millisecondsSinceEpoch}.$outExt',
        );
        final rc = await api.unpackToFile(
            inputPath: furryFile.path, outputPath: outPath);
        final f = File(outPath);
        if (rc == 0 && await f.exists()) return f;

        final bytes =
            await api.unpackFromFurryToBytes(inputPath: furryFile.path);
        if (bytes == null) {
          throw StateError('Unpack-to-bytes failed: null');
        }
        await f.writeAsBytes(bytes, flush: true);
        return f;
      }

      final sources = <AudioSource>[];
      for (final f in queue) {
        final base = p.basename(f.path);
        final ext = p.extension(base).toLowerCase();
        final isFurry =
            ext == '.furry' || await api.isValidFurryFile(filePath: f.path);

        Uri uri;
        String title;
        String artist;
        Uri? artUri;

        if (isFurry) {
          final playable = await ensurePlayableFileForFurry(f);
          uri = playable.uri;
          final meta = await getMetaPreviewForFurry(f);
          title = meta.title.isEmpty ? base : meta.title;
          artist = meta.artist.isNotEmpty ? meta.artist : meta.subtitle;
          artUri = meta.artUri;
        } else {
          uri = f.uri;
          title = base;
          artist = '';
          artUri = null;
        }

        sources.add(
          AudioSource.uri(
            uri,
            tag: MediaItem(
              id: f.path,
              title: title,
              artist: artist,
              artUri: artUri,
            ),
          ),
        );
      }

      await player.setAudioSource(
        ConcatenatingAudioSource(children: sources),
        initialIndex: index,
        initialPosition: Duration.zero,
      );
      await play();

      // Update UI immediately (system controls update via MediaItem tags).
      await _syncNowPlayingFromQueueIndex(index);
      return;
    }

    _androidPlaylistActive = false;
    _queue = List<File>.from(queue);
    _queueIndex = index;
    _publishQueueState();
    unawaited(systemMedia.setQueueAvailability(
      canGoNext: canPlayNextTrack,
      canGoPrevious: canPlayPreviousTrack,
    ));
    await playFile(
      file: queue[index],
      displayName: displayName ?? p.basename(queue[index].path),
    );
  }

  bool get canPlayPreviousTrack => _queue != null && _queue!.length > 1;
  bool get canPlayNextTrack => _queue != null && _queue!.length > 1;

  Future<void> playPreviousTrack() async {
    final queue = _queue;
    if (queue == null) return;
    final now = DateTime.now();
    final withinWindow = _lastPreviousPressedAt != null &&
        now.difference(_lastPreviousPressedAt!) <= _previousDoublePressWindow;
    _lastPreviousPressedAt = now;

    if (!withinWindow) {
      await player.seek(Duration.zero);
      await play();
      return;
    }

    if (queue.length <= 1) return;
    final nextIdx = (_queueIndex - 1 + queue.length) % queue.length;
    if (_androidPlaylistActive && !kIsWeb && Platform.isAndroid) {
      _queueIndex = nextIdx;
      _publishQueueState();
      unawaited(systemMedia.setQueueAvailability(
        canGoNext: canPlayNextTrack,
        canGoPrevious: canPlayPreviousTrack,
      ));
      await player.seek(Duration.zero, index: nextIdx);
      await play();
      await _syncNowPlayingFromQueueIndex(nextIdx);
      return;
    }
    await playFromQueue(queue: queue, index: nextIdx);
  }

  Future<void> playNextTrack() async {
    final queue = _queue;
    if (queue == null) return;
    if (queue.length <= 1) return;
    final nextIdx = (_queueIndex + 1) % queue.length;
    if (_androidPlaylistActive && !kIsWeb && Platform.isAndroid) {
      _queueIndex = nextIdx;
      _publishQueueState();
      unawaited(systemMedia.setQueueAvailability(
        canGoNext: canPlayNextTrack,
        canGoPrevious: canPlayPreviousTrack,
      ));
      await player.seek(Duration.zero, index: nextIdx);
      await play();
      await _syncNowPlayingFromQueueIndex(nextIdx);
      return;
    }
    await playFromQueue(queue: queue, index: nextIdx);
  }

  Future<void> stop() async {
    await player.stop();
    appendLog('Stopped');
  }

  Future<void> play() async {
    // If the current track has completed, pressing play should restart it.
    final duration = player.duration;
    final atEnd = duration != null &&
        duration > Duration.zero &&
        player.position >= (duration - const Duration(milliseconds: 200));
    if (player.processingState == ProcessingState.completed || atEnd) {
      await player.seek(Duration.zero, index: player.currentIndex);
    }
    await player.play();
  }

  Future<void> pause() async {
    await player.pause();
  }

  Future<void> togglePlayPause(bool playing) async {
    if (playing) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> seek(Duration position) async {
    await player.seek(position);
  }

  String _fmt(Duration? d) {
    if (d == null) return '--:--';
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> seekBy(Duration delta) async {
    try {
      final duration = player.duration;
      final position = player.position;
      final target = position + delta;
      var clamped = target;
      if (clamped.isNegative) clamped = Duration.zero;
      if (duration != null && clamped > duration) clamped = duration;
      await seek(clamped);
    } catch (e, st) {
      appendLog('Seek failed: $e\n$st');
    }
  }

  Future<void> playAtQueueIndex(int index) async {
    final queue = _queue;
    if (queue == null || queue.isEmpty) return;
    if (index < 0 || index >= queue.length) return;

    if (_androidPlaylistActive && !kIsWeb && Platform.isAndroid) {
      _queueIndex = index;
      _publishQueueState();
      unawaited(systemMedia.setQueueAvailability(
        canGoNext: canPlayNextTrack,
        canGoPrevious: canPlayPreviousTrack,
      ));
      await player.seek(Duration.zero, index: index);
      await play();
      await _syncNowPlayingFromQueueIndex(index);
      return;
    }

    await playFromQueue(queue: queue, index: index);
  }

  void clearQueue({bool keepPlaying = true}) {
    _queue = null;
    _queueIndex = -1;
    _androidPlaylistActive = false;
    _publishQueueState();
    unawaited(systemMedia.setQueueAvailability(
      canGoNext: canPlayNextTrack,
      canGoPrevious: canPlayPreviousTrack,
    ));
    if (!keepPlaying) {
      unawaited(stop());
      nowPlaying.value = null;
    }
  }

  Future<void> removeFromQueueByPath(String path) async {
    final queue = _queue;
    if (queue == null || queue.isEmpty) return;

    final idx = queue.indexWhere((f) => f.path == path);
    if (idx < 0) return;

    final currentPath = nowPlaying.value?.sourcePath;
    queue.removeAt(idx);
    if (queue.isEmpty) {
      clearQueue(keepPlaying: false);
      return;
    }

    // Keep the current track if possible.
    if (currentPath != null) {
      final newIdx = queue.indexWhere((f) => f.path == currentPath);
      _queueIndex = newIdx >= 0 ? newIdx : 0;
    } else {
      _queueIndex = _queueIndex.clamp(0, queue.length - 1);
    }
    _publishQueueState();
    unawaited(systemMedia.setQueueAvailability(
      canGoNext: canPlayNextTrack,
      canGoPrevious: canPlayPreviousTrack,
    ));
  }

  Future<void> enqueueFile(File file, {bool playNext = false}) async {
    final currentPath = nowPlaying.value?.sourcePath;
    final q = _queue == null ? <File>[] : List<File>.from(_queue!);

    // If no explicit queue exists yet, bootstrap from the current track.
    if (q.isEmpty && currentPath != null) {
      q.add(File(currentPath));
      _queueIndex = 0;
    }

    // De-dupe by path (keep earliest).
    if (q.any((f) => f.path == file.path)) return;

    if (playNext && q.isNotEmpty && _queueIndex >= 0) {
      q.insert((_queueIndex + 1).clamp(0, q.length), file);
    } else {
      q.add(file);
    }

    _queue = q;
    _publishQueueState();
    unawaited(systemMedia.setQueueAvailability(
      canGoNext: canPlayNextTrack,
      canGoPrevious: canPlayPreviousTrack,
    ));
  }

  void moveQueueItem(int oldIndex, int newIndex) {
    final queue = _queue;
    if (queue == null || queue.isEmpty) return;
    if (oldIndex < 0 || oldIndex >= queue.length) return;
    if (newIndex < 0 || newIndex >= queue.length) return;
    if (oldIndex == newIndex) return;

    final currentPath = nowPlaying.value?.sourcePath;
    final item = queue.removeAt(oldIndex);
    queue.insert(newIndex, item);

    if (currentPath != null) {
      final idx = queue.indexWhere((f) => f.path == currentPath);
      _queueIndex = idx;
    } else {
      _queueIndex = _queueIndex.clamp(0, queue.length - 1);
    }
    _publishQueueState();
  }

  Future<_LibraryIndex> buildLibraryIndex(List<File> files) async {
    final states = <(File file, DateTime modified, int bytes)>[];
    for (final file in files) {
      try {
        final stat = await file.stat();
        states.add((file, stat.modified, stat.size));
      } catch (e, st) {
        appendLog('Index stat failed: ${file.path}: $e\n$st');
      }
    }

    final signature = Object.hash(
      states.length,
      Object.hashAll(
        states.map(
          (state) => Object.hash(
            state.$1.path,
            state.$2.microsecondsSinceEpoch,
            state.$3,
          ),
        ),
      ),
    );
    final cached = _libraryIndexCache;
    if (cached != null && cached.signature == signature) {
      return cached.index;
    }

    final activePaths = <String>{};
    final tracks = <_TrackEntry>[];
    for (final state in states) {
      final file = state.$1;
      final modified = state.$2;
      final bytes = state.$3;
      final path = file.path;
      activePaths.add(path);

      final trackCached = _trackEntryCache[path];
      if (trackCached != null &&
          trackCached.modified == modified &&
          trackCached.bytes == bytes) {
        tracks.add(trackCached.track);
        continue;
      }

      try {
        final meta = await getMetaPreviewForFurry(file, modified: modified);
        final track = _TrackEntry(
          file: file,
          meta: meta,
          modified: modified,
          bytes: bytes,
        );
        _trackEntryCache[path] = _TrackEntryCacheEntry(
          modified: modified,
          bytes: bytes,
          track: track,
        );
        tracks.add(track);
      } catch (e, st) {
        appendLog('Index meta failed: $path: $e\n$st');
        final track = _TrackEntry(
          file: file,
          meta: _MetaPreview(
            title: p.basename(path),
            artist: '',
            album: '',
            subtitle: '',
            artUri: null,
            coverBytesLen: null,
          ),
          modified: modified,
          bytes: bytes,
        );
        _trackEntryCache[path] = _TrackEntryCacheEntry(
          modified: modified,
          bytes: bytes,
          track: track,
        );
        tracks.add(track);
      }
    }

    _trackEntryCache.removeWhere((path, _) => !activePaths.contains(path));
    _metaPreviewCache.removeWhere((path, _) => !activePaths.contains(path));

    final albumsByKey = <String, _AlbumGroup>{};
    final artistsByKey = <String, _ArtistGroup>{};

    for (final t in tracks) {
      final albumName = t.meta.album.trim();
      final artistName = t.meta.artist.trim();
      final albumKey = '${artistName.toLowerCase()}|${albumName.toLowerCase()}';
      final artistKey = artistName.toLowerCase();

      final album = albumsByKey.putIfAbsent(
        albumKey,
        () => _AlbumGroup(
          album: albumName,
          artist: artistName,
          artUri: t.meta.artUri,
        ),
      );
      album.tracks.add(t);
      album.artUri ??= t.meta.artUri;

      final artist = artistsByKey.putIfAbsent(
        artistKey,
        () => _ArtistGroup(artist: artistName, artUri: t.meta.artUri),
      );
      artist.tracks.add(t);
      artist.artUri ??= t.meta.artUri;
      artist.albumsByKey.putIfAbsent(albumKey, () => album);
    }

    final albums = albumsByKey.values.toList(growable: false)
      ..sort((a, b) => a.title.compareTo(b.title));
    final artists = artistsByKey.values.toList(growable: false)
      ..sort((a, b) => a.title.compareTo(b.title));

    for (final a in albums) {
      a.tracks.sort((x, y) => x.displayTitle.compareTo(y.displayTitle));
    }
    for (final ar in artists) {
      for (final alb in ar.albumsByKey.values) {
        alb.tracks.sort((x, y) => x.displayTitle.compareTo(y.displayTitle));
      }
    }

    final result =
        _LibraryIndex(tracks: tracks, albums: albums, artists: artists);
    _libraryIndexCache = _LibraryIndexCacheEntry(
      signature: signature,
      index: result,
    );
    return result;
  }
}

/// 当前正在播放的条目（供 UI 展示）。
///
/// 该结构只保存 UI 需要的摘要信息：标题/副标题/来源路径/封面 URI。
/// 真实播放源与队列由 `_AppController.player` / `_AppController.queueState` 管理。
class _NowPlaying {
  final String title;
  final String subtitle;
  final String sourcePath;
  final Uri? artUri;

  _NowPlaying({
    required this.title,
    required this.subtitle,
    required this.sourcePath,
    required this.artUri,
  });
}

/// 播放队列快照（供 UI 订阅）。
///
/// `queue` 是文件列表；`index` 指向当前播放项（-1 表示无有效索引）。
class _QueueState {
  final List<File> queue;
  final int index;

  const _QueueState({required this.queue, required this.index});

  bool get hasQueue => queue.isNotEmpty;

  File? get currentFile {
    if (index < 0 || index >= queue.length) return null;
    return queue[index];
  }
}

/// `.furry` 文件的轻量元信息预览（用于列表页快速渲染）。
///
/// 该结构会从 `.furry` 的 tags JSON + cover payload 中提取：
/// - 标题/歌手/专辑
/// - 组合副标题（artist · album）
/// - 封面临时文件 URI（避免在列表里直接持有大字节数组）
class _MetaPreview {
  final String title;
  final String artist;
  final String album;
  final String subtitle;
  final Uri? artUri;
  final int? coverBytesLen;

  _MetaPreview({
    required this.title,
    required this.artist,
    required this.album,
    required this.subtitle,
    required this.artUri,
    required this.coverBytesLen,
  });
}

enum _LibraryView { tracks, albums, artists, queue }

enum _LibrarySort { recent, title, artist, album, size }

class _LibraryOptions {
  final _LibrarySort sort;
  final bool ascending;
  final bool onlyWithCover;

  const _LibraryOptions({
    required this.sort,
    required this.ascending,
    required this.onlyWithCover,
  });
}

class _SuggestionCacheEntry {
  final List<_TrackEntry> matches;
  final bool complete;

  const _SuggestionCacheEntry({
    required this.matches,
    required this.complete,
  });
}

class _TrackEntry {
  final File file;
  final _MetaPreview meta;
  final DateTime modified;
  final int bytes;

  const _TrackEntry({
    required this.file,
    required this.meta,
    required this.modified,
    required this.bytes,
  });

  String get path => file.path;

  String get displayTitle =>
      meta.title.isEmpty ? p.basename(file.path) : meta.title;

  String get displayArtist {
    if (meta.artist.isNotEmpty) return meta.artist;
    final parts = meta.subtitle.split(' · ');
    return parts.isEmpty ? '' : parts.first;
  }

  String get displayAlbum => meta.album;
}

class _AlbumGroup {
  final String album;
  final String artist;
  Uri? artUri;
  final List<_TrackEntry> tracks = <_TrackEntry>[];

  _AlbumGroup({
    required this.album,
    required this.artist,
    required this.artUri,
  });

  String get title => album.isEmpty ? '未知专辑' : album;
  String get subtitle => artist.isEmpty ? '未知歌手' : artist;
}

class _ArtistGroup {
  final String artist;
  Uri? artUri;
  final Map<String, _AlbumGroup> albumsByKey = <String, _AlbumGroup>{};
  final List<_TrackEntry> tracks = <_TrackEntry>[];

  _ArtistGroup({required this.artist, required this.artUri});

  String get title => artist.isEmpty ? '未知歌手' : artist;
}

class _LibraryIndex {
  final List<_TrackEntry> tracks;
  final List<_AlbumGroup> albums;
  final List<_ArtistGroup> artists;

  const _LibraryIndex({
    required this.tracks,
    required this.albums,
    required this.artists,
  });
}

/// 本地音乐库页：搜索 + 模块入口（歌曲/专辑/歌手/队列）+ 内容区。
///
/// 数据来源：`_AppController.furryOutputs`（最近输出的 `.furry` 文件列表）。
/// 为避免重复解析，索引构建使用 `Future<_LibraryIndex>` + hash 缓存。
class LibraryPage extends StatefulWidget {
  final _AppController controller;
  const LibraryPage({super.key, required this.controller});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final SearchController _searchController = SearchController();
  String _query = '';
  String _pendingQuery = '';
  Timer? _queryDebounceTimer;
  static const Duration _searchDebounceDelay = Duration(milliseconds: 180);
  int? _suggestionCacheSourceHash;
  final Map<String, _SuggestionCacheEntry> _suggestionCache =
      <String, _SuggestionCacheEntry>{};
  static const int _suggestionCacheLimit = 32;
  static const int _suggestionMaxStoredMatches = 256;
  _LibraryView _view = _LibraryView.tracks;
  _LibrarySort _sort = _LibrarySort.recent;
  bool _ascending = false;
  bool _onlyWithCover = false;

  int? _lastFilesHash;
  Future<_LibraryIndex>? _indexFuture;

  @override
  void dispose() {
    _queryDebounceTimer?.cancel();
    _suggestionCache.clear();
    _searchController.dispose();
    super.dispose();
  }

  void _applyQueryImmediately(String value) {
    final next = value.trim();
    _queryDebounceTimer?.cancel();
    _pendingQuery = next;
    if (_query == next) return;
    setState(() => _query = next);
  }

  void _scheduleQueryUpdate(String value) {
    final next = value.trim();
    _pendingQuery = next;
    _queryDebounceTimer?.cancel();
    _queryDebounceTimer = Timer(_searchDebounceDelay, () {
      if (!mounted || _query == _pendingQuery) return;
      setState(() => _query = _pendingQuery);
    });
  }

  Future<_LibraryIndex> _getIndexFuture(
      _AppController controller, List<File> files) {
    final hash = _filesStateHash(files);
    if (_indexFuture == null || _lastFilesHash != hash) {
      _lastFilesHash = hash;
      _indexFuture = controller.buildLibraryIndex(files);
    }
    return _indexFuture!;
  }

  int _filesStateHash(List<File> files) {
    final fileHashes = <int>[];
    for (final file in files) {
      try {
        final stat = file.statSync();
        fileHashes.add(Object.hash(
          file.path,
          stat.modified.microsecondsSinceEpoch,
          stat.size,
        ));
      } catch (_) {
        fileHashes.add(Object.hash(file.path, 0, 0));
      }
    }
    return Object.hash(files.length, Object.hashAll(fileHashes));
  }

  List<_TrackEntry> _buildSuggestions(
    List<_TrackEntry> tracks,
    String queryLower,
    int sourceHash,
  ) {
    if (queryLower.isEmpty) {
      return tracks.take(6).toList(growable: false);
    }

    if (_suggestionCacheSourceHash != sourceHash) {
      _suggestionCacheSourceHash = sourceHash;
      _suggestionCache.clear();
    }

    final exactCached = _suggestionCache[queryLower];
    if (exactCached != null) {
      return exactCached.matches.take(8).toList(growable: false);
    }

    List<_TrackEntry>? basePool;
    if (queryLower.length >= 2) {
      final prefixes = _suggestionCache.keys
          .where((key) =>
              key.isNotEmpty &&
              queryLower.startsWith(key) &&
              _suggestionCache[key]!.complete)
          .toList(growable: false)
        ..sort((a, b) => b.length.compareTo(a.length));
      if (prefixes.isNotEmpty) {
        basePool = _suggestionCache[prefixes.first]!.matches;
      }
    }

    final input = basePool ?? tracks;
    final matches = <_TrackEntry>[];
    var complete = true;
    for (final track in input) {
      if (_matchesQuery(track, queryLower)) {
        if (matches.length < _suggestionMaxStoredMatches) {
          matches.add(track);
        } else {
          complete = false;
          break;
        }
      }
    }

    final entry = _SuggestionCacheEntry(
      matches: List<_TrackEntry>.unmodifiable(matches),
      complete: complete,
    );
    _suggestionCache[queryLower] = entry;

    if (_suggestionCache.length > _suggestionCacheLimit) {
      _suggestionCache.remove(_suggestionCache.keys.first);
    }

    return matches.take(8).toList(growable: false);
  }

  Widget _buildSuggestionTile(
    SearchController searchController,
    _TrackEntry track, {
    bool showArrow = false,
  }) {
    return ListTile(
      leading: _CoverThumb(artUri: track.meta.artUri),
      title: Text(track.displayTitle,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        track.meta.subtitle.isEmpty ? '本地文件' : track.meta.subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: showArrow ? const Icon(Icons.north_west_rounded) : null,
      onTap: () {
        searchController.closeView(track.displayTitle);
        _applyQueryImmediately(track.displayTitle);
      },
    );
  }

  Widget _buildSuggestionContent(
    SearchController searchController,
    String queryLower,
    List<_TrackEntry> suggestions,
  ) {
    if (queryLower.isEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(
            leading: Icon(Icons.auto_awesome_rounded),
            title: Text('建议'),
            subtitle: Text('试试搜索歌名、专辑或歌手'),
          ),
          for (final track in suggestions)
            _buildSuggestionTile(searchController, track),
        ],
      );
    }

    if (suggestions.isEmpty) {
      return ListTile(
        leading: const Icon(Icons.search_off_rounded),
        title: Text('无结果：${searchController.text}'),
        subtitle: const Text('试试更短的关键词'),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final track in suggestions)
          _buildSuggestionTile(searchController, track, showArrow: true),
      ],
    );
  }

  bool _matchesQuery(_TrackEntry t, String queryLower) {
    if (queryLower.isEmpty) return true;
    final base = p.basename(t.file.path).toLowerCase();
    final title = t.displayTitle.toLowerCase();
    final artist = t.meta.artist.toLowerCase();
    final album = t.meta.album.toLowerCase();
    return base.contains(queryLower) ||
        title.contains(queryLower) ||
        artist.contains(queryLower) ||
        album.contains(queryLower);
  }

  Future<void> _openOptionsSheet() async {
    final current = _LibraryOptions(
      sort: _sort,
      ascending: _ascending,
      onlyWithCover: _onlyWithCover,
    );
    final next = await showModalBottomSheet<_LibraryOptions>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _LibraryOptionsSheet(value: current),
    );
    if (!mounted || next == null) return;
    setState(() {
      _sort = next.sort;
      _ascending = next.ascending;
      _onlyWithCover = next.onlyWithCover;
    });
  }

  int _compareTrack(_TrackEntry a, _TrackEntry b) {
    int result;
    switch (_sort) {
      case _LibrarySort.recent:
        result = b.modified.compareTo(a.modified);
        break;
      case _LibrarySort.title:
        result = a.displayTitle.compareTo(b.displayTitle);
        break;
      case _LibrarySort.artist:
        result = a.meta.artist.compareTo(b.meta.artist);
        break;
      case _LibrarySort.album:
        result = a.meta.album.compareTo(b.meta.album);
        break;
      case _LibrarySort.size:
        result = b.bytes.compareTo(a.bytes);
        break;
    }
    return _ascending ? -result : result;
  }

  List<_TrackEntry> _buildFilteredTracks(
      _LibraryIndex index, String queryLower) {
    final tracks = index.tracks
        .where((track) => !_onlyWithCover || track.meta.artUri != null)
        .where((track) => _matchesQuery(track, queryLower))
        .toList(growable: false)
      ..sort(_compareTrack);
    return tracks;
  }

  List<_AlbumGroup> _buildFilteredAlbums(
      _LibraryIndex index, String queryLower) {
    return index.albums.where((album) {
      if (_onlyWithCover && album.artUri == null) return false;
      if (queryLower.isEmpty) return true;
      return album.title.toLowerCase().contains(queryLower) ||
          album.subtitle.toLowerCase().contains(queryLower);
    }).toList(growable: false);
  }

  List<_ArtistGroup> _buildFilteredArtists(
      _LibraryIndex index, String queryLower) {
    return index.artists.where((artist) {
      if (_onlyWithCover && artist.artUri == null) return false;
      if (queryLower.isEmpty) return true;
      return artist.title.toLowerCase().contains(queryLower);
    }).toList(growable: false);
  }

  Widget _buildLibraryContentSliver(
    _AppController controller,
    _LibraryIndex index,
    String queryLower,
  ) {
    switch (_view) {
      case _LibraryView.tracks:
        final tracks = _buildFilteredTracks(index, queryLower);
        return _TracksSliver(
          controller: controller,
          tracks: tracks,
          bytesFmt: _fmtBytes,
        );
      case _LibraryView.albums:
        final albums = _buildFilteredAlbums(index, queryLower);
        return _AlbumsSliver(controller: controller, albums: albums);
      case _LibraryView.artists:
        final artists = _buildFilteredArtists(index, queryLower);
        return _ArtistsSliver(controller: controller, artists: artists);
      case _LibraryView.queue:
        return _QueueSliver(controller: controller);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final cs = Theme.of(context).colorScheme;

    return CustomScrollView(
      slivers: [
        SliverAppBar.large(
          title: const Text('本地音乐'),
          actions: [
            IconButton(
              tooltip: '刷新',
              onPressed: controller.refreshOutputs,
              icon: const Icon(Icons.refresh_rounded),
            ),
            const SizedBox(width: 8),
          ],
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SearchAnchor.bar(
              searchController: _searchController,
              barHintText: '搜索音乐库',
              barLeading: const Icon(Icons.search_rounded),
              barTrailing: <Widget>[
                IconButton.filledTonal(
                  tooltip: '排序/筛选',
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    _openOptionsSheet();
                  },
                  icon: const Icon(Icons.tune_rounded),
                ),
              ],
              suggestionsBuilder: (context, searchController) {
                final q = _pendingQuery.toLowerCase();
                final files = controller.furryOutputs.value;
                if (files.isEmpty) {
                  return <Widget>[
                    const ListTile(
                      leading: Icon(Icons.music_off_rounded),
                      title: Text('暂无可搜索内容'),
                    ),
                  ];
                }
                return <Widget>[
                  FutureBuilder<_LibraryIndex>(
                    future: _getIndexFuture(controller, files),
                    builder: (context, snap) {
                      final idx = snap.data;
                      if (idx == null) {
                        return const ListTile(
                          leading: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          title: Text('正在加载…'),
                        );
                      }

                      final tracks = idx.tracks;
                      final sourceHash = _lastFilesHash ?? 0;
                      final suggestions =
                          _buildSuggestions(tracks, q, sourceHash);
                      return _buildSuggestionContent(
                        searchController,
                        q,
                        suggestions,
                      );
                    },
                  ),
                ];
              },
              onChanged: _scheduleQueryUpdate,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _LibraryModulesCard(
              value: _view,
              onChanged: (v) {
                HapticFeedback.selectionClick();
                setState(() => _view = v);
              },
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          sliver: ValueListenableBuilder<List<File>>(
            valueListenable: controller.furryOutputs,
            builder: (context, files, _) {
              if (files.isEmpty) {
                return SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '还没有音乐库内容',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '当前没有检测到 .furry 输出文件。先去“转换”页打包，或直接选择一个音频文件开始播放。',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      Card(
                        margin: EdgeInsets.zero,
                        color: cs.surfaceContainer,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(28),
                        ),
                        child: Column(
                          children: [
                            ListTile(
                              leading: Icon(Icons.swap_horiz_rounded,
                                  color: cs.primary),
                              title: const Text('去转换'),
                              subtitle: const Text('把音频打包成 .furry 并写入封面/标签'),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () {
                                HapticFeedback.selectionClick();
                                controller.requestTabIndex(1);
                              },
                            ),
                            const Divider(height: 1),
                            ListTile(
                              leading: Icon(Icons.audio_file_rounded,
                                  color: cs.primary),
                              title: const Text('选择音频播放'),
                              subtitle: const Text('无需 .furry，也可以先体验播放器'),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () async {
                                HapticFeedback.selectionClick();
                                final f = await controller.pickForPlay();
                                if (f == null) return;
                                await controller.playFile(
                                  file: f,
                                  displayName: p.basename(f.path),
                                );
                              },
                            ),
                            const Divider(height: 1),
                            ListTile(
                              leading: Icon(Icons.refresh_rounded,
                                  color: cs.primary),
                              title: const Text('重新扫描'),
                              subtitle: const Text('更新“最近输出”列表'),
                              onTap: () async {
                                HapticFeedback.selectionClick();
                                await controller.refreshOutputs();
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }

              return FutureBuilder<_LibraryIndex>(
                future: _getIndexFuture(controller, files),
                builder: (context, snap) {
                  final idx = snap.data;
                  if (idx == null) {
                    return const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Center(
                          child: CircularProgressIndicator(),
                        ),
                      ),
                    );
                  }

                  final q = _query.trim().toLowerCase();
                  return _buildLibraryContentSliver(controller, idx, q);
                },
              );
            },
          ),
        ),
        SliverToBoxAdapter(child: _BottomOverlaySpacer(controller: controller)),
      ],
    );
  }
}

String _fmtBytes(int bytes) {
  const kb = 1024;
  const mb = 1024 * 1024;
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(1)} KB';
  return '$bytes B';
}

PageRoute<T> _expressivePageRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      final offset = Tween<Offset>(
        begin: const Offset(0.06, 0),
        end: Offset.zero,
      ).animate(curved);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(position: offset, child: child),
      );
    },
  );
}

String _albumHeroTag(_AlbumGroup album) {
  return 'album_${album.artist.toLowerCase()}|${album.album.toLowerCase()}';
}

String _nowPlayingHeroTag(String sourcePath) {
  // Keep it stable and reasonably short; Hero tags can be any object, but we
  // prefer a string for easier debugging.
  return 'np_${sourcePath.hashCode}';
}

class _LibraryModulesCard extends StatelessWidget {
  const _LibraryModulesCard({
    required this.value,
    required this.onChanged,
  });

  final _LibraryView value;
  final ValueChanged<_LibraryView> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    const modules = <({
      _LibraryView view,
      IconData icon,
      String title,
      String subtitle,
    })>[
      (
        view: _LibraryView.tracks,
        icon: Icons.music_note_rounded,
        title: '歌曲',
        subtitle: '按单曲浏览与播放',
      ),
      (
        view: _LibraryView.albums,
        icon: Icons.album_rounded,
        title: '专辑',
        subtitle: '按专辑归类，沉浸式封面网格',
      ),
      (
        view: _LibraryView.artists,
        icon: Icons.person_rounded,
        title: '歌手',
        subtitle: '按歌手整理，快速定位作品',
      ),
      (
        view: _LibraryView.queue,
        icon: Icons.queue_music_rounded,
        title: '队列',
        subtitle: '管理接下来要播放的内容',
      ),
    ];

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: cs.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final item in modules) ...[
                _LibraryModuleChip(
                  selected: value == item.view,
                  icon: item.icon,
                  label: item.title,
                  semanticHint: item.subtitle,
                  onTap: () => onChanged(item.view),
                ),
                if (item != modules.last) const SizedBox(width: 8),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LibraryModuleChip extends StatelessWidget {
  const _LibraryModuleChip({
    required this.selected,
    required this.icon,
    required this.label,
    required this.semanticHint,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final String semanticHint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = selected
        ? cs.secondaryContainer
        : _withOpacityCompat(cs.surfaceContainerHighest, 0.8);
    final fg = selected ? cs.onSecondaryContainer : cs.onSurfaceVariant;

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      hint: semanticHint,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: fg),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: fg,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryOptionsSheet extends StatefulWidget {
  const _LibraryOptionsSheet({required this.value});

  final _LibraryOptions value;

  @override
  State<_LibraryOptionsSheet> createState() => _LibraryOptionsSheetState();
}

class _LibraryOptionsSheetState extends State<_LibraryOptionsSheet> {
  late _LibrarySort _sort;
  late bool _ascending;
  late bool _onlyWithCover;

  @override
  void initState() {
    super.initState();
    _sort = widget.value.sort;
    _ascending = widget.value.ascending;
    _onlyWithCover = widget.value.onlyWithCover;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '排序与筛选',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 12),
            Text('排序', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _SortChip(
                  label: '最近',
                  selected: _sort == _LibrarySort.recent,
                  onTap: () => setState(() => _sort = _LibrarySort.recent),
                ),
                _SortChip(
                  label: '标题',
                  selected: _sort == _LibrarySort.title,
                  onTap: () => setState(() => _sort = _LibrarySort.title),
                ),
                _SortChip(
                  label: '歌手',
                  selected: _sort == _LibrarySort.artist,
                  onTap: () => setState(() => _sort = _LibrarySort.artist),
                ),
                _SortChip(
                  label: '专辑',
                  selected: _sort == _LibrarySort.album,
                  onTap: () => setState(() => _sort = _LibrarySort.album),
                ),
                _SortChip(
                  label: '大小',
                  selected: _sort == _LibrarySort.size,
                  onTap: () => setState(() => _sort = _LibrarySort.size),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              value: _ascending,
              onChanged: (v) => setState(() => _ascending = v),
              contentPadding: EdgeInsets.zero,
              title: const Text('升序'),
              subtitle: const Text('关闭时为降序/最近优先'),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              value: _onlyWithCover,
              onChanged: (v) => setState(() => _onlyWithCover = v),
              contentPadding: EdgeInsets.zero,
              title: const Text('仅显示有封面'),
              subtitle: const Text('用于快速筛选更完整的条目'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop(
                        _LibraryOptions(
                          sort: _sort,
                          ascending: _ascending,
                          onlyWithCover: _onlyWithCover,
                        ),
                      );
                    },
                    child: const Text('应用'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SortChip extends StatelessWidget {
  const _SortChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      selected: selected,
      label: Text(label),
      onSelected: (_) => onTap(),
      showCheckmark: false,
      selectedColor: Theme.of(context).colorScheme.secondaryContainer,
    );
  }
}

typedef _BytesFmt = String Function(int bytes);

class _TracksSliver extends StatelessWidget {
  const _TracksSliver({
    required this.controller,
    required this.tracks,
    required this.bytesFmt,
  });

  final _AppController controller;
  final List<_TrackEntry> tracks;
  final _BytesFmt bytesFmt;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final nowPlayingPath = controller.nowPlaying.value?.sourcePath;
    if (tracks.isEmpty) {
      return SliverToBoxAdapter(
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.filter_alt_off_rounded, color: cs.primary),
                const SizedBox(width: 12),
                const Expanded(child: Text('没有匹配结果')),
              ],
            ),
          ),
        ),
      );
    }

    final queueFiles = tracks.map((t) => t.file).toList(growable: false);

    return SliverList.separated(
      itemCount: tracks.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final t = tracks[i];
        final isCurrent = nowPlayingPath != null && nowPlayingPath == t.path;
        final meta = t.meta;
        final subtitleParts = <String>[
          if (meta.artist.isNotEmpty) meta.artist,
          if (meta.album.isNotEmpty) meta.album,
        ];
        final subtitle = subtitleParts.isNotEmpty
            ? subtitleParts.join(' · ')
            : (meta.subtitle.isNotEmpty
                ? meta.subtitle
                : '${bytesFmt(t.bytes)} · ${t.modified.toLocal()}');

        return Card(
          margin: EdgeInsets.zero,
          color: isCurrent
              ? _withOpacityCompat(cs.secondaryContainer, 0.55)
              : null,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: Stack(
              clipBehavior: Clip.none,
              children: [
                _CoverThumb(artUri: t.meta.artUri),
                if (isCurrent)
                  Positioned(
                    right: -6,
                    bottom: -6,
                    child: AnimatedScale(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutBack,
                      scale: 1,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: cs.primary,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: _withOpacityCompat(cs.surface, 0.85),
                          ),
                        ),
                        child: Icon(
                          Icons.equalizer_rounded,
                          size: 14,
                          color: cs.onPrimary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            title: Text(
              t.displayTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '加入队列',
                  onPressed: () async {
                    HapticFeedback.selectionClick();
                    await controller.enqueueFile(t.file, playNext: false);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已加入队列')),
                      );
                    }
                  },
                  icon: const Icon(Icons.queue_music_rounded),
                ),
                _TrackOverflowMenu(
                  controller: controller,
                  track: t,
                  queueFiles: queueFiles,
                  indexInQueue: i,
                ),
              ],
            ),
            onTap: () => controller.playFromQueue(
              queue: queueFiles,
              index: i,
              displayName: p.basename(t.file.path),
            ),
          ),
        );
      },
    );
  }
}

class _TrackOverflowMenu extends StatelessWidget {
  const _TrackOverflowMenu({
    required this.controller,
    required this.track,
    required this.queueFiles,
    required this.indexInQueue,
  });

  final _AppController controller;
  final _TrackEntry track;
  final List<File> queueFiles;
  final int indexInQueue;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '更多',
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'play',
          child: ListTile(
            leading: Icon(Icons.play_arrow_rounded),
            title: Text('播放'),
          ),
        ),
        const PopupMenuItem(
          value: 'play_next',
          child: ListTile(
            leading: Icon(Icons.playlist_play_rounded),
            title: Text('下一首播放（加入队列）'),
          ),
        ),
        const PopupMenuItem(
          value: 'add_queue',
          child: ListTile(
            leading: Icon(Icons.queue_music_rounded),
            title: Text('加入队列'),
          ),
        ),
        const PopupMenuItem(
          value: 'copy_path',
          child: ListTile(
            leading: Icon(Icons.copy_rounded),
            title: Text('复制路径'),
          ),
        ),
      ],
      onSelected: (v) async {
        switch (v) {
          case 'play':
            HapticFeedback.selectionClick();
            await controller.playFromQueue(
              queue: queueFiles,
              index: indexInQueue,
              displayName: p.basename(track.file.path),
            );
            break;
          case 'play_next':
            HapticFeedback.selectionClick();
            await controller.enqueueFile(track.file, playNext: true);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已加入“下一首播放”')),
              );
            }
            break;
          case 'add_queue':
            HapticFeedback.selectionClick();
            await controller.enqueueFile(track.file, playNext: false);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已加入队列')),
              );
            }
            break;
          case 'copy_path':
            HapticFeedback.selectionClick();
            await Clipboard.setData(ClipboardData(text: track.file.path));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制路径')),
              );
            }
            break;
        }
      },
      icon: const Icon(Icons.more_vert_rounded),
    );
  }
}

class _AlbumsSliver extends StatelessWidget {
  const _AlbumsSliver({required this.controller, required this.albums});

  final _AppController controller;
  final List<_AlbumGroup> albums;

  @override
  Widget build(BuildContext context) {
    if (albums.isEmpty) {
      return const SliverToBoxAdapter(
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text('没有匹配的专辑'),
          ),
        ),
      );
    }

    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.crossAxisExtent;
        final crossAxisCount = w >= 980
            ? 5
            : w >= 760
                ? 4
                : w >= 520
                    ? 3
                    : 2;
        return SliverGrid(
          delegate: SliverChildBuilderDelegate(
            childCount: albums.length,
            (context, i) {
              final a = albums[i];
              return _AlbumTile(
                album: a,
                onTap: () {
                  Navigator.of(context).push(
                    _expressivePageRoute(
                      _AlbumDetailPage(controller: controller, album: a),
                    ),
                  );
                },
              );
            },
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.85,
          ),
        );
      },
    );
  }
}

class _AlbumTile extends StatelessWidget {
  const _AlbumTile({required this.album, required this.onTap});

  final _AlbumGroup album;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final heroTag = _albumHeroTag(album);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Hero(
                        tag: heroTag,
                        child: Container(
                          color: cs.surfaceContainerHigh,
                          child: album.artUri == null
                              ? Center(
                                  child: Icon(
                                    Icons.album_rounded,
                                    color: cs.primary,
                                    size: 44,
                                  ),
                                )
                              : Image.file(
                                  File.fromUri(album.artUri!),
                                  fit: BoxFit.cover,
                                  cacheWidth: 512,
                                  cacheHeight: 512,
                                  gaplessPlayback: true,
                                ),
                        ),
                      ),
                      Positioned(
                        right: 10,
                        top: 10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: _withOpacityCompat(
                                cs.surfaceContainerHighest, 0.9),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color:
                                  _withOpacityCompat(cs.outlineVariant, 0.55),
                            ),
                          ),
                          child: Text(
                            '${album.tracks.length} 首',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: cs.onSurface,
                                ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                album.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 2),
              Text(
                album.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArtistsSliver extends StatelessWidget {
  const _ArtistsSliver({required this.controller, required this.artists});

  final _AppController controller;
  final List<_ArtistGroup> artists;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (artists.isEmpty) {
      return const SliverToBoxAdapter(
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text('没有匹配的歌手'),
          ),
        ),
      );
    }

    return SliverList.separated(
      itemCount: artists.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final a = artists[i];
        final albums = a.albumsByKey.values.length;
        final initial = a.title.isEmpty ? '?' : a.title.characters.first;
        return Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: a.artUri == null
                ? CircleAvatar(
                    backgroundColor: cs.secondaryContainer,
                    foregroundColor: cs.onSecondaryContainer,
                    child: Text(
                      initial,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Image.file(
                        File.fromUri(a.artUri!),
                        fit: BoxFit.cover,
                        cacheWidth: 96,
                        cacheHeight: 96,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
            title: Text(
              a.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '$albums 张专辑 · ${a.tracks.length} 首',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              Navigator.of(context).push(
                _expressivePageRoute(
                  _ArtistDetailPage(controller: controller, artist: a),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _QueueSliver extends StatelessWidget {
  const _QueueSliver({required this.controller});

  final _AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<_QueueState>(
      valueListenable: controller.queueState,
      builder: (context, qs, _) {
        if (!qs.hasQueue) {
          return SliverToBoxAdapter(
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(Icons.queue_music_rounded,
                        color: cs.primary, size: 28),
                    const SizedBox(width: 12),
                    const Expanded(
                        child: Text('队列为空：从“歌曲/专辑/歌手”里添加或直接播放即可生成队列')),
                  ],
                ),
              ),
            ),
          );
        }

        return SliverToBoxAdapter(
          child: Column(
            children: [
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Row(
                    children: [
                      Icon(Icons.queue_music_rounded, color: cs.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '播放队列 · ${qs.queue.length} 首',
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w800,
                                  ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () =>
                            controller.clearQueue(keepPlaying: true),
                        icon: const Icon(Icons.clear_all_rounded),
                        label: const Text('清空'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: qs.queue.length,
                onReorder: (oldIndex, newIndex) {
                  var target = newIndex;
                  if (target > oldIndex) target -= 1;
                  controller.moveQueueItem(oldIndex, target);
                },
                itemBuilder: (context, i) {
                  final f = qs.queue[i];
                  final key = ValueKey<String>('q_${f.path}');
                  return _QueueRow(
                    key: key,
                    controller: controller,
                    file: f,
                    index: i,
                    isCurrent: i == qs.index,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    super.key,
    required this.controller,
    required this.file,
    required this.index,
    required this.isCurrent,
  });

  final _AppController controller;
  final File file;
  final int index;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = p.basename(file.path);
    final ext = p.extension(base).toLowerCase();
    final isFurry = ext == '.furry';

    return Card(
      key: key,
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: isFurry
            ? FutureBuilder<_MetaPreview>(
                future: controller.getMetaPreviewForFurry(file),
                builder: (context, snap) {
                  final meta = snap.data;
                  final art = meta?.artUri;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      _CoverThumb(artUri: art),
                      if (isCurrent)
                        Positioned(
                          right: -6,
                          bottom: -6,
                          child: AnimatedScale(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutBack,
                            scale: isCurrent ? 1 : 0.8,
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 180),
                              opacity: isCurrent ? 1 : 0,
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: cs.primary,
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: _withOpacityCompat(cs.surface, 0.85),
                                  ),
                                ),
                                child: Icon(
                                  Icons.equalizer_rounded,
                                  size: 14,
                                  color: cs.onPrimary,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              )
            : Stack(
                clipBehavior: Clip.none,
                children: [
                  CircleAvatar(
                    backgroundColor: cs.surfaceContainerHigh,
                    foregroundColor: cs.onSurfaceVariant,
                    child: Text('${index + 1}'),
                  ),
                  if (isCurrent)
                    Positioned(
                      right: -6,
                      bottom: -6,
                      child: AnimatedScale(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutBack,
                        scale: isCurrent ? 1 : 0.8,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 180),
                          opacity: isCurrent ? 1 : 0,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: cs.primary,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: _withOpacityCompat(cs.surface, 0.85),
                              ),
                            ),
                            child: Icon(
                              Icons.equalizer_rounded,
                              size: 14,
                              color: cs.onPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
        title: isFurry
            ? FutureBuilder<_MetaPreview>(
                future: controller.getMetaPreviewForFurry(file),
                builder: (context, snap) {
                  final meta = snap.data;
                  return Text(
                    meta?.title ?? base,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  );
                },
              )
            : Text(base, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: isFurry
            ? FutureBuilder<_MetaPreview>(
                future: controller.getMetaPreviewForFurry(file),
                builder: (context, snap) {
                  final meta = snap.data;
                  final subtitleParts = <String>[
                    if ((meta?.artist ?? '').isNotEmpty) meta!.artist,
                    if ((meta?.album ?? '').isNotEmpty) meta!.album,
                  ];
                  final subtitle = subtitleParts.isNotEmpty
                      ? subtitleParts.join(' · ')
                      : (meta?.subtitle ?? '');
                  return Text(
                    subtitle.isEmpty ? '本地文件' : subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  );
                },
              )
            : const Text('本地文件'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '移除',
              onPressed: () => controller.removeFromQueueByPath(file.path),
              icon: const Icon(Icons.close_rounded),
            ),
            ReorderableDragStartListener(
              index: index,
              child: const Icon(Icons.drag_handle_rounded),
            ),
          ],
        ),
        onTap: () => controller.playAtQueueIndex(index),
      ),
    );
  }
}

class _AlbumDetailPage extends StatelessWidget {
  const _AlbumDetailPage({required this.controller, required this.album});

  final _AppController controller;
  final _AlbumGroup album;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tracks = album.tracks;
    final heroTag = _albumHeroTag(album);
    final w = MediaQuery.of(context).size.width;
    final coverSize = (w - 48).clamp(200.0, 320.0);
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: Text(album.title),
            actions: [
              FilledButton.tonalIcon(
                onPressed: tracks.isEmpty
                    ? null
                    : () => controller.playFromQueue(
                          queue:
                              tracks.map((t) => t.file).toList(growable: false),
                          index: 0,
                          displayName: p.basename(tracks.first.file.path),
                        ),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('播放全部'),
              ),
              const SizedBox(width: 8),
            ],
          ),
          SliverToBoxAdapter(
            child: TweenAnimationBuilder<double>(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              tween: Tween<double>(begin: 0, end: 1),
              builder: (context, t, child) {
                return Opacity(
                  opacity: t,
                  child: Transform.translate(
                    offset: Offset(0, lerpDouble(12, 0, t)!),
                    child: child,
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: SizedBox(
                          width: coverSize,
                          height: coverSize,
                          child: Hero(
                            tag: heroTag,
                            child: album.artUri == null
                                ? ColoredBox(
                                    color: cs.surfaceContainerHigh,
                                    child: Icon(
                                      Icons.album_rounded,
                                      size: coverSize * 0.28,
                                      color: cs.primary,
                                    ),
                                  )
                                : Image.file(
                                    File.fromUri(album.artUri!),
                                    fit: BoxFit.cover,
                                    cacheWidth: 1024,
                                    cacheHeight: 1024,
                                    gaplessPlayback: true,
                                  ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      album.subtitle,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${tracks.length} 首',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: _TracksSliver(
              controller: controller,
              tracks: tracks,
              bytesFmt: _fmtBytes,
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtistDetailPage extends StatelessWidget {
  const _ArtistDetailPage({required this.controller, required this.artist});

  final _AppController controller;
  final _ArtistGroup artist;

  @override
  Widget build(BuildContext context) {
    final albums = artist.albumsByKey.values.toList(growable: false)
      ..sort((a, b) => a.title.compareTo(b.title));
    final tracks = artist.tracks.toList(growable: false)
      ..sort((a, b) => a.displayTitle.compareTo(b.displayTitle));
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: Text(artist.title),
            actions: [
              FilledButton.tonalIcon(
                onPressed: tracks.isEmpty
                    ? null
                    : () => controller.playFromQueue(
                          queue:
                              tracks.map((t) => t.file).toList(growable: false),
                          index: 0,
                          displayName: p.basename(tracks.first.file.path),
                        ),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('播放全部'),
              ),
              const SizedBox(width: 8),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Icon(Icons.album_rounded, color: cs.primary),
                  const SizedBox(width: 8),
                  Text('专辑', style: Theme.of(context).textTheme.titleLarge),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: _AlbumsSliver(controller: controller, albums: albums),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Icon(Icons.music_note_rounded, color: cs.primary),
                  const SizedBox(width: 8),
                  Text('歌曲', style: Theme.of(context).textTheme.titleLarge),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: _TracksSliver(
              controller: controller,
              tracks: tracks,
              bytesFmt: _fmtBytes,
            ),
          ),
        ],
      ),
    );
  }
}

class _CoverThumb extends StatelessWidget {
  final Uri? artUri;
  const _CoverThumb({required this.artUri});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final uri = artUri;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 48,
        height: 48,
        color: cs.surfaceContainerHigh,
        child: uri == null
            ? Icon(Icons.music_note, color: cs.primary)
            : Image.file(
                File.fromUri(uri),
                fit: BoxFit.cover,
                // Hint decoder to avoid full-res bitmap allocations on Android.
                cacheWidth: 96,
                cacheHeight: 96,
              ),
      ),
    );
  }
}

class ConverterPage extends StatefulWidget {
  final _AppController controller;
  const ConverterPage({super.key, required this.controller});

  @override
  State<ConverterPage> createState() => _ConverterPageState();
}

class _ConverterPageState extends State<ConverterPage> {
  late final ValueNotifier<double> _paddingDraftKb;

  @override
  void initState() {
    super.initState();
    _paddingDraftKb =
        ValueNotifier<double>(widget.controller.paddingKb.toDouble());
  }

  @override
  void didUpdateWidget(covariant ConverterPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _paddingDraftKb.value = widget.controller.paddingKb.toDouble();
    }
  }

  @override
  void dispose() {
    _paddingDraftKb.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final cs = Theme.of(context).colorScheme;

    return CustomScrollView(
      slivers: [
        SliverAppBar.large(
          title: const Text('转换'),
          actions: const [SizedBox(width: 8)],
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          sliver: SliverToBoxAdapter(
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.lock_rounded, color: cs.primary),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text('打包（音频 → .furry）'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '把音频封装成 .furry（含封面与标签），用于快速导入与统一管理。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () async {
                            await controller.pickForPack();
                            setState(() {});
                          },
                          icon: const Icon(Icons.audio_file_rounded),
                          label: const Text('选择音频'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: controller.pickedForPack == null
                              ? null
                              : controller.startPack,
                          icon: const Icon(Icons.auto_fix_high_rounded),
                          label: const Text('打包'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainer,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.insert_drive_file_rounded,
                              color: cs.onSurfaceVariant),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              controller.pickedForPackName == null
                                  ? '未选择输入文件'
                                  : '输入：${controller.pickedForPackName}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        const Text('Padding (KB)'),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ValueListenableBuilder<double>(
                            valueListenable: _paddingDraftKb,
                            builder: (context, draft, _) {
                              final clamped =
                                  draft.clamp(0.0, 1024.0).toDouble();
                              final rounded = clamped.round();
                              return Slider(
                                value: clamped,
                                min: 0,
                                max: 1024,
                                divisions: null,
                                label: '$rounded KB',
                                onChanged: (v) {
                                  _paddingDraftKb.value = v;
                                  controller.paddingKb = v.round();
                                },
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                    ValueListenableBuilder<double>(
                      valueListenable: _paddingDraftKb,
                      builder: (context, draft, _) => Text(
                        '当前 padding: ${draft.clamp(0.0, 1024.0).round()} KB',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          sliver: SliverToBoxAdapter(
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.play_circle_rounded, color: cs.primary),
                        const SizedBox(width: 10),
                        const Expanded(child: Text('临时播放')),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '从文件选择器中选一个音频或 .furry 立即播放。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: () async {
                            final f = await controller.pickForPlay();
                            if (f == null) return;
                            await controller.playFile(file: f);
                          },
                          icon: const Icon(Icons.folder_open_rounded),
                          label: const Text('选择并播放'),
                        ),
                        OutlinedButton.icon(
                          onPressed: controller.stop,
                          icon: const Icon(Icons.stop_rounded),
                          label: const Text('停止'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(child: _BottomOverlaySpacer(controller: controller)),
      ],
    );
  }
}

class SettingsPage extends StatelessWidget {
  final _AppController controller;
  const SettingsPage({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return CustomScrollView(
      slivers: [
        const SliverAppBar.large(title: Text('设置')),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          sliver: SliverToBoxAdapter(
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.bug_report_rounded, color: cs.primary),
                        const SizedBox(width: 10),
                        const Expanded(child: Text('诊断日志')),
                        IconButton(
                          tooltip: '复制',
                          onPressed: () async {
                            final text = controller.log.value;
                            if (text.trim().isEmpty) return;
                            await Clipboard.setData(ClipboardData(text: text));
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已复制诊断日志')),
                              );
                            }
                          },
                          icon: const Icon(Icons.copy_rounded),
                        ),
                        IconButton(
                          tooltip: '清空',
                          onPressed: () async {
                            await controller.clearLog();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已清空诊断日志')),
                              );
                            }
                          },
                          icon: const Icon(Icons.delete_outline_rounded),
                        ),
                        IconButton(
                          tooltip: '导出',
                          onPressed: () async {
                            final path = await controller.exportLog();
                            if (!context.mounted) return;
                            if (path == null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('导出失败')),
                              );
                              return;
                            }
                            await Clipboard.setData(ClipboardData(text: path));
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('已导出（路径已复制到剪贴板）'),
                                ),
                              );
                            }
                          },
                          icon: const Icon(Icons.file_upload_outlined),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '用于排查闪退/卡顿等问题（持久化保存，重启不会丢）。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainer,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: ValueListenableBuilder<String>(
                        valueListenable: controller.log,
                        builder: (context, log, _) {
                          return SelectableText(
                            log.isEmpty ? '(empty)' : log,
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      fontFamily: 'monospace',
                                      color: cs.onSurfaceVariant,
                                    ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(child: _BottomOverlaySpacer(controller: controller)),
      ],
    );
  }
}

// Kept temporarily for reference while iterating on the player UI.
// ignore: unused_element
class _NowPlayingPanelDeprecated extends StatefulWidget {
  final _AppController controller;
  final double bottomOverlayBaseline;

  // Tuned by eye: close to M3 bottom sheet mini player height.
  // ignore: unused_field
  static const double miniHeightPx = 76;

  const _NowPlayingPanelDeprecated({
    required this.controller,
    required this.bottomOverlayBaseline,
  });

  @override
  State<_NowPlayingPanelDeprecated> createState() =>
      _NowPlayingPanelDeprecatedState();
}

class _NowPlayingPanelDeprecatedState
    extends State<_NowPlayingPanelDeprecated> {
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  double _extent = 0;
  double? _dragStartExtent;

  void _expand(double maxSize) {
    _sheetController.animateTo(
      maxSize,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _collapse(double minSize) {
    _sheetController.animateTo(
      minSize,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _sheetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<_NowPlaying?>(
      valueListenable: widget.controller.nowPlaying,
      builder: (context, np, _) {
        if (np == null) return const SizedBox.shrink();

        return LayoutBuilder(
          builder: (context, constraints) {
            final availableH = constraints.biggest.height;
            final minSize = (availableH <= 0)
                ? 0.18
                : (NowPlayingPanel.miniHeightPx / availableH).clamp(0.10, 0.24);
            const maxSize = 0.98;
            final effectiveExtent = _extent == 0 ? minSize : _extent;
            final tRaw = ((effectiveExtent - minSize) / (maxSize - minSize))
                .clamp(0.0, 1.0);
            final reveal = Curves.easeOutCubic.transform(tRaw);
            final miniOpacity =
                (1.0 - Curves.easeOutCubic.transform(tRaw)).clamp(0.0, 1.0);
            final fullOpacity =
                Curves.easeInOutCubicEmphasized.transform(reveal);
            // When collapsed, keep the mini player above the bottom navigation bar.
            // When expanded, allow it to cover the whole screen (including nav).
            final bottomPad = (lerpDouble(
                      widget.bottomOverlayBaseline,
                      0,
                      reveal,
                    ) ??
                    widget.bottomOverlayBaseline)
                .clamp(0.0, widget.bottomOverlayBaseline);
            final sheetPixels = _sheetController.isAttached
                ? _sheetController.pixels
                : (effectiveExtent * availableH);
            final maxHeaderHeight = (sheetPixels - 12).clamp(0.0, sheetPixels);

            void onHeaderDragStart(DragStartDetails details) {
              _dragStartExtent = _sheetController.isAttached
                  ? _sheetController.size
                  : effectiveExtent;
            }

            void onHeaderDragUpdate(DragUpdateDetails details) {
              final h = availableH <= 1 ? 1.0 : availableH;
              final start = _dragStartExtent ??
                  (_sheetController.isAttached
                      ? _sheetController.size
                      : effectiveExtent);
              final next = (start + (-details.delta.dy / h)).clamp(
                minSize,
                maxSize,
              );
              _sheetController.jumpTo(next);
              _dragStartExtent = next;
              if (mounted) setState(() => _extent = next);
            }

            void onHeaderDragEnd(DragEndDetails details) {
              _dragStartExtent = null;
              final v = details.primaryVelocity ?? 0.0;
              final current = _sheetController.isAttached
                  ? _sheetController.size
                  : effectiveExtent;
              final threshold = minSize + (maxSize - minSize) * 0.33;
              final snapTo = (v.abs() > 600)
                  ? (v < 0 ? maxSize : minSize)
                  : ((current >= threshold) ? maxSize : minSize);
              _sheetController.animateTo(
                snapTo,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
              );
            }

            return NotificationListener<DraggableScrollableNotification>(
              onNotification: (n) {
                if (mounted) {
                  setState(() => _extent = n.extent);
                }
                return false;
              },
              child: DraggableScrollableSheet(
                controller: _sheetController,
                initialChildSize: minSize,
                minChildSize: minSize,
                maxChildSize: maxSize,
                snap: true,
                snapSizes: <double>[minSize, maxSize],
                expand: false,
                builder: (context, scrollController) {
                  final topInset = MediaQuery.of(context).padding.top;
                  final topPad = lerpDouble(0, topInset, reveal) ?? 0.0;
                  return Material(
                    color: Colors.transparent,
                    child: _NowPlayingBackdrop(
                      reveal: reveal,
                      cs: cs,
                      child: Padding(
                        padding:
                            EdgeInsets.only(top: topPad, bottom: bottomPad),
                        child: Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                              child: GestureDetector(
                                // Keep the drag gesture out of the ListView to avoid
                                // gesture arena conflicts (slow drags would be won by
                                // the Scrollable and "bounce back").
                                behavior: HitTestBehavior.translucent,
                                onVerticalDragStart: onHeaderDragStart,
                                onVerticalDragUpdate: onHeaderDragUpdate,
                                onVerticalDragEnd: onHeaderDragEnd,
                                child: _NowPlayingMorphHeader(
                                  controller: widget.controller,
                                  np: np,
                                  reveal: reveal,
                                  miniOpacity: miniOpacity,
                                  fullOpacity: fullOpacity,
                                  maxHeight: maxHeaderHeight,
                                  onExpand: () => _expand(maxSize),
                                  onCollapse: () => _collapse(minSize),
                                ),
                              ),
                            ),
                            Expanded(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onVerticalDragStart: onHeaderDragStart,
                                onVerticalDragUpdate: onHeaderDragUpdate,
                                onVerticalDragEnd: onHeaderDragEnd,
                                child: ListView(
                                  controller: scrollController,
                                  physics: const NeverScrollableScrollPhysics(),
                                  padding:
                                      const EdgeInsets.fromLTRB(12, 6, 12, 24),
                                  children: [
                                    IgnorePointer(
                                      ignoring: reveal < 0.35,
                                      child: Opacity(
                                        opacity: fullOpacity,
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const SizedBox(height: 14),
                                            _NowPlayingSeekBar(
                                                controller: widget.controller),
                                            const SizedBox(height: 16),
                                            _NowPlayingControls(
                                                controller: widget.controller),
                                            const SizedBox(height: 16),
                                            Container(
                                              padding: const EdgeInsets.all(12),
                                              decoration: BoxDecoration(
                                                color: cs.surfaceContainerHigh,
                                                borderRadius:
                                                    BorderRadius.circular(18),
                                              ),
                                              child: Row(
                                                children: [
                                                  Icon(
                                                      Icons
                                                          .info_outline_rounded,
                                                      color:
                                                          cs.onSurfaceVariant),
                                                  const SizedBox(width: 10),
                                                  Expanded(
                                                    child: Text(
                                                      np.sourcePath,
                                                      maxLines: 2,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .bodySmall
                                                          ?.copyWith(
                                                            color: cs
                                                                .onSurfaceVariant,
                                                          ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _NowPlayingBackdrop extends StatelessWidget {
  final double reveal;
  final ColorScheme cs;
  final Widget child;

  const _NowPlayingBackdrop({
    required this.reveal,
    required this.cs,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // Material 3 surfaces: prefer tonal, mostly-opaque surfaces with elevation.
    // Avoid blur/glass as the baseline "strict" M3 look for better contrast and
    // performance across devices.
    final t = Curves.easeOutCubic.transform(reveal.clamp(0.0, 1.0));
    final elevation = (lerpDouble(1.0, 8.0, t) ?? 4.0).clamp(0.0, 12.0);

    return Material(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      clipBehavior: Clip.antiAlias,
      elevation: elevation,
      color: cs.surfaceContainerHighest,
      surfaceTintColor: cs.surfaceTint,
      child: child,
    );
  }
}

class _NowPlayingMorphHeader extends StatelessWidget {
  final _AppController controller;
  final _NowPlaying np;
  final double reveal;
  final double miniOpacity;
  final double fullOpacity;
  final double maxHeight;
  final VoidCallback onExpand;
  final VoidCallback onCollapse;

  const _NowPlayingMorphHeader({
    required this.controller,
    required this.np,
    required this.reveal,
    required this.miniOpacity,
    required this.fullOpacity,
    required this.maxHeight,
    required this.onExpand,
    required this.onCollapse,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final coverMax = w.clamp(0.0, 420.0).toDouble();
        const coverMin = 44.0;
        const minRadius = 14.0;

        // Prevent the cover from growing while the mini controls are still
        // visible; otherwise it can overlap the mini bar buttons.
        final coverT = Curves.easeOutCubic.transform(
          ((reveal - 0.18) / 0.82).clamp(0.0, 1.0),
        );

        final coverSize = lerpDouble(coverMin, coverMax, coverT)!;
        // The sheet already applies a SafeArea-like top padding when expanded,
        // so keep the cover a bit closer to the top to avoid excessive vertical
        // push-down on devices with tall status bars/notches.
        final coverTop = lerpDouble(10, 34, coverT)!;
        final coverLeft = lerpDouble(12, (w - coverSize) / 2, coverT)!;
        // Match "最近输出" thumbnails: fixed corner radius.
        const radius = minRadius;

        final desiredHeaderH =
            lerpDouble(72, coverTop + coverSize + 92, reveal)!
                .clamp(72.0, 640.0)
                .toDouble();
        final headerH = desiredHeaderH.clamp(0.0, maxHeight).toDouble();

        return SizedBox(
          height: headerH,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    width: 46,
                    height: 5,
                    decoration: BoxDecoration(
                      color: _withOpacityCompat(cs.onSurfaceVariant, 0.35),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: IgnorePointer(
                    // Important: avoid an invisible mini bar blocking sheet dragging
                    // when expanded.
                    ignoring: reveal > 0.08,
                    child: Opacity(
                      opacity: miniOpacity,
                      child: Card(
                        margin: EdgeInsets.zero,
                        elevation: 0,
                        color: cs.surfaceContainerHigh,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(28),
                          side: BorderSide(
                            color: _withOpacityCompat(cs.outlineVariant, 0.55),
                          ),
                        ),
                        child: InkWell(
                          onTap: onExpand,
                          borderRadius: BorderRadius.circular(28),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                            child: Row(
                              children: [
                                const SizedBox(
                                    width: coverMin, height: coverMin),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        np.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        np.subtitle,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                                color: cs.onSurfaceVariant),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton.filledTonal(
                                  tooltip: '上一首',
                                  onPressed: controller.canPlayPreviousTrack
                                      ? controller.playPreviousTrack
                                      : null,
                                  icon: const Icon(Icons.skip_previous_rounded),
                                ),
                                StreamBuilder<PlayerState>(
                                  stream: controller.playerStateStream,
                                  builder: (context, snap) {
                                    final playing = snap.data?.playing ?? false;
                                    final processing =
                                        snap.data?.processingState ??
                                            ProcessingState.idle;
                                    final busy = processing ==
                                            ProcessingState.loading ||
                                        processing == ProcessingState.buffering;
                                    return IconButton.filledTonal(
                                      onPressed: busy
                                          ? null
                                          : () async {
                                              if (playing) {
                                                await controller.pause();
                                              } else {
                                                await controller.play();
                                              }
                                            },
                                      icon: busy
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2),
                                            )
                                          : Icon(playing
                                              ? Icons.pause_rounded
                                              : Icons.play_arrow_rounded),
                                    );
                                  },
                                ),
                                IconButton.filledTonal(
                                  tooltip: '下一首',
                                  onPressed: controller.canPlayNextTrack
                                      ? controller.playNextTrack
                                      : null,
                                  icon: const Icon(Icons.skip_next_rounded),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: coverLeft,
                top: coverTop,
                width: coverSize,
                height: coverSize,
                child: IgnorePointer(
                  child: Builder(
                    builder: (context) {
                      final isThumb = coverSize <= 60;
                      final image = np.artUri == null
                          ? Icon(Icons.album_rounded,
                              size: coverSize * 0.33, color: cs.primary)
                          : Image.file(
                              File.fromUri(np.artUri!),
                              fit: BoxFit.cover,
                              // Keep cache dimensions stable while dragging to avoid
                              // re-decoding on every frame (which can cause flicker).
                              cacheWidth: 1024,
                              cacheHeight: 1024,
                              gaplessPlayback: true,
                              filterQuality: FilterQuality.medium,
                            );

                      // Match the "最近输出" thumbnail feel: no border/shadow when small.
                      if (isThumb) {
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: ColoredBox(
                            color: cs.surfaceContainerHighest,
                            child: image,
                          ),
                        );
                      }

                      return DecoratedBox(
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(radius),
                          border: Border.all(
                            color: _withOpacityCompat(cs.outlineVariant, 0.5),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: _withOpacityCompat(
                                  cs.shadow, 0.18 * fullOpacity),
                              blurRadius: 24 * fullOpacity,
                              offset: Offset(0, 10 * fullOpacity),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(radius),
                          child: image,
                        ),
                      );
                    },
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: IgnorePointer(
                  ignoring: fullOpacity < 0.1,
                  child: Opacity(
                    opacity: fullOpacity,
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: '收起',
                          onPressed: onCollapse,
                          icon: const Icon(Icons.keyboard_arrow_down_rounded),
                        ),
                        const Spacer(),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: coverTop + coverSize + 18,
                child: IgnorePointer(
                  ignoring: fullOpacity < 0.1,
                  child: Opacity(
                    opacity: fullOpacity,
                    child: Transform.translate(
                      offset: Offset(0, 8 * (1 - fullOpacity)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(np.title,
                              style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 6),
                          Text(
                            np.subtitle,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class NowPlayingPanel extends StatefulWidget {
  final _AppController controller;
  final double bottomOverlayBaseline;

  // Tuned by eye: close to M3 mini player height.
  static const double miniHeightPx = 76;
  static const double miniGapPx = 8;

  const NowPlayingPanel({
    super.key,
    required this.controller,
    required this.bottomOverlayBaseline,
  });

  @override
  State<NowPlayingPanel> createState() => _NowPlayingPanelState();
}

class _NowPlayingPanelState extends State<NowPlayingPanel> {
  bool _sheetOpen = false;

  Future<void> _openSheet(_NowPlaying np) async {
    if (_sheetOpen) return;
    setState(() => _sheetOpen = true);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return _NowPlayingSheet(controller: widget.controller, np: np);
      },
    );
    if (mounted) setState(() => _sheetOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_NowPlaying?>(
      valueListenable: widget.controller.nowPlaying,
      builder: (context, np, _) {
        if (np == null) return const SizedBox.shrink();

        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              widget.bottomOverlayBaseline + NowPlayingPanel.miniGapPx,
            ),
            child: _NowPlayingMiniBar(
              controller: widget.controller,
              np: np,
              onOpen: () => _openSheet(np),
            ),
          ),
        );
      },
    );
  }
}

Future<void> _showNowPlayingActionsSheet({
  required BuildContext context,
  required _AppController controller,
  required _NowPlaying np,
}) async {
  final file = File(np.sourcePath);
  final qs = controller.queueState.value;
  final inQueue = qs.queue.any((f) => f.path == np.sourcePath);

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.queue_music_rounded),
                title: const Text('加入队列'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await controller.enqueueFile(file, playNext: false);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已加入队列')),
                    );
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.playlist_play_rounded),
                title: const Text('下一首播放'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await controller.enqueueFile(file, playNext: true);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已加入“下一首播放”')),
                    );
                  }
                },
              ),
              if (inQueue)
                ListTile(
                  leading: const Icon(Icons.playlist_remove_rounded),
                  title: const Text('从队列移除'),
                  onTap: () async {
                    Navigator.of(context).pop();
                    await controller.removeFromQueueByPath(np.sourcePath);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已从队列移除')),
                      );
                    }
                  },
                ),
              if (qs.hasQueue)
                ListTile(
                  leading: const Icon(Icons.clear_all_rounded),
                  title: const Text('清空队列（不停止播放）'),
                  onTap: () {
                    Navigator.of(context).pop();
                    controller.clearQueue(keepPlaying: true);
                  },
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('复制标题'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await Clipboard.setData(ClipboardData(text: np.title));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制标题')),
                    );
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('复制路径'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await Clipboard.setData(ClipboardData(text: np.sourcePath));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制路径')),
                    );
                  }
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _NowPlayingMiniBar extends StatelessWidget {
  const _NowPlayingMiniBar({
    required this.controller,
    required this.np,
    required this.onOpen,
  });

  final _AppController controller;
  final _NowPlaying np;
  final VoidCallback onOpen;

  static const double _compactControlSize = 40;
  static const double _compactPrimaryControlSize = 42;

  ButtonStyle _compactTonalStyle() {
    return IconButton.styleFrom(
      minimumSize: const Size.square(_compactControlSize),
      maximumSize: const Size.square(_compactControlSize),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final titleStyle = Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        );
    final subtitleStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: cs.onSurfaceVariant,
        );

    return LayoutBuilder(
      builder: (context, constraints) {
        final showPrevious = constraints.maxWidth >= 470;
        final showMore = constraints.maxWidth >= 560;
        final heroTag = _nowPlayingHeroTag(np.sourcePath);
        return Semantics(
          button: true,
          label: '正在播放：${np.title}',
          child: Material(
            elevation: 2,
            color: cs.surfaceContainerHigh,
            surfaceTintColor: cs.surfaceTint,
            shadowColor: _withOpacityCompat(cs.shadow, 0.22),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(
                color: _withOpacityCompat(cs.outlineVariant, 0.55),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              height: NowPlayingPanel.miniHeightPx,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: onOpen,
                        borderRadius: BorderRadius.circular(20),
                        child: Row(
                          children: [
                            Hero(
                              tag: heroTag,
                              child: _CoverThumb(artUri: np.artUri),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    np.title,
                                    style: titleStyle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    np.subtitle,
                                    style: subtitleStyle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 6),
                                  _MiniProgress(controller: controller),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (showPrevious) ...[
                      IconButton.filledTonal(
                        style: _compactTonalStyle(),
                        tooltip: '上一首',
                        onPressed: controller.canPlayPreviousTrack
                            ? () {
                                HapticFeedback.selectionClick();
                                controller.playPreviousTrack();
                              }
                            : null,
                        icon: const Icon(
                          Icons.skip_previous_rounded,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    _MiniPlayPause(
                      controller: controller,
                      compact: true,
                    ),
                    const SizedBox(width: 6),
                    IconButton.filledTonal(
                      style: _compactTonalStyle(),
                      tooltip: '下一首',
                      onPressed: controller.canPlayNextTrack
                          ? () {
                              HapticFeedback.selectionClick();
                              controller.playNextTrack();
                            }
                          : null,
                      icon: const Icon(Icons.skip_next_rounded, size: 22),
                    ),
                    const SizedBox(width: 6),
                    IconButton.filledTonal(
                      style: _compactTonalStyle(),
                      tooltip: '展开',
                      onPressed: () {
                        HapticFeedback.selectionClick();
                        onOpen();
                      },
                      icon:
                          const Icon(Icons.keyboard_arrow_up_rounded, size: 24),
                    ),
                    if (showMore) ...[
                      const SizedBox(width: 6),
                      IconButton.filledTonal(
                        style: _compactTonalStyle(),
                        tooltip: '更多',
                        onPressed: () {
                          HapticFeedback.selectionClick();
                          _showNowPlayingActionsSheet(
                            context: context,
                            controller: controller,
                            np: np,
                          );
                        },
                        icon: const Icon(Icons.more_horiz_rounded, size: 22),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MiniPlayPause extends StatelessWidget {
  const _MiniPlayPause({required this.controller, this.compact = false});
  final _AppController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final controlSize =
        compact ? _NowPlayingMiniBar._compactPrimaryControlSize : 48.0;
    final iconSize = compact ? 23.0 : 24.0;
    final indicatorSize = compact ? 16.0 : 18.0;
    return StreamBuilder<PlayerState>(
      stream: controller.playerStateStream,
      builder: (context, snap) {
        final playing = snap.data?.playing ?? false;
        final processing = snap.data?.processingState ?? ProcessingState.idle;
        final busy = processing == ProcessingState.loading ||
            processing == ProcessingState.buffering;
        return IconButton.filled(
          style: IconButton.styleFrom(
            minimumSize: Size.square(controlSize),
            maximumSize: Size.square(controlSize),
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
          tooltip: playing ? '暂停' : '播放',
          onPressed: busy
              ? null
              : () async {
                  HapticFeedback.selectionClick();
                  if (playing) {
                    await controller.pause();
                  } else {
                    await controller.play();
                  }
                },
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) =>
                ScaleTransition(scale: anim, child: child),
            child: busy
                ? SizedBox(
                    key: const ValueKey<String>('busy'),
                    width: indicatorSize,
                    height: indicatorSize,
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    key: ValueKey<bool>(playing),
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: iconSize,
                  ),
          ),
        );
      },
    );
  }
}

class _MiniProgress extends StatelessWidget {
  const _MiniProgress({required this.controller});
  final _AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return StreamBuilder<Duration?>(
      stream: controller.durationStream,
      builder: (context, durSnap) {
        final duration = durSnap.data ?? Duration.zero;
        final maxMs = duration.inMilliseconds <= 0
            ? 1.0
            : duration.inMilliseconds.toDouble();
        return StreamBuilder<Duration>(
          stream: controller.positionStream,
          builder: (context, posSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final posMs = pos.inMilliseconds.toDouble().clamp(0.0, maxMs);
            final progress = (posMs / maxMs).clamp(0.0, 1.0);
            return ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: TweenAnimationBuilder<double>(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                tween: Tween<double>(
                  begin: 0,
                  end: progress.isFinite ? progress : 0,
                ),
                builder: (context, v, _) {
                  return LinearProgressIndicator(
                    value: v,
                    minHeight: 3,
                    backgroundColor:
                        _withOpacityCompat(cs.onSurfaceVariant, 0.16),
                    valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _NowPlayingSheet extends StatelessWidget {
  const _NowPlayingSheet({required this.controller, required this.np});

  final _AppController controller;
  final _NowPlaying np;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final w = MediaQuery.of(context).size.width;
    final coverSize = (w - 48).clamp(220.0, 360.0);
    final heroTag = _nowPlayingHeroTag(np.sourcePath);

    Widget cover() {
      final uri = np.artUri;
      return TweenAnimationBuilder<double>(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        tween: Tween<double>(begin: 0.0, end: 1.0),
        builder: (context, t, child) {
          return Opacity(
            opacity: t,
            child: Transform.scale(
              scale: lerpDouble(0.96, 1.0, t)!,
              child: child,
            ),
          );
        },
        child: Hero(
          tag: heroTag,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Container(
              width: coverSize,
              height: coverSize,
              color: cs.surfaceContainerHigh,
              child: uri == null
                  ? Icon(
                      Icons.album_rounded,
                      size: coverSize * 0.28,
                      color: cs.primary,
                    )
                  : Image.file(
                      File.fromUri(uri),
                      fit: BoxFit.cover,
                      cacheWidth: 1024,
                      cacheHeight: 1024,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.medium,
                    ),
            ),
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '正在播放',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                  ),
                  IconButton(
                    tooltip: '更多',
                    onPressed: () => _showNowPlayingActionsSheet(
                      context: context,
                      controller: controller,
                      np: np,
                    ),
                    icon: const Icon(Icons.more_horiz_rounded),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Center(child: cover()),
              const SizedBox(height: 16),
              Text(np.title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 6),
              Text(
                np.subtitle,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 18),
              _NowPlayingSeekBar(controller: controller),
              const SizedBox(height: 16),
              _NowPlayingControls(controller: controller),
              const SizedBox(height: 18),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.insert_drive_file_rounded, color: cs.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('文件',
                                style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 6),
                            SelectableText(
                              np.sourcePath,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '复制路径',
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: np.sourcePath),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已复制路径')),
                            );
                          }
                        },
                        icon: const Icon(Icons.copy_rounded),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NowPlayingSeekBar extends StatefulWidget {
  final _AppController controller;
  const _NowPlayingSeekBar({required this.controller});

  @override
  State<_NowPlayingSeekBar> createState() => _NowPlayingSeekBarState();
}

class _NowPlayingSeekBarState extends State<_NowPlayingSeekBar> {
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return StreamBuilder<Duration?>(
      stream: controller.durationStream,
      builder: (context, durSnap) {
        final duration = durSnap.data ?? Duration.zero;
        final maxMs = duration.inMilliseconds <= 0
            ? 1.0
            : duration.inMilliseconds.toDouble();
        return StreamBuilder<Duration>(
          stream: controller.positionStream,
          builder: (context, posSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final posMs = pos.inMilliseconds.toDouble().clamp(0.0, maxMs);
            final value = _dragMs ?? posMs;
            return Column(
              children: [
                Semantics(
                  label: '播放进度',
                  value:
                      '${controller._fmt(Duration(milliseconds: posMs.round()))} / ${controller._fmt(duration)}',
                  child: Slider(
                    value: value.clamp(0.0, maxMs),
                    min: 0,
                    max: maxMs,
                    semanticFormatterCallback: (v) => controller._fmt(
                      Duration(
                        milliseconds: v.round().clamp(0, maxMs.toInt()),
                      ),
                    ),
                    onChangeStart: (_) => setState(() => _dragMs = value),
                    onChanged: (v) => setState(() => _dragMs = v),
                    onChangeEnd: (v) async {
                      setState(() => _dragMs = null);
                      await controller.seek(Duration(milliseconds: v.round()));
                    },
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(controller._fmt(Duration(milliseconds: posMs.round())),
                        style: Theme.of(context).textTheme.bodySmall),
                    Text(controller._fmt(duration),
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _NowPlayingControls extends StatelessWidget {
  final _AppController controller;
  const _NowPlayingControls({required this.controller});

  @override
  Widget build(BuildContext context) {
    const sideControlSize = 46.0;
    const centerControlSize = 58.0;

    return Center(
      child: StreamBuilder<PlayerState>(
        stream: controller.playerStateStream,
        builder: (context, snap) {
          final playing = snap.data?.playing ?? false;
          final processing = snap.data?.processingState ?? ProcessingState.idle;
          final busy = processing == ProcessingState.loading ||
              processing == ProcessingState.buffering;

          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.filledTonal(
                tooltip: '上一首',
                style: IconButton.styleFrom(
                  minimumSize: const Size.square(sideControlSize),
                  maximumSize: const Size.square(sideControlSize),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: controller.canPlayPreviousTrack
                    ? () {
                        HapticFeedback.selectionClick();
                        controller.playPreviousTrack();
                      }
                    : null,
                icon: const Icon(Icons.skip_previous_rounded, size: 24),
              ),
              const SizedBox(width: 10),
              Semantics(
                button: true,
                label: playing ? '暂停' : '播放',
                child: Tooltip(
                  message: playing ? '暂停' : '播放',
                  child: IconButton.filled(
                    style: IconButton.styleFrom(
                      minimumSize: const Size.square(centerControlSize),
                      maximumSize: const Size.square(centerControlSize),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: busy
                        ? null
                        : () async {
                            HapticFeedback.selectionClick();
                            if (playing) {
                              await controller.pause();
                            } else {
                              await controller.play();
                            }
                          },
                    icon: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 30,
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filledTonal(
                tooltip: '下一首',
                style: IconButton.styleFrom(
                  minimumSize: const Size.square(sideControlSize),
                  maximumSize: const Size.square(sideControlSize),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: controller.canPlayNextTrack
                    ? () {
                        HapticFeedback.selectionClick();
                        controller.playNextTrack();
                      }
                    : null,
                icon: const Icon(Icons.skip_next_rounded, size: 24),
              ),
            ],
          );
        },
      ),
    );
  }
}

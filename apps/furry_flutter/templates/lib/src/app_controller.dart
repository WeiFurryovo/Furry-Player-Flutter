part of '../main.dart';

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
  final ValueNotifier<int> furryOutputsSignature = ValueNotifier<int>(0);
  final ValueNotifier<String> log = ValueNotifier<String>('');

  final ListQueue<String> _logLines = ListQueue<String>();
  int _logChars = 0;

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
  final _EpochTokenGate _libraryBuildGate = _EpochTokenGate();
  final _EpochTokenGate _outputsRefreshGate = _EpochTokenGate();
  final _EpochTokenGate _playRequestGate = _EpochTokenGate();
  final _QueueSnapshotBuilder _queueSnapshotBuilder =
      const _QueueSnapshotBuilder();
  final _QueueMutationPlanner _queueMutationPlanner =
      const _QueueMutationPlanner();
  static const _LibraryIndex _emptyLibraryIndex = _LibraryIndex(
    tracks: <_TrackEntry>[],
    albums: <_AlbumGroup>[],
    artists: <_ArtistGroup>[],
  );
  static const int _metaPreviewCacheLimit = 64;
  static const int _ioWorkerCount = 8;
  static const int _metaWorkerCount = 6;
  static const int _maxInMemoryLogChars = 200000;
  static const int _maxInMemoryLogLines = 4096;

  int paddingKb = 0;

  File? pickedForPack;
  String? pickedForPackName;

  void _restoreLogBuffer(String raw) {
    _logLines.clear();
    _logChars = 0;

    final normalized = raw.replaceAll('\r\n', '\n');
    for (final line in normalized.split('\n')) {
      if (line.isEmpty) continue;
      _logLines.addLast(line);
      _logChars += line.length + 1;
    }

    _trimLogBuffer();
    _syncLogNotifier();
  }

  void _trimLogBuffer() {
    while (_logLines.length > _maxInMemoryLogLines ||
        _logChars > _maxInMemoryLogChars) {
      final removed = _logLines.removeLast();
      _logChars -= removed.length + 1;
    }
    if (_logChars < 0) {
      _logChars = 0;
    }
  }

  void _syncLogNotifier() {
    log.value = _logLines.isEmpty ? '' : '${_logLines.join('\n')}\n';
  }

  void _appendLogLineToMemory(String line) {
    _logLines.addFirst(line);
    _logChars += line.length + 1;
    _trimLogBuffer();
    _syncLogNotifier();
  }

  /// 初始化控制器：加载平台能力、绑定系统媒体中心、恢复/刷新数据并写入诊断日志。
  Future<void> init() async {
    final persisted = await _DiagnosticsLog.readAll();
    if (persisted.trim().isNotEmpty) {
      _restoreLogBuffer(persisted);
    } else {
      _syncLogNotifier();
    }
    appendLog('Process: pid=$pid');
    try {
      await api.init();
      await systemMedia.init();
      systemMedia.bindQueueControls(
        onNext: playNextTrack,
        onPrevious: playPreviousTrack,
      );
      _syncQueueAvailability();
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
    queueState.value = _queueSnapshotBuilder.build(_queue, _queueIndex);
  }

  void requestTabIndex(int index) {
    requestedTab.value = index;
  }

  bool get _supportsAndroidPlaylist => !kIsWeb && Platform.isAndroid;

  bool get _useAndroidPlaylistControls =>
      _androidPlaylistActive && _supportsAndroidPlaylist;

  void _syncQueueAvailability() {
    unawaited(systemMedia.setQueueAvailability(
      canGoNext: canPlayNextTrack,
      canGoPrevious: canPlayPreviousTrack,
    ));
  }

  void _publishQueueStateAndAvailability() {
    _publishQueueState();
    _syncQueueAvailability();
  }

  int _beginPlayRequest() => _playRequestGate.begin();

  bool _isPlayRequestCurrent(int token) => _playRequestGate.isCurrent(token);

  void _invalidatePlayRequests() {
    _playRequestGate.invalidate();
  }

  Future<List<File>> _listFiles(Directory dir) async {
    final files = <File>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File) files.add(entity);
    }
    return files;
  }

  Future<void> cleanupTempArtifacts() async {
    try {
      final tmp = await getTemporaryDirectory();
      final now = DateTime.now();

      // Cleanup unpacked audio files from `.furry` (keep recent ones).
      final unpackDir = Directory(p.join(tmp.path, 'furry_unpacked'));
      if (await unpackDir.exists()) {
        final unpackFiles = await _listFiles(unpackDir);
        final unpackStates = await _statFilesInOrder(
          unpackFiles,
          concurrency: _ioWorkerCount,
        )
          ..sort((a, b) => b.stat.modified.compareTo(a.stat.modified));
        const keep = 12;
        final cutoff = now.subtract(const Duration(days: 2));
        for (var i = 0; i < unpackStates.length; i++) {
          final entry = unpackStates[i];
          if (i >= keep || entry.stat.modified.isBefore(cutoff)) {
            try {
              await entry.file.delete();
            } catch (_) {}
          }
        }
      }

      // Cleanup imported temp files created from picker streams/bytes.
      final rootFiles = await _listFiles(tmp);
      final importCandidates = rootFiles
          .where((file) => p.basename(file.path).startsWith('import_'))
          .toList(growable: false);
      final importStates = await _statFilesInOrder(
        importCandidates,
        concurrency: _ioWorkerCount,
      );
      final importCutoff = now.subtract(const Duration(days: 2));
      for (final entry in importStates) {
        if (entry.stat.modified.isBefore(importCutoff)) {
          try {
            await entry.file.delete();
          } catch (_) {}
        }
      }

      // Cleanup cover art temp files.
      final artDir = Directory(p.join(tmp.path, 'furry_media_art'));
      if (await artDir.exists()) {
        final artFiles = await _listFiles(artDir);
        final artStates = await _statFilesInOrder(
          artFiles,
          concurrency: _ioWorkerCount,
        );

        final cutoff = now.subtract(const Duration(days: 7));
        final alive = <_FileStatEntry>[];
        for (final entry in artStates) {
          if (entry.stat.modified.isBefore(cutoff)) {
            try {
              await entry.file.delete();
            } catch (_) {}
            continue;
          }
          alive.add(entry);
        }

        // Cap total cover cache size (LRU by modified time).
        const maxArtCacheBytes = 256 * 1024 * 1024; // 256 MiB
        var totalBytes = 0;
        for (final entry in alive) {
          totalBytes += entry.stat.size;
        }
        if (totalBytes > maxArtCacheBytes) {
          alive.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
          for (final entry in alive) {
            if (totalBytes <= maxArtCacheBytes) break;
            try {
              await entry.file.delete();
              totalBytes -= entry.stat.size;
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

  void _cacheMetaPreviewEntry(String key, _MetaPreviewCacheEntry entry) {
    _metaPreviewCache.remove(key);
    _metaPreviewCache[key] = entry;
    if (_metaPreviewCache.length > _metaPreviewCacheLimit) {
      _metaPreviewCache.remove(_metaPreviewCache.keys.first);
    }
  }

  void _evictMetaPreviewEntryIfSameFuture(
    String key,
    Future<_MetaPreview> future,
  ) {
    final current = _metaPreviewCache[key];
    if (current != null && identical(current.future, future)) {
      _metaPreviewCache.remove(key);
    }
  }

  Future<_MetaPreview> _getMetaPreviewForFurryCached(
    File furryFile,
    DateTime modified,
  ) {
    final key = furryFile.path;
    final existing = _metaPreviewCache[key];
    if (existing != null && existing.modified == modified) {
      _cacheMetaPreviewEntry(key, existing);
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

    _cacheMetaPreviewEntry(
      key,
      _MetaPreviewCacheEntry(
        modified: modified,
        future: future,
      ),
    );

    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          _evictMetaPreviewEntryIfSameFuture(key, future);
        },
      ),
    );

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
    furryOutputsSignature.dispose();
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
      _syncQueueAvailability();
    });
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
    _appendLogLineToMemory('${DateTime.now().toIso8601String()}  $msg');
    unawaited(_DiagnosticsLog.appendLine(msg));
  }

  Future<void> clearLog() async {
    _logLines.clear();
    _logChars = 0;
    _syncLogNotifier();
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
}

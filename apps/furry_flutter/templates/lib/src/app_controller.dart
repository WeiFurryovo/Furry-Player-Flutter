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
    int? requestToken,
  }) async {
    final playToken = requestToken ?? _beginPlayRequest();

    bool isStalePlayRequest() => !_isPlayRequestCurrent(playToken);

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
    _publishQueueStateAndAvailability();

    if (isStalePlayRequest()) return;

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
      if (isStalePlayRequest()) return;

      if (isFurry) {
        await cleanupTempArtifacts();
        if (isStalePlayRequest()) return;

        final originalExt = await api.getOriginalFormat(filePath: file.path);
        if (isStalePlayRequest()) return;

        final tmp = await getTemporaryDirectory();
        if (isStalePlayRequest()) return;

        final outDir = Directory(p.join(tmp.path, 'furry_unpacked'));
        if (!await outDir.exists()) {
          await outDir.create(recursive: true);
        }
        if (isStalePlayRequest()) return;

        final outExt = originalExt.trim().isEmpty ? 'bin' : originalExt.trim();
        final outPath = p.join(
          outDir.path,
          'unpacked_${file.path.hashCode}_${DateTime.now().millisecondsSinceEpoch}.$outExt',
        );
        appendLog('Unpacking .furry → $outExt…');
        final rc =
            await api.unpackToFile(inputPath: file.path, outputPath: outPath);
        if (isStalePlayRequest()) return;

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
        if (isStalePlayRequest()) return;

        final meta = await getMetaPreviewForFurry(file);
        if (isStalePlayRequest()) return;

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
          if (isStalePlayRequest()) return;
          await player.setAudioSource(
            AudioSource.uri(unpacked.uri, tag: mediaItem),
          );
        } else {
          final bytes = await api.unpackFromFurryToBytes(inputPath: file.path);
          if (isStalePlayRequest()) return;

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
            if (isStalePlayRequest()) return;

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
        if (isStalePlayRequest()) return;

        await play();
        if (isStalePlayRequest()) return;

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
        if (isStalePlayRequest()) return;

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
        if (isStalePlayRequest()) return;

        await player.setAudioSource(AudioSource.uri(file.uri, tag: mediaItem));
        if (isStalePlayRequest()) return;

        await play();
        if (isStalePlayRequest()) return;

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
        if (isStalePlayRequest()) return;

        appendLog('Playing (raw): $name');
      }
    } catch (e, st) {
      if (isStalePlayRequest()) return;
      appendLog('Play failed: $e\n$st');
    }
  }

  Future<void> playFromQueue({
    required List<File> queue,
    required int index,
    String? displayName,
    int? requestToken,
  }) async {
    if (queue.isEmpty) return;
    if (index < 0 || index >= queue.length) return;

    final playToken = requestToken ?? _beginPlayRequest();

    bool isStalePlayRequest() => !_isPlayRequestCurrent(playToken);

    // On Android, use a playlist so audio_service can expose next/previous in the
    // system notification/lockscreen controls.
    if (_supportsAndroidPlaylist && queue.length > 1) {
      _queue = List<File>.from(queue);
      _queueIndex = index;
      _androidPlaylistActive = true;
      _publishQueueStateAndAvailability();

      if (isStalePlayRequest()) return;

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
      if (isStalePlayRequest()) return;

      final tmp = await getTemporaryDirectory();
      if (isStalePlayRequest()) return;

      final outDir = Directory(p.join(tmp.path, 'furry_unpacked'));
      if (!await outDir.exists()) await outDir.create(recursive: true);
      if (isStalePlayRequest()) return;

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
        if (isStalePlayRequest()) return;

        final base = p.basename(f.path);
        final ext = p.extension(base).toLowerCase();
        final isFurry =
            ext == '.furry' || await api.isValidFurryFile(filePath: f.path);
        if (isStalePlayRequest()) return;

        Uri uri;
        String title;
        String artist;
        Uri? artUri;

        if (isFurry) {
          final playable = await ensurePlayableFileForFurry(f);
          if (isStalePlayRequest()) return;

          uri = playable.uri;
          final meta = await getMetaPreviewForFurry(f);
          if (isStalePlayRequest()) return;

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

      if (isStalePlayRequest()) return;

      await player.setAudioSource(
        ConcatenatingAudioSource(children: sources),
        initialIndex: index,
        initialPosition: Duration.zero,
      );
      if (isStalePlayRequest()) return;

      await play();
      if (isStalePlayRequest()) return;

      // Update UI immediately (system controls update via MediaItem tags).
      await _syncNowPlayingFromQueueIndex(index);
      return;
    }

    _androidPlaylistActive = false;
    _queue = List<File>.from(queue);
    _queueIndex = index;
    _publishQueueStateAndAvailability();
    if (isStalePlayRequest()) return;

    await playFile(
      file: queue[index],
      displayName: displayName ?? p.basename(queue[index].path),
      requestToken: playToken,
    );
  }
}

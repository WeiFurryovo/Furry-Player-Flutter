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

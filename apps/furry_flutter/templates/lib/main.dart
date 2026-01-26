import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'furry_api.dart';
import 'furry_api_selector.dart';
import 'in_memory_audio_source.dart';
import 'system_media_bridge.dart';

final List<String> _startupDiagnostics = <String>[];

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

class _DiagnosticsLog {
  static File? _file;
  static Future<void> _writeChain = Future<void>.value();

  static const int _maxBytes = 512 * 1024; // 512 KiB
  static const int _keepBytes = 256 * 1024; // 256 KiB

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
}

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

  if (!kIsWeb && Platform.isAndroid) {
    final prevPlatform = JustAudioPlatform.instance;
    try {
      await JustAudioBackground.init(
        androidNotificationChannelId:
            'com.furry.furry_flutter_app.channel.audio',
        androidNotificationChannelName: 'Furry Player',
        androidNotificationOngoing: true,
      );
      _startupLog('JustAudioBackground init ok');
    } catch (e, st) {
      // If AudioService init fails, just_audio_background may have already replaced the platform.
      // Restore the previous platform so playback still works (without system controls).
      JustAudioPlatform.instance = prevPlatform;
      _startupLog('JustAudioBackground init failed: $e\n$st');
    }
  }
  runApp(const FurryApp());
}

class FurryApp extends StatelessWidget {
  const FurryApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF8E7CFF);
    return MaterialApp(
      title: 'Furry Player (Flutter)',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme:
            ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme:
            ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
      ),
      home: const AppShell(),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  late final _controller = _AppController();
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controller.appendLog('Lifecycle: $state');
  }

  @override
  Widget build(BuildContext context) {
    final destinations = <NavigationDestination>[
      const NavigationDestination(
          icon: Icon(Icons.library_music_outlined),
          selectedIcon: Icon(Icons.library_music),
          label: '本地'),
      const NavigationDestination(
          icon: Icon(Icons.swap_horiz_outlined),
          selectedIcon: Icon(Icons.swap_horiz),
          label: '转换'),
      const NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: '设置'),
    ];

    return Scaffold(
      body: SafeArea(
        top: false,
        child: IndexedStack(
          index: _tabIndex,
          children: [
            LibraryPage(controller: _controller),
            ConverterPage(controller: _controller),
            SettingsPage(controller: _controller),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MiniPlayerBar(controller: _controller),
            NavigationBar(
              selectedIndex: _tabIndex,
              destinations: destinations,
              onDestinationSelected: (i) => setState(() => _tabIndex = i),
            ),
          ],
        ),
      ),
    );
  }
}

class _AppController {
  final AudioPlayer player = AudioPlayer();
  final FurryApi api = createFurryApi();
  late final SystemMediaBridge systemMedia = SystemMediaBridge(player);

  StreamSubscription<dynamic>? _playbackErrorsSub;
  StreamSubscription<dynamic>? _playerStateSub;
  Timer? _rssTimer;

  final ValueNotifier<_NowPlaying?> nowPlaying =
      ValueNotifier<_NowPlaying?>(null);
  final ValueNotifier<List<File>> furryOutputs =
      ValueNotifier<List<File>>(<File>[]);
  final ValueNotifier<String> log = ValueNotifier<String>('');

  List<File>? _queue;
  int _queueIndex = -1;

  // Keep this bounded to avoid unbounded RAM growth (cover bytes can be large).
  final Map<String, Future<_MetaPreview>> _metaPreviewCache =
      <String, Future<_MetaPreview>>{};
  static const int _metaPreviewCacheLimit = 64;

  int paddingKb = 0;

  File? pickedForPack;
  String? pickedForPackName;

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
        for (final f in artDir.listSync().whereType<File>()) {
          if (f.lastModifiedSync().isBefore(cutoff)) {
            try {
              await f.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  void dispose() {
    _playbackErrorsSub?.cancel();
    _playerStateSub?.cancel();
    _rssTimer?.cancel();
    player.dispose();
    systemMedia.dispose();
    nowPlaying.dispose();
    furryOutputs.dispose();
    log.dispose();
  }

  void _wirePlayerDiagnostics() {
    _playbackErrorsSub?.cancel();
    _playerStateSub?.cancel();
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

    final out = File(
        p.join(artDir.path, 'cover_${bytes.length}_${bytes.hashCode}.$ext'));
    if (!await out.exists()) {
      await out.writeAsBytes(bytes, flush: true);
    }
    return out.uri;
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
      }
    } else {
      _queueIndex = -1;
    }
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
          artist: meta.subtitle,
          artUri: artUriSystem,
        );
        if (unpacked != null) {
          await player
              .setAudioSource(AudioSource.uri(unpacked.uri, tag: mediaItem));
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
            await player
                .setAudioSource(AudioSource.uri(unpacked.uri, tag: mediaItem));
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
                  bytes: bytes, contentType: mime, tag: mediaItem),
            );
          }
        }
        await player.play();
        nowPlaying.value = _NowPlaying(
          title: meta.title.isEmpty ? name : meta.title,
          subtitle:
              meta.subtitle.isEmpty ? '.furry → $originalExt' : meta.subtitle,
          sourcePath: file.path,
          artUri: artUriUi,
        );
        await systemMedia.setMetadata(
          SystemMediaMetadata(
            title: nowPlaying.value!.title,
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
        await player.play();
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
    _queue = List<File>.from(queue);
    _queueIndex = index;
    unawaited(systemMedia.setQueueAvailability(
      canGoNext: canPlayNextTrack,
      canGoPrevious: canPlayPreviousTrack,
    ));
    await playFile(
      file: queue[index],
      displayName: displayName ?? p.basename(queue[index].path),
    );
  }

  bool get canPlayPreviousTrack => _queue != null && _queueIndex > 0;
  bool get canPlayNextTrack =>
      _queue != null && _queueIndex >= 0 && _queueIndex < (_queue!.length - 1);

  Future<void> playPreviousTrack() async {
    final queue = _queue;
    if (queue == null) return;
    if (_queueIndex <= 0) return;
    await playFromQueue(queue: queue, index: _queueIndex - 1);
  }

  Future<void> playNextTrack() async {
    final queue = _queue;
    if (queue == null) return;
    if (_queueIndex < 0 || _queueIndex >= queue.length - 1) return;
    await playFromQueue(queue: queue, index: _queueIndex + 1);
  }

  Future<void> stop() async {
    await player.stop();
    appendLog('Stopped');
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
      final target = player.position + delta;
      var clamped = target;
      if (clamped.isNegative) clamped = Duration.zero;
      if (duration != null && clamped > duration) clamped = duration;
      await player.seek(clamped);
    } catch (e, st) {
      appendLog('Seek failed: $e\n$st');
    }
  }

  Future<_MetaPreview> getMetaPreviewForFurry(File furryFile) {
    final key = furryFile.path;
    final existing = _metaPreviewCache[key];
    if (existing != null) return existing;
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
        subtitle: subtitleParts.join(' · '),
        artUri: artUri,
        coverBytesLen: coverBytesLen,
      );
    }();

    _metaPreviewCache[key] = future;
    if (_metaPreviewCache.length > _metaPreviewCacheLimit) {
      final firstKey = _metaPreviewCache.keys.first;
      _metaPreviewCache.remove(firstKey);
    }
    return future;
  }
}

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

class _MetaPreview {
  final String title;
  final String subtitle;
  final Uri? artUri;
  final int? coverBytesLen;

  _MetaPreview({
    required this.title,
    required this.subtitle,
    required this.artUri,
    required this.coverBytesLen,
  });
}

class LibraryPage extends StatefulWidget {
  final _AppController controller;
  const LibraryPage({super.key, required this.controller});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地音乐'),
        actions: [
          IconButton(
            tooltip: '选择文件播放',
            onPressed: () async {
              final f = await controller.pickForPlay();
              if (f == null) return;
              await controller.playFile(file: f);
            },
            icon: const Icon(Icons.playlist_add),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: controller.refreshOutputs,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          SearchBar(
            hintText: '搜索（输出的 .furry）',
            leading: const Icon(Icons.search),
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
          const SizedBox(height: 12),
          Text('最近输出', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ValueListenableBuilder<List<File>>(
            valueListenable: controller.furryOutputs,
            builder: (context, files, _) {
              final filtered = files.where((f) {
                if (_query.isEmpty) return true;
                return p
                    .basename(f.path)
                    .toLowerCase()
                    .contains(_query.toLowerCase());
              }).toList();

              if (filtered.isEmpty) {
                return const Text('暂无 .furry 输出文件（去“转换”页打包试试）');
              }

              return Column(
                children: [
                  for (var i = 0; i < filtered.length; i++)
                    FutureBuilder<_MetaPreview>(
                      future: controller.getMetaPreviewForFurry(filtered[i]),
                      builder: (context, snap) {
                        final f = filtered[i];
                        final meta = snap.data;
                        return ListTile(
                          leading: _CoverThumb(artUri: meta?.artUri),
                          title: Text(meta?.title ?? p.basename(f.path),
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            meta == null || meta.subtitle.isEmpty
                                ? '${_fmtBytes(f.lengthSync())} · ${f.lastModifiedSync().toLocal()}'
                                : meta.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => controller.playFromQueue(
                            queue: filtered,
                            index: i,
                            displayName: p.basename(f.path),
                          ),
                        );
                      },
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  String _fmtBytes(int bytes) {
    const kb = 1024;
    const mb = 1024 * 1024;
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(1)} KB';
    return '$bytes B';
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
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 44,
        height: 44,
        color: cs.surfaceContainerHighest,
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
  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('转换 / 打包')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.lock, color: cs.primary),
                      const SizedBox(width: 8),
                      const Text('打包（音频 → .furry）',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          await controller.pickForPack();
                          setState(() {});
                        },
                        icon: const Icon(Icons.audio_file),
                        label: const Text('选择音频'),
                      ),
                      FilledButton.icon(
                        onPressed: controller.startPack,
                        icon: const Icon(Icons.auto_fix_high),
                        label: const Text('开始打包'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(controller.pickedForPackName == null
                      ? '未选择输入文件'
                      : '输入：${controller.pickedForPackName}'),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('Padding (KB)'),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Slider(
                          value: controller.paddingKb.toDouble().clamp(0, 1024),
                          min: 0,
                          max: 1024,
                          divisions: 64,
                          label: '${controller.paddingKb} KB',
                          onChanged: (v) =>
                              setState(() => controller.paddingKb = v.round()),
                        ),
                      ),
                    ],
                  ),
                  Text('当前 padding: ${controller.paddingKb} KB',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.play_circle, color: cs.primary),
                      const SizedBox(width: 8),
                      const Text('播放（文件或 .furry）',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          final f = await controller.pickForPlay();
                          if (f == null) return;
                          await controller.playFile(file: f);
                        },
                        icon: const Icon(Icons.folder_open),
                        label: const Text('选择并播放'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: controller.stop,
                        icon: const Icon(Icons.stop),
                        label: const Text('停止'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsPage extends StatelessWidget {
  final _AppController controller;
  const SettingsPage({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('诊断日志',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  ValueListenableBuilder<String>(
                    valueListenable: controller.log,
                    builder: (context, log, _) {
                      return SelectableText(
                        log.isEmpty ? '(empty)' : log,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(fontFamily: 'monospace'),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MiniPlayerBar extends StatelessWidget {
  final _AppController controller;
  const MiniPlayerBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<_NowPlaying?>(
      valueListenable: controller.nowPlaying,
      builder: (context, np, _) {
        if (np == null) return const SizedBox.shrink();

        return Material(
          color: cs.surfaceContainerHighest,
          child: InkWell(
            onTap: () => _showNowPlaying(context, controller),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  _CoverThumb(artUri: np.artUri),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(np.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text(np.subtitle,
                            style: Theme.of(context).textTheme.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '上一首',
                    onPressed: controller.canPlayPreviousTrack
                        ? controller.playPreviousTrack
                        : null,
                    icon: const Icon(Icons.skip_previous),
                  ),
                  StreamBuilder<PlayerState>(
                    stream: controller.player.playerStateStream,
                    builder: (context, snap) {
                      final playing = snap.data?.playing ?? false;
                      final processing =
                          snap.data?.processingState ?? ProcessingState.idle;
                      final busy = processing == ProcessingState.loading ||
                          processing == ProcessingState.buffering;
                      return IconButton.filledTonal(
                        onPressed: busy
                            ? null
                            : () async {
                                if (playing) {
                                  await controller.player.pause();
                                } else {
                                  await controller.player.play();
                                }
                              },
                        icon: busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : Icon(playing ? Icons.pause : Icons.play_arrow),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: '下一首',
                    onPressed: controller.canPlayNextTrack
                        ? controller.playNextTrack
                        : null,
                    icon: const Icon(Icons.skip_next),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showNowPlaying(BuildContext context, _AppController controller) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => NowPlayingSheet(controller: controller),
    );
  }
}

class NowPlayingSheet extends StatefulWidget {
  final _AppController controller;
  const NowPlayingSheet({super.key, required this.controller});

  @override
  State<NowPlayingSheet> createState() => _NowPlayingSheetState();
}

class _NowPlayingSheetState extends State<NowPlayingSheet> {
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<_NowPlaying?>(
      valueListenable: widget.controller.nowPlaying,
      builder: (context, np, _) {
        if (np == null) {
          return const SizedBox.shrink();
        }

        return DraggableScrollableSheet(
          initialChildSize: 0.70,
          minChildSize: 0.45,
          maxChildSize: 0.98,
          expand: false,
          builder: (context, scrollController) {
            return Material(
              color: cs.surface,
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  Center(
                    child: Container(
                      width: 48,
                      height: 5,
                      decoration: BoxDecoration(
                        color: cs.outlineVariant,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  AspectRatio(
                    aspectRatio: 1,
                    child: Container(
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: np.artUri == null
                          ? Icon(Icons.album, size: 96, color: cs.primary)
                          : Image.file(
                              File.fromUri(np.artUri!),
                              fit: BoxFit.cover,
                              cacheWidth: 1200,
                              cacheHeight: 1200,
                            ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    np.title,
                    style: Theme.of(context).textTheme.titleLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(np.subtitle,
                      style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 16),
                  StreamBuilder<Duration?>(
                    stream: widget.controller.player.durationStream,
                    builder: (context, durSnap) {
                      final duration = durSnap.data ?? Duration.zero;
                      return StreamBuilder<Duration>(
                        stream: widget.controller.player.positionStream,
                        builder: (context, posSnap) {
                          final position = posSnap.data ?? Duration.zero;
                          final max = duration.inMilliseconds > 0
                              ? duration.inMilliseconds.toDouble()
                              : 1.0;
                          final current = position.inMilliseconds
                              .clamp(0, max.toInt())
                              .toDouble();
                          final value =
                              (_dragMs ?? current).clamp(0, max).toDouble();
                          return Column(
                            children: [
                              Slider(
                                value: value,
                                max: max,
                                onChanged: (v) => setState(() => _dragMs = v),
                                onChangeEnd: (v) async {
                                  setState(() => _dragMs = null);
                                  await widget.controller.player
                                      .seek(Duration(milliseconds: v.round()));
                                },
                              ),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    widget.controller._fmt(
                                        Duration(milliseconds: value.round())),
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                  Text(
                                    widget.controller._fmt(duration),
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: '上一首',
                        onPressed: widget.controller.canPlayPreviousTrack
                            ? widget.controller.playPreviousTrack
                            : null,
                        icon: const Icon(Icons.skip_previous),
                      ),
                      const SizedBox(width: 12),
                      StreamBuilder<PlayerState>(
                        stream: widget.controller.player.playerStateStream,
                        builder: (context, snap) {
                          final playing = snap.data?.playing ?? false;
                          final processing = snap.data?.processingState ??
                              ProcessingState.idle;
                          final busy = processing == ProcessingState.loading ||
                              processing == ProcessingState.buffering;
                          return FilledButton.tonalIcon(
                            onPressed: busy
                                ? null
                                : () async {
                                    if (playing) {
                                      await widget.controller.player.pause();
                                    } else {
                                      await widget.controller.player.play();
                                    }
                                  },
                            icon: busy
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : Icon(
                                    playing ? Icons.pause : Icons.play_arrow),
                            label: Text(playing ? '暂停' : '播放'),
                          );
                        },
                      ),
                      const SizedBox(width: 12),
                      IconButton(
                        tooltip: '下一首',
                        onPressed: widget.controller.canPlayNextTrack
                            ? widget.controller.playNextTrack
                            : null,
                        icon: const Icon(Icons.skip_next),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              np.sourcePath,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'furry_api.dart';
import 'furry_api_selector.dart';
import 'in_memory_audio_source.dart';
import 'system_media_bridge.dart';

final List<String> _startupDiagnostics = <String>[];
AudioHandler? _androidAudioHandler;

Color _withOpacityCompat(Color color, double opacity) =>
    color.withAlpha((opacity * 255).round().clamp(0, 255));

// audio_service needs a top-level entry-point builder on Android (especially for
// background isolate / release tree-shaking).
@pragma('vm:entry-point')
AudioHandler _androidAudioHandlerBuilder() => _AndroidAudioHandler();

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

@pragma('vm:entry-point')
class _AndroidAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final AudioPlayer player = AudioPlayer();

  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];
  PlaybackEvent? _lastEvent;
  int _queueLength = 0;
  int _currentIndex = -1;

  _AndroidAudioHandler() {
    _subs.add(player.sequenceStateStream.listen((s) {
      final seq = s?.effectiveSequence ?? const <IndexedAudioSource>[];
      final items = <MediaItem>[];
      for (final src in seq) {
        final tag = src.tag;
        if (tag is MediaItem) items.add(tag);
      }
      _queueLength = items.length;
      _currentIndex = s?.currentIndex ?? -1;
      queue.add(items);

      final idx = _currentIndex;
      if (idx >= 0 && idx < items.length) {
        mediaItem.add(items[idx]);
      }
      _broadcastState();
    }));

    _subs.add(player.playbackEventStream.listen((e) {
      _lastEvent = e;
      _broadcastState();
    }));

    _subs.add(player.positionStream.listen((_) {
      _broadcastState();
    }));

    _subs.add(player.durationStream.listen((d) {
      if (d == null) return;
      final item = mediaItem.value;
      if (item == null) return;
      if (item.duration == d) return;
      mediaItem.add(item.copyWith(duration: d));
    }));
  }

  void _broadcastState() {
    final hasPrevious = _currentIndex > 0;
    final hasNext = _currentIndex >= 0 && _currentIndex < (_queueLength - 1);

    final playing = player.playing;
    final processingState = player.processingState;

    final controls = <MediaControl>[
      if (hasPrevious) MediaControl.skipToPrevious,
      if (playing) MediaControl.pause else MediaControl.play,
      if (hasNext) MediaControl.skipToNext,
    ];

    playbackState.add(
      playbackState.value.copyWith(
        controls: controls,
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices:
            List<int>.generate(controls.length, (i) => i),
        processingState: const <ProcessingState, AudioProcessingState>{
          ProcessingState.idle: AudioProcessingState.idle,
          ProcessingState.loading: AudioProcessingState.loading,
          ProcessingState.buffering: AudioProcessingState.buffering,
          ProcessingState.ready: AudioProcessingState.ready,
          ProcessingState.completed: AudioProcessingState.completed,
        }[processingState]!,
        playing: playing,
        updatePosition: player.position,
        bufferedPosition: _lastEvent?.bufferedPosition ?? Duration.zero,
        speed: player.speed,
        queueIndex: _currentIndex >= 0 ? _currentIndex : null,
      ),
    );
  }

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> stop() async {
    await player.pause();
  }

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> skipToQueueItem(int index) async {
    await player.seek(Duration.zero, index: index);
    await player.play();
  }

  @override
  Future<void> skipToNext() async {
    final next = _currentIndex + 1;
    if (next < 0 || next >= _queueLength) return;
    await skipToQueueItem(next);
  }

  @override
  Future<void> skipToPrevious() async {
    final prev = _currentIndex - 1;
    if (prev < 0 || prev >= _queueLength) return;
    await skipToQueueItem(prev);
  }

  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    switch (name) {
      case 'setAudioSource':
        final uriStr = extras?['uri'] as String?;
        if (uriStr == null || uriStr.trim().isEmpty) return null;
        final id = (extras?['id'] as String?)?.trim() ?? uriStr;
        final title = (extras?['title'] as String?)?.trim() ?? id;
        final artist = (extras?['artist'] as String?)?.trim() ?? '';
        final album = (extras?['album'] as String?)?.trim() ?? '';
        final artStr = (extras?['artUri'] as String?)?.trim();
        final media = MediaItem(
          id: id,
          title: title,
          artist: artist,
          album: album,
          artUri: artStr == null || artStr.isEmpty ? null : Uri.parse(artStr),
        );
        await player.setAudioSource(
          AudioSource.uri(Uri.parse(uriStr), tag: media),
          initialPosition: Duration.zero,
        );
        return null;

      case 'setPlaylist':
        final raw = extras?['items'];
        if (raw is! List) return null;
        final sources = <AudioSource>[];
        for (final it in raw) {
          if (it is! Map) continue;
          final uriStr = it['uri'] as String?;
          if (uriStr == null || uriStr.trim().isEmpty) continue;
          final id = (it['id'] as String?)?.trim() ?? uriStr;
          final title = (it['title'] as String?)?.trim() ?? id;
          final artist = (it['artist'] as String?)?.trim() ?? '';
          final album = (it['album'] as String?)?.trim() ?? '';
          final artStr = (it['artUri'] as String?)?.trim();
          sources.add(
            AudioSource.uri(
              Uri.parse(uriStr),
              tag: MediaItem(
                id: id,
                title: title,
                artist: artist,
                album: album,
                artUri:
                    artStr == null || artStr.isEmpty ? null : Uri.parse(artStr),
              ),
            ),
          );
        }
        if (sources.isEmpty) return null;
        final initialIndex = extras?['initialIndex'] as int? ?? 0;
        await player.setAudioSource(
          ConcatenatingAudioSource(children: sources),
          initialIndex: initialIndex.clamp(0, sources.length - 1),
          initialPosition: Duration.zero,
        );
        return null;
    }
    return super.customAction(name, extras);
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await player.dispose();
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
    try {
      final handler = await AudioService.init(
        builder: _androidAudioHandlerBuilder,
        config: AudioServiceConfig(
          androidNotificationChannelId:
              'com.furry.furry_flutter_app.channel.audio',
          androidNotificationChannelName: 'Furry Player',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: false,
          fastForwardInterval: Duration(seconds: 10),
          rewindInterval: Duration(seconds: 10),
        ),
      );
      _androidAudioHandler = handler;
      _startupLog('AudioService init ok');
    } catch (e, st) {
      _startupLog('AudioService init failed: $e\n$st');
    }
  }
  runApp(const FurryApp());
}

class FurryApp extends StatelessWidget {
  const FurryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Furry Player (Flutter)',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: _ExpressiveTheme.build(Brightness.light),
      darkTheme: _ExpressiveTheme.build(Brightness.dark),
      home: const AppShell(),
    );
  }
}

class _ExpressiveTheme {
  static ThemeData build(Brightness brightness) {
    const seed = Color(0xFF8E7CFF);
    final scheme =
        ColorScheme.fromSeed(seedColor: seed, brightness: brightness);

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
    );

    final tt = base.textTheme;
    final textTheme = tt.copyWith(
      displaySmall: tt.displaySmall?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.6,
        height: 1.05,
      ),
      headlineSmall: tt.headlineSmall?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4,
        height: 1.10,
      ),
      titleLarge: tt.titleLarge?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.2,
      ),
      titleMedium: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      labelLarge: tt.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    );

    const r24 = BorderRadius.all(Radius.circular(24));
    const r18 = BorderRadius.all(Radius.circular(18));

    return base.copyWith(
      textTheme: textTheme,
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        scrolledUnderElevation: 0,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
      ),
      listTileTheme: ListTileThemeData(
        shape: const RoundedRectangleBorder(borderRadius: r18),
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        backgroundColor: scheme.surface,
        indicatorColor: scheme.secondaryContainer,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.all(12),
        ),
      ),
      sliderTheme: base.sliderTheme.copyWith(
        trackHeight: 4,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
        valueIndicatorShape: const PaddleSliderValueIndicatorShape(),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        showDragHandle: true,
        backgroundColor: scheme.surface,
        modalBackgroundColor: scheme.surface,
        shape: const RoundedRectangleBorder(borderRadius: r24),
        clipBehavior: Clip.antiAlias,
      ),
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
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: IndexedStack(
            key: ValueKey<int>(_tabIndex),
            index: _tabIndex,
            children: [
              LibraryPage(controller: _controller),
              ConverterPage(controller: _controller),
              SettingsPage(controller: _controller),
            ],
          ),
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
  _AppController() : player = AudioPlayer();

  final AudioPlayer player;
  final FurryApi api = createFurryApi();
  late final SystemMediaBridge systemMedia = SystemMediaBridge(player);

  bool get _useAndroidAudioHandler =>
      !kIsWeb && Platform.isAndroid && _androidAudioHandler != null;

  static ProcessingState _toJustAudioProcessingState(
    AudioProcessingState state,
  ) {
    switch (state) {
      case AudioProcessingState.idle:
        return ProcessingState.idle;
      case AudioProcessingState.loading:
        return ProcessingState.loading;
      case AudioProcessingState.buffering:
        return ProcessingState.buffering;
      case AudioProcessingState.ready:
        return ProcessingState.ready;
      case AudioProcessingState.completed:
        return ProcessingState.completed;
      case AudioProcessingState.error:
        return ProcessingState.idle;
    }
  }

  Stream<PlayerState> get playerStateStream {
    if (_useAndroidAudioHandler) {
      final handler = _androidAudioHandler!;
      return handler.playbackState.map((s) {
        return PlayerState(s.playing, _toJustAudioProcessingState(s.processingState));
      });
    }
    return player.playerStateStream;
  }

  Stream<Duration?> get durationStream {
    if (_useAndroidAudioHandler) {
      final handler = _androidAudioHandler!;
      return handler.mediaItem.map((m) => m?.duration).distinct();
    }
    return player.durationStream;
  }

  Stream<Duration> get positionStream {
    if (_useAndroidAudioHandler) {
      final handler = _androidAudioHandler!;
      return handler.playbackState.map((s) => s.updatePosition);
    }
    return player.positionStream;
  }

  StreamSubscription<dynamic>? _playbackErrorsSub;
  StreamSubscription<dynamic>? _playerStateSub;
  StreamSubscription<int?>? _currentIndexSub;
  Timer? _rssTimer;

  final ValueNotifier<_NowPlaying?> nowPlaying =
      ValueNotifier<_NowPlaying?>(null);
  final ValueNotifier<List<File>> furryOutputs =
      ValueNotifier<List<File>>(<File>[]);
  final ValueNotifier<String> log = ValueNotifier<String>('');

  List<File>? _queue;
  int _queueIndex = -1;
  bool _androidPlaylistActive = false;

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
    _currentIndexSub?.cancel();
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

    final idxStream = _useAndroidAudioHandler
        ? _androidAudioHandler!.playbackState.map((s) => s.queueIndex)
        : player.currentIndexStream;
    _currentIndexSub = idxStream.distinct().listen((idx) {
      final queue = _queue;
      if (queue == null) return;
      if (idx == null) return;
      if (idx < 0 || idx >= queue.length) return;
      if (idx == _queueIndex) return;
      _queueIndex = idx;
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
        _androidPlaylistActive = false;
      }
    } else {
      _queueIndex = -1;
      _androidPlaylistActive = false;
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
        if (_useAndroidAudioHandler) {
          if (unpacked == null) {
            final bytes =
                await api.unpackFromFurryToBytes(inputPath: file.path);
            if (bytes == null) {
              appendLog('Unpack-to-bytes failed: null');
              return;
            }
            final fallbackPath = p.join(
              outDir.path,
              'unpacked_mem_${file.path.hashCode}_${DateTime.now().millisecondsSinceEpoch}.$outExt',
            );
            try {
              final f = File(fallbackPath);
              await f.writeAsBytes(bytes, flush: true);
              unpacked = f;
            } catch (e, st) {
              appendLog('Write-bytes fallback failed: $e\n$st');
              return;
            }
          }
          await _androidAudioHandler!.customAction(
            'setAudioSource',
            <String, dynamic>{
              'uri': unpacked!.uri.toString(),
              'id': mediaItem.id,
              'title': mediaItem.title,
              'artist': mediaItem.artist,
              'album': mediaItem.album,
              'artUri': mediaItem.artUri?.toString(),
            },
          );
        } else {
          if (unpacked != null) {
            await player.setAudioSource(
              AudioSource.uri(unpacked.uri, tag: mediaItem),
            );
          } else {
            final bytes =
                await api.unpackFromFurryToBytes(inputPath: file.path);
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
        }
        await play();
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
            duration: _useAndroidAudioHandler ? null : player.duration,
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
        if (_useAndroidAudioHandler) {
          await _androidAudioHandler!.customAction(
            'setAudioSource',
            <String, dynamic>{
              'uri': file.uri.toString(),
              'id': mediaItem.id,
              'title': mediaItem.title,
              'artist': mediaItem.artist,
              'album': mediaItem.album,
              'artUri': mediaItem.artUri?.toString(),
            },
          );
        } else {
          await player.setAudioSource(AudioSource.uri(file.uri, tag: mediaItem));
        }
        await play();
        nowPlaying.value = _NowPlaying(
            title: name, subtitle: '本地文件', sourcePath: file.path, artUri: null);
        await systemMedia.setMetadata(
          SystemMediaMetadata(
            title: name,
            artist: '',
            album: '',
            artUri: null,
            duration: _useAndroidAudioHandler ? null : player.duration,
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
    if (_useAndroidAudioHandler && queue.length > 1) {
      _queue = List<File>.from(queue);
      _queueIndex = index;
      _androidPlaylistActive = true;
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

      final items = <Map<String, dynamic>>[];
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
          artist = meta.subtitle;
          artUri = meta.artUri;
        } else {
          uri = f.uri;
          title = base;
          artist = '';
          artUri = null;
        }

        items.add(
          <String, dynamic>{
            'uri': uri.toString(),
            'id': f.path,
            'title': title,
            'artist': artist,
            'album': '',
            'artUri': artUri?.toString(),
          },
        );
      }

      await _androidAudioHandler!.customAction(
        'setPlaylist',
        <String, dynamic>{
          'items': items,
          'initialIndex': index,
        },
      );
      await play();

      // Update UI immediately (system controls update via MediaItem tags).
      await _syncNowPlayingFromQueueIndex(index);
      return;
    }

    _androidPlaylistActive = false;
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
    final nextIdx = _queueIndex - 1;
    if (_androidPlaylistActive && _useAndroidAudioHandler) {
      _queueIndex = nextIdx;
      unawaited(systemMedia.setQueueAvailability(
        canGoNext: canPlayNextTrack,
        canGoPrevious: canPlayPreviousTrack,
      ));
      await _androidAudioHandler!.skipToQueueItem(nextIdx);
      await _syncNowPlayingFromQueueIndex(nextIdx);
      return;
    }
    await playFromQueue(queue: queue, index: nextIdx);
  }

  Future<void> playNextTrack() async {
    final queue = _queue;
    if (queue == null) return;
    if (_queueIndex < 0 || _queueIndex >= queue.length - 1) return;
    final nextIdx = _queueIndex + 1;
    if (_androidPlaylistActive && _useAndroidAudioHandler) {
      _queueIndex = nextIdx;
      unawaited(systemMedia.setQueueAvailability(
        canGoNext: canPlayNextTrack,
        canGoPrevious: canPlayPreviousTrack,
      ));
      await _androidAudioHandler!.skipToQueueItem(nextIdx);
      await _syncNowPlayingFromQueueIndex(nextIdx);
      return;
    }
    await playFromQueue(queue: queue, index: nextIdx);
  }

  Future<void> stop() async {
    if (_useAndroidAudioHandler) {
      await _androidAudioHandler!.pause();
      await seek(Duration.zero);
      appendLog('Stopped');
      return;
    }
    await player.stop();
    appendLog('Stopped');
  }

  Future<void> play() async {
    if (_useAndroidAudioHandler) {
      await _androidAudioHandler!.play();
      return;
    }
    await player.play();
  }

  Future<void> pause() async {
    if (_useAndroidAudioHandler) {
      await _androidAudioHandler!.pause();
      return;
    }
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
    if (_useAndroidAudioHandler) {
      await _androidAudioHandler!.seek(position);
      return;
    }
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
      final duration = _useAndroidAudioHandler
          ? (_androidAudioHandler!.mediaItem.hasValue
              ? _androidAudioHandler!.mediaItem.value.duration
              : null)
          : player.duration;
      final position = _useAndroidAudioHandler
          ? _androidAudioHandler!.playbackState.value.updatePosition
          : player.position;
      final target = position + delta;
      var clamped = target;
      if (clamped.isNegative) clamped = Duration.zero;
      if (duration != null && clamped > duration) clamped = duration;
      await seek(clamped);
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
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final f = await controller.pickForPlay();
          if (f == null) return;
          await controller.playFile(file: f);
        },
        icon: const Icon(Icons.play_arrow_rounded),
        label: const Text('选择并播放'),
      ),
      body: CustomScrollView(
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
              child: SearchBar(
                hintText: '搜索（输出的 .furry）',
                leading: const Icon(Icons.search_rounded),
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Icon(Icons.history_rounded, color: cs.primary),
                  const SizedBox(width: 8),
                  Text('最近输出', style: Theme.of(context).textTheme.titleLarge),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: ValueListenableBuilder<List<File>>(
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
                  return SliverToBoxAdapter(
                    child: Card(
                      margin: EdgeInsets.zero,
                      elevation: 0,
                      color: cs.surfaceContainerHighest,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Icon(Icons.queue_music_rounded,
                                color: cs.primary, size: 28),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text('暂无 .furry 输出文件（去“转换”页打包试试）'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }

                return SliverList.separated(
                  itemCount: filtered.length,
                  separatorBuilder: (_, i) =>
                      SizedBox(height: i.isEven ? 10 : 10),
                  itemBuilder: (context, i) {
                    final f = filtered[i];
                    return FutureBuilder<_MetaPreview>(
                      future: controller.getMetaPreviewForFurry(f),
                      builder: (context, snap) {
                        final meta = snap.data;
                        return Card(
                          margin: EdgeInsets.zero,
                          elevation: 0,
                          color: cs.surfaceContainerHighest,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(28),
                          ),
                          child: ListTile(
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
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () => controller.playFromQueue(
                              queue: filtered,
                              index: i,
                              displayName: p.basename(f.path),
                            ),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
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
      borderRadius: BorderRadius.circular(14),
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: controller.startPack,
        icon: const Icon(Icons.auto_fix_high_rounded),
        label: const Text('开始打包'),
      ),
      body: CustomScrollView(
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
                elevation: 0,
                color: cs.surfaceContainerHighest,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
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
                            child: Slider(
                              value: controller.paddingKb
                                  .toDouble()
                                  .clamp(0, 1024),
                              min: 0,
                              max: 1024,
                              divisions: 64,
                              label: '${controller.paddingKb} KB',
                              onChanged: (v) => setState(
                                  () => controller.paddingKb = v.round()),
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
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverToBoxAdapter(
              child: Card(
                margin: EdgeInsets.zero,
                elevation: 0,
                color: cs.surfaceContainerHighest,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
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
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const SliverAppBar.large(title: Text('设置')),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            sliver: SliverToBoxAdapter(
              child: Card(
                margin: EdgeInsets.zero,
                elevation: 0,
                color: cs.surfaceContainerHighest,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
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
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
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

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Card(
            margin: EdgeInsets.zero,
            elevation: 0,
            color: cs.surfaceContainerHighest,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
            child: InkWell(
              onTap: () => _showNowPlaying(context, controller),
              borderRadius: BorderRadius.circular(28),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Hero(
                          tag: 'cover_${np.sourcePath}',
                          child: _CoverThumb(artUri: np.artUri),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(np.title,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              Text(
                                np.subtitle,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: cs.onSurfaceVariant),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
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
                            final processing = snap.data?.processingState ??
                                ProcessingState.idle;
                            final busy =
                                processing == ProcessingState.loading ||
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
                        IconButton(
                          tooltip: '下一首',
                          onPressed: controller.canPlayNextTrack
                              ? controller.playNextTrack
                              : null,
                          icon: const Icon(Icons.skip_next_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    StreamBuilder<Duration?>(
                      stream: controller.durationStream,
                      builder: (context, durSnap) {
                        final duration = durSnap.data ?? Duration.zero;
                        return StreamBuilder<Duration>(
                          stream: controller.positionStream,
                          builder: (context, posSnap) {
                            final pos = posSnap.data ?? Duration.zero;
                            final maxMs = duration.inMilliseconds <= 0
                                ? 1
                                : duration.inMilliseconds;
                            final value =
                                (pos.inMilliseconds / maxMs).clamp(0.0, 1.0);
                            return ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: LinearProgressIndicator(
                                value: value,
                                minHeight: 3,
                                backgroundColor: _withOpacityCompat(
                                    cs.onSurfaceVariant, 0.15),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ],
                ),
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
            return DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    _withOpacityCompat(cs.primaryContainer, 0.35),
                    cs.surface,
                  ],
                ),
              ),
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                children: [
                  const SizedBox(height: 8),
                  Center(
                    child: Hero(
                      tag: 'cover_${np.sourcePath}',
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: Container(
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(28),
                            border: Border.all(
                              color: _withOpacityCompat(cs.outlineVariant, 0.5),
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: np.artUri == null
                              ? Icon(Icons.album_rounded,
                                  size: 96, color: cs.primary)
                              : Image.file(
                                  File.fromUri(np.artUri!),
                                  fit: BoxFit.cover,
                                  cacheWidth: 1400,
                                  cacheHeight: 1400,
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    np.title,
                    style: Theme.of(context).textTheme.headlineSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    np.subtitle,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 18),
                  StreamBuilder<Duration?>(
                    stream: widget.controller.durationStream,
                    builder: (context, durSnap) {
                      final duration = durSnap.data ?? Duration.zero;
                      return StreamBuilder<Duration>(
                        stream: widget.controller.positionStream,
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
                                  await widget.controller
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
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(color: cs.onSurfaceVariant),
                                  ),
                                  Text(
                                    widget.controller._fmt(duration),
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(color: cs.onSurfaceVariant),
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton.filledTonal(
                        tooltip: '上一首',
                        onPressed: widget.controller.canPlayPreviousTrack
                            ? widget.controller.playPreviousTrack
                            : null,
                        icon: const Icon(Icons.skip_previous_rounded),
                      ),
                      const SizedBox(width: 12),
                      StreamBuilder<PlayerState>(
                        stream: widget.controller.playerStateStream,
                        builder: (context, snap) {
                          final playing = snap.data?.playing ?? false;
                          final processing = snap.data?.processingState ??
                              ProcessingState.idle;
                          final busy = processing == ProcessingState.loading ||
                              processing == ProcessingState.buffering;
                              return FilledButton.icon(
                                onPressed: busy
                                    ? null
                                    : () async {
                                        if (playing) {
                                          await widget.controller.pause();
                                        } else {
                                          await widget.controller.play();
                                        }
                                      },
                                icon: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 180),
                                  child: busy
                                  ? const SizedBox(
                                      key: ValueKey('busy'),
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : Icon(
                                      playing
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                      key: ValueKey(playing),
                                    ),
                            ),
                            label: Text(playing ? '暂停' : '播放'),
                          );
                        },
                      ),
                      const SizedBox(width: 12),
                      IconButton.filledTonal(
                        tooltip: '下一首',
                        onPressed: widget.controller.canPlayNextTrack
                            ? widget.controller.playNextTrack
                            : null,
                        icon: const Icon(Icons.skip_next_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Card(
                    color: cs.surfaceContainer,
                    margin: EdgeInsets.zero,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline_rounded,
                              color: cs.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              np.sourcePath,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: cs.onSurfaceVariant),
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

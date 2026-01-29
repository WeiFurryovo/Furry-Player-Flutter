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

final List<String> _startupDiagnostics = <String>[];
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

class _FurryAudioHandler extends BaseAudioHandler
    with SeekHandler, QueueHandler {
  _FurryAudioHandler(this._player) {
    _sequenceStateSub = _player.sequenceStateStream.listen(_onSequenceState);
    _indexSub = _player.currentIndexStream.listen(_onIndexChanged);
    _eventSub = _player.playbackEventStream.listen(_onPlaybackEvent);
    _durationSub = _player.durationStream.listen(_onDurationChanged);

    _onSequenceState(_player.sequenceState);
    _onIndexChanged(_player.currentIndex);
    _onPlaybackEvent(_player.playbackEvent);
  }

  final AudioPlayer _player;

  StreamSubscription<SequenceState?>? _sequenceStateSub;
  StreamSubscription<int?>? _indexSub;
  StreamSubscription<PlaybackEvent>? _eventSub;
  StreamSubscription<Duration?>? _durationSub;

  List<MediaItem> _queueItems = const <MediaItem>[];
  final Map<int, Duration> _knownDurations = <int, Duration>{};
  DateTime? _lastPreviousPressedAt;
  static const Duration _previousDoublePressWindow = Duration(seconds: 2);

  void _onSequenceState(SequenceState? state) {
    final sequence = state?.effectiveSequence ?? const <IndexedAudioSource>[];
    final items = <MediaItem>[];
    for (final source in sequence) {
      final tag = source.tag;
      if (tag is MediaItem) {
        items.add(tag);
      } else {
        items.add(
          MediaItem(
            id: source.toString(),
            title: 'Unknown',
          ),
        );
      }
    }
    _queueItems = List<MediaItem>.unmodifiable(items);
    queue.add(_queueItems);

    final idx = state?.currentIndex;
    if (idx != null) _setMediaItemByIndex(idx);
  }

  void _onIndexChanged(int? idx) {
    if (idx == null) return;
    _setMediaItemByIndex(idx);
  }

  void _setMediaItemByIndex(int idx) {
    if (idx < 0 || idx >= _queueItems.length) return;
    final known = _knownDurations[idx];
    final currentDuration =
        idx == _player.currentIndex ? _player.duration : null;
    final duration = known ?? currentDuration;
    final item = duration == null
        ? _queueItems[idx]
        : _queueItems[idx].copyWith(duration: duration);
    mediaItem.add(item);
  }

  void _onDurationChanged(Duration? duration) {
    final current = mediaItem.value;
    if (current == null) return;
    if (duration == null) return;
    if (current.duration == duration) return;
    final idx = _player.currentIndex;
    if (idx != null) {
      _knownDurations[idx] = duration;
    }
    mediaItem.add(current.copyWith(duration: duration));
  }

  int _compactControlsCount() {
    var count = 1; // play/pause always present
    if (_queueItems.length > 1) {
      count += 2;
    }
    return count.clamp(1, 3);
  }

  void _onPlaybackEvent(PlaybackEvent event) {
    final hasQueueNav = _queueItems.length > 1;
    final processingState =
        (event.processingState == ProcessingState.completed && !_player.hasNext)
            ? AudioProcessingState.ready
            : const <ProcessingState, AudioProcessingState>{
                ProcessingState.idle: AudioProcessingState.idle,
                ProcessingState.loading: AudioProcessingState.loading,
                ProcessingState.buffering: AudioProcessingState.buffering,
                ProcessingState.ready: AudioProcessingState.ready,
                ProcessingState.completed: AudioProcessingState.completed,
              }[event.processingState]!;
    playbackState.add(
      playbackState.value.copyWith(
        controls: <MediaControl>[
          if (hasQueueNav) MediaControl.skipToPrevious,
          if (_player.playing) MediaControl.pause else MediaControl.play,
          if (hasQueueNav) MediaControl.skipToNext,
        ],
        systemActions: const <MediaAction>{
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices:
            List<int>.generate(_compactControlsCount(), (i) => i),
        processingState: processingState,
        playing: _player.playing,
        // Use the live position rather than `PlaybackEvent.updatePosition`.
        // `updatePosition` in just_audio events may remain stale between events,
        // and since `audio_service` refreshes `updateTime` on each state update,
        // stale `updatePosition` can make the system seekbar jump back to 0.
        updatePosition: _player.position,
        bufferedPosition: event.bufferedPosition,
        speed: _player.speed,
        queueIndex: event.currentIndex,
      ),
    );
  }

  @override
  Future<void> play() async {
    final duration = _player.duration;
    final atEnd = duration != null &&
        duration > Duration.zero &&
        _player.position >= (duration - const Duration(milliseconds: 200));
    if (_player.processingState == ProcessingState.completed || atEnd) {
      await _player.seek(Duration.zero, index: _player.currentIndex);
    }
    await _player.play();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() async {
    if (_queueItems.length <= 1) return;
    if (_player.hasNext) {
      await _player.seekToNext();
    } else {
      await _player.seek(Duration.zero, index: 0);
    }
    await _player.play();
  }

  @override
  Future<void> skipToPrevious() async {
    // 1st press => restart current track
    // 2nd press within a short window => go to previous track
    final now = DateTime.now();
    final withinWindow = _lastPreviousPressedAt != null &&
        now.difference(_lastPreviousPressedAt!) <= _previousDoublePressWindow;
    _lastPreviousPressedAt = now;

    if (withinWindow && _queueItems.length > 1) {
      if (_player.hasPrevious) {
        await _player.seekToPrevious();
      } else {
        await _player.seek(Duration.zero, index: _queueItems.length - 1);
      }
      await _player.play();
      return;
    }

    await _player.seek(Duration.zero);
    await _player.play();
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> onTaskRemoved() async {
    await _player.pause();
    return super.onTaskRemoved();
  }

  Future<void> dispose() async {
    await _sequenceStateSub?.cancel();
    await _indexSub?.cancel();
    await _eventSub?.cancel();
    await _durationSub?.cancel();
  }
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

class _ExpressiveTheme {
  static TextTheme _fontFamilyWithFallback(
    TextTheme theme, {
    required String fontFamily,
    required List<String> fallback,
  }) {
    TextStyle? patch(TextStyle? style) => style?.copyWith(
          fontFamily: fontFamily,
          fontFamilyFallback: fallback,
        );

    return theme.copyWith(
      displayLarge: patch(theme.displayLarge),
      displayMedium: patch(theme.displayMedium),
      displaySmall: patch(theme.displaySmall),
      headlineLarge: patch(theme.headlineLarge),
      headlineMedium: patch(theme.headlineMedium),
      headlineSmall: patch(theme.headlineSmall),
      titleLarge: patch(theme.titleLarge),
      titleMedium: patch(theme.titleMedium),
      titleSmall: patch(theme.titleSmall),
      bodyLarge: patch(theme.bodyLarge),
      bodyMedium: patch(theme.bodyMedium),
      bodySmall: patch(theme.bodySmall),
      labelLarge: patch(theme.labelLarge),
      labelMedium: patch(theme.labelMedium),
      labelSmall: patch(theme.labelSmall),
    );
  }

  static ThemeData build(
    Brightness brightness, {
    ColorScheme? schemeOverride,
  }) {
    const seed = Color(0xFF8E7CFF);
    final scheme = schemeOverride ??
        ColorScheme.fromSeed(seedColor: seed, brightness: brightness);

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // Prefer system Google Sans when available; otherwise fall back to
      // a bundled Google Fonts alternative for consistent rendering.
      fontFamily: 'Google Sans',
    );

    final tt = _fontFamilyWithFallback(
      GoogleFonts.interTextTheme(base.textTheme),
      fontFamily: 'Google Sans',
      fallback: const <String>['Inter', 'Roboto'],
    );
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
      primaryTextTheme: _fontFamilyWithFallback(
        GoogleFonts.interTextTheme(base.primaryTextTheme),
        fontFamily: 'Google Sans',
        fallback: const <String>['Inter', 'Roboto'],
      ),
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
        backgroundColor: scheme.surfaceContainer,
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
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        shape: const RoundedRectangleBorder(borderRadius: r18),
      ),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.player});

  final AudioPlayer player;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  late final _AppController _controller;
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = _AppController(widget.player);
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

    const navBarHeight = 72.0;
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
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
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: NavigationBar(
                selectedIndex: _tabIndex,
                destinations: destinations,
                onDestinationSelected: (i) => setState(() => _tabIndex = i),
              ),
            ),
          ),
          // Spotify-like persistent player panel above the nav bar.
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(bottom: navBarHeight + bottomInset),
              child: NowPlayingPanel(controller: _controller),
            ),
          ),
        ],
      ),
    );
  }
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
  final ValueNotifier<List<File>> furryOutputs =
      ValueNotifier<List<File>>(<File>[]);
  final ValueNotifier<String> log = ValueNotifier<String>('');

  List<File>? _queue;
  int _queueIndex = -1;
  bool _androidPlaylistActive = false;
  DateTime? _lastPreviousPressedAt;
  static const Duration _previousDoublePressWindow = Duration(seconds: 2);

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
          artist = meta.subtitle;
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
                          IconButton(
                            tooltip: '复制',
                            onPressed: () async {
                              final text = controller.log.value;
                              if (text.trim().isEmpty) return;
                              await Clipboard.setData(
                                  ClipboardData(text: text));
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
                              await Clipboard.setData(
                                  ClipboardData(text: path));
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('已导出（路径已复制到剪贴板）')),
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

class NowPlayingPanel extends StatefulWidget {
  final _AppController controller;
  const NowPlayingPanel({super.key, required this.controller});

  @override
  State<NowPlayingPanel> createState() => _NowPlayingPanelState();
}

class _NowPlayingPanelState extends State<NowPlayingPanel> {
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  double _extent = 0;
  double? _dragStartExtent;

  // Tuned by eye: close to the old mini bar height.
  static const double _miniHeightPx = 96;

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
                : (_miniHeightPx / availableH).clamp(0.12, 0.28);
            const maxSize = 0.98;
            final effectiveExtent = _extent == 0 ? minSize : _extent;
            final tRaw = ((effectiveExtent - minSize) / (maxSize - minSize))
                .clamp(0.0, 1.0);
            final reveal = Curves.easeOutCubic.transform(tRaw);
            final miniOpacity =
                (1.0 - Curves.easeOutCubic.transform(tRaw)).clamp(0.0, 1.0);
            final fullOpacity =
                Curves.easeInOutCubicEmphasized.transform(reveal);
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
                        padding: EdgeInsets.only(top: topPad),
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
                              child: ListView(
                                controller: scrollController,
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
                                                Icon(Icons.info_outline_rounded,
                                                    color: cs.onSurfaceVariant),
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
        final coverTop = lerpDouble(10, 46, coverT)!;
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
                        color: cs.surfaceContainerHighest,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(28),
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
                                IconButton(
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
                          borderRadius: BorderRadius.circular(14),
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
                onPressed: controller.canPlayPreviousTrack
                    ? controller.playPreviousTrack
                    : null,
                icon: const Icon(Icons.skip_previous_rounded),
              ),
              const SizedBox(width: 14),
              Semantics(
                button: true,
                label: playing ? '暂停' : '播放',
                child: Tooltip(
                  message: playing ? '暂停' : '播放',
                  child: FilledButton(
                    onPressed: busy
                        ? null
                        : () async {
                            if (playing) {
                              await controller.pause();
                            } else {
                              await controller.play();
                            }
                          },
                    child: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(playing ? '暂停' : '播放'),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              IconButton.filledTonal(
                tooltip: '下一首',
                onPressed: controller.canPlayNextTrack
                    ? controller.playNextTrack
                    : null,
                icon: const Icon(Icons.skip_next_rounded),
              ),
            ],
          );
        },
      ),
    );
  }
}

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

/// Android 后台播放 / 通知栏（锁屏）控制的适配层。
///
/// 该类把 `just_audio` 的队列/播放状态同步到 `audio_service` 的 `AudioHandler`：
/// - 系统媒体中心可显示当前曲目、进度、播放状态
/// - 系统按钮（播放/暂停/上一首/下一首）能回调到播放器
///
/// 重要：Flutter UI 的业务逻辑仍由 `_AppController` 驱动；此 handler 只负责系统集成。
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
    const r20 = BorderRadius.all(Radius.circular(20));
    const r16 = BorderRadius.all(Radius.circular(16));

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
        scrolledUnderElevation: 1,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
      ),
      listTileTheme: ListTileThemeData(
        shape: const RoundedRectangleBorder(borderRadius: r20),
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.secondaryContainer,
        indicatorShape: const StadiumBorder(),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLow,
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
      searchBarTheme: SearchBarThemeData(
        shape: const WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: r24),
        ),
        elevation: const WidgetStatePropertyAll<double>(0),
        backgroundColor: WidgetStatePropertyAll<Color>(scheme.surfaceContainer),
        textStyle: WidgetStatePropertyAll<TextStyle?>(
          textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        hintStyle: WidgetStatePropertyAll<TextStyle?>(
          textTheme.titleMedium?.copyWith(color: scheme.onSurfaceVariant),
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
        shape: const RoundedRectangleBorder(borderRadius: r16),
      ),
    );
  }
}

/// 应用主壳（3 个主 tab + 自定义底部导航 + 迷你播放器浮层）。
///
/// - 窄屏：底部导航（自定义 Expressive 样式，减少无效留白）
/// - 宽屏：NavigationRail
/// - `NowPlayingPanel` 作为底部浮层，始终保持在页面内容上方
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.player});

  final AudioPlayer player;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  late final _AppController _controller;
  int _tabIndex = 0;
  static const double _wideRailBreakpoint = 700;
  static const double _bottomNavMarginH = 16;
  static const double _bottomNavMarginBottom = 6;

  void _onRequestedTab() {
    final idx = _controller.requestedTab.value;
    if (idx == null) return;
    _controller.requestedTab.value = null;
    if (!mounted) return;
    setState(() => _tabIndex = idx.clamp(0, 2));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = _AppController(widget.player);
    _controller.requestedTab.addListener(_onRequestedTab);
    _controller.init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.requestedTab.removeListener(_onRequestedTab);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controller.appendLog('Lifecycle: $state');
  }

  @override
  Widget build(BuildContext context) {
    final navItems = <_NavItem>[
      const _NavItem(
        label: '本地',
        icon: Icons.library_music_outlined,
        selectedIcon: Icons.library_music,
      ),
      const _NavItem(
        label: '转换',
        icon: Icons.swap_horiz_outlined,
        selectedIcon: Icons.swap_horiz,
      ),
      const _NavItem(
        label: '设置',
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings,
      ),
    ];

    final navBarHeight = NavigationBarTheme.of(context).height ?? 80.0;
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return LayoutBuilder(
      builder: (context, constraints) {
        final useRail = constraints.maxWidth >= _wideRailBreakpoint;
        final pages = <Widget>[
          LibraryPage(controller: _controller),
          ConverterPage(controller: _controller),
          SettingsPage(controller: _controller),
        ];

        // Base distance from the bottom edge that the mini-player should sit above.
        // On phones, this is the bottom NavigationBar + system gesture inset.
        // On wide layouts (rail), it's just the system bottom inset.
        final bottomOverlayBaseline = useRail
            ? bottomInset
            : (navBarHeight + bottomInset + _bottomNavMarginBottom);

        Widget contentStack() {
          return Stack(
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
                    children: pages,
                  ),
                ),
              ),
              Positioned.fill(
                child: NowPlayingPanel(
                  controller: _controller,
                  bottomOverlayBaseline: bottomOverlayBaseline,
                ),
              ),
            ],
          );
        }

        if (useRail) {
          final railDestinations = navItems
              .map(
                (d) => NavigationRailDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selectedIcon),
                  label: Text(d.label),
                ),
              )
              .toList(growable: false);

          return Scaffold(
            body: Row(
              children: [
                SafeArea(
                  child: NavigationRail(
                    selectedIndex: _tabIndex,
                    onDestinationSelected: (i) => setState(() => _tabIndex = i),
                    labelType: NavigationRailLabelType.all,
                    destinations: railDestinations,
                  ),
                ),
                Expanded(
                  child: contentStack(),
                ),
              ],
            ),
          );
        }

        return Scaffold(
          extendBody: true,
          body: Stack(
            children: [
              contentStack(),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _ExpressiveBottomNavBar(
                  selectedIndex: _tabIndex,
                  items: navItems,
                  onDestinationSelected: (i) => setState(() => _tabIndex = i),
                  marginH: _bottomNavMarginH,
                  marginBottom: _bottomNavMarginBottom,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NavItem {
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  const _NavItem({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });
}

/// 自定义的 M3 Expressive 底部导航栏。
///
/// Flutter 的 `NavigationBar` 在某些布局下会带来较大的内部留白（尤其顶部），
/// 且 icon/label 的位置不易精细控制。这里使用自定义 layout：
/// - 保留 label（提升可读性）
/// - 不下移 icon（保持稳定的视觉锚点）
/// - 通过轻微阴影与 `surfaceContainer` 强化“悬浮”层级
class _ExpressiveBottomNavBar extends StatelessWidget {
  const _ExpressiveBottomNavBar({
    required this.selectedIndex,
    required this.items,
    required this.onDestinationSelected,
    required this.marginH,
    required this.marginBottom,
  });

  final int selectedIndex;
  final List<_NavItem> items;
  final ValueChanged<int> onDestinationSelected;
  final double marginH;
  final double marginBottom;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final navBarHeight = NavigationBarTheme.of(context).height ?? 80.0;
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final navTheme = NavigationBarTheme.of(context);
    final indicatorColor = navTheme.indicatorColor ?? cs.secondaryContainer;
    final labelStyle = Theme.of(context).textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: cs.onSurfaceVariant,
        );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        marginH,
        0,
        marginH,
        marginBottom + bottomInset,
      ),
      child: Material(
        elevation: 2,
        color: cs.surfaceContainer,
        surfaceTintColor: cs.surfaceTint,
        shadowColor: _withOpacityCompat(cs.shadow, 0.22),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: BorderSide(color: _withOpacityCompat(cs.outlineVariant, 0.55)),
        ),
        clipBehavior: Clip.antiAlias,
        // Custom layout to reduce only the top in-bar whitespace while keeping
        // icon positions stable and showing labels.
        child: SizedBox(
          height: navBarHeight,
          child: Padding(
            // Reduce only the top in-bar whitespace (circled by the user) while
            // keeping icon positions from shifting downward and still showing
            // labels.
            // Keep symmetric vertical padding (top == bottom).
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Row(
              children: [
                for (var i = 0; i < items.length; i++)
                  Expanded(
                    child: _NavItemButton(
                      selected: i == selectedIndex,
                      item: items[i],
                      indicatorColor: indicatorColor,
                      labelStyle: labelStyle,
                      onTap: () => onDestinationSelected(i),
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

class _NavItemButton extends StatelessWidget {
  const _NavItemButton({
    required this.selected,
    required this.item,
    required this.indicatorColor,
    required this.labelStyle,
    required this.onTap,
  });

  final bool selected;
  final _NavItem item;
  final Color indicatorColor;
  final TextStyle? labelStyle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final iconColor = selected ? cs.onSecondaryContainer : cs.onSurfaceVariant;
    final textColor = selected ? cs.onSurface : cs.onSurfaceVariant;
    final effectiveLabelStyle =
        (labelStyle ?? Theme.of(context).textTheme.labelMedium)?.copyWith(
      color: textColor,
    );

    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
          decoration: BoxDecoration(
            color: selected ? indicatorColor : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(selected ? item.selectedIcon : item.icon, color: iconColor),
              const SizedBox(height: 6),
              Text(item.label, style: effectiveLabelStyle),
            ],
          ),
        ),
      ),
    );
  }
}

/// 给 `CustomScrollView` 的底部留出空间，避免内容被：
/// - 底部导航栏
/// - 迷你播放器
/// 覆盖。
class _BottomOverlaySpacer extends StatelessWidget {
  const _BottomOverlaySpacer({required this.controller});

  final _AppController controller;
  static const double _extra = 16;
  static const double _wideRailBreakpoint = 700;
  static const double _miniHeight = NowPlayingPanel.miniHeightPx;
  static const double _miniGap = NowPlayingPanel.miniGapPx;
  static const double _bottomNavMarginBottom =
      _AppShellState._bottomNavMarginBottom;

  @override
  Widget build(BuildContext context) {
    final navBarHeight = NavigationBarTheme.of(context).height ?? 80.0;
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return ValueListenableBuilder<_NowPlaying?>(
      valueListenable: controller.nowPlaying,
      builder: (context, np, _) {
        final useRail =
            MediaQuery.of(context).size.width >= _wideRailBreakpoint;
        final bottomBaseline = useRail
            ? bottomInset
            : (navBarHeight + bottomInset + _bottomNavMarginBottom);
        // Keep content scrollable above the overlays:
        // - bottom navigation bar (plus system inset)
        // - mini player (only when active)
        final mini = (np == null) ? 0.0 : _miniHeight;
        return SizedBox(height: bottomBaseline + mini + _miniGap + _extra);
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
  final Map<String, Future<_MetaPreview>> _metaPreviewCache =
      <String, Future<_MetaPreview>>{};
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
        artist: artist,
        album: album,
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

  Future<_LibraryIndex> buildLibraryIndex(List<File> files) async {
    final tracks = <_TrackEntry>[];
    for (final f in files) {
      try {
        final meta = await getMetaPreviewForFurry(f);
        final stat = await f.stat();
        tracks.add(
          _TrackEntry(
            file: f,
            meta: meta,
            modified: stat.modified,
            bytes: stat.size,
          ),
        );
      } catch (e, st) {
        appendLog('Index meta failed: ${f.path}: $e\n$st');
        final stat = await f.stat();
        tracks.add(
          _TrackEntry(
            file: f,
            meta: _MetaPreview(
              title: p.basename(f.path),
              artist: '',
              album: '',
              subtitle: '',
              artUri: null,
              coverBytesLen: null,
            ),
            modified: stat.modified,
            bytes: stat.size,
          ),
        );
      }
    }

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

    return _LibraryIndex(tracks: tracks, albums: albums, artists: artists);
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
  _LibraryView _view = _LibraryView.tracks;
  _LibrarySort _sort = _LibrarySort.recent;
  bool _ascending = false;
  bool _onlyWithCover = false;

  int? _lastFilesHash;
  Future<_LibraryIndex>? _indexFuture;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<_LibraryIndex> _getIndexFuture(
      _AppController controller, List<File> files) {
    final hash =
        Object.hash(files.length, Object.hashAll(files.map((f) => f.path)));
    if (_indexFuture == null || _lastFilesHash != hash) {
      _lastFilesHash = hash;
      _indexFuture = controller.buildLibraryIndex(files);
    }
    return _indexFuture!;
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
                final q = searchController.text.trim().toLowerCase();
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
                      final suggestions = <_TrackEntry>[];
                      if (q.isNotEmpty) {
                        for (final t in tracks) {
                          if (_matchesQuery(t, q)) suggestions.add(t);
                          if (suggestions.length >= 8) break;
                        }
                      }

                      if (q.isEmpty) {
                        final hot = tracks.take(6).toList(growable: false);
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const ListTile(
                              leading: Icon(Icons.auto_awesome_rounded),
                              title: Text('建议'),
                              subtitle: Text('试试搜索歌名、专辑或歌手'),
                            ),
                            for (final t in hot)
                              ListTile(
                                leading: _CoverThumb(artUri: t.meta.artUri),
                                title: Text(t.displayTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                subtitle: Text(
                                  t.meta.subtitle.isEmpty
                                      ? '本地文件'
                                      : t.meta.subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () {
                                  searchController.closeView(t.displayTitle);
                                  setState(() => _query = t.displayTitle);
                                },
                              ),
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
                          for (final t in suggestions)
                            ListTile(
                              leading: _CoverThumb(artUri: t.meta.artUri),
                              title: Text(t.displayTitle,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                t.meta.subtitle.isEmpty
                                    ? '本地文件'
                                    : t.meta.subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(Icons.north_west_rounded),
                              onTap: () {
                                searchController.closeView(t.displayTitle);
                                setState(() => _query = t.displayTitle);
                              },
                            ),
                        ],
                      );
                    },
                  ),
                ];
              },
              onChanged: (v) => setState(() => _query = v.trim()),
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
                  final tracks = idx.tracks
                      .where((t) => (!_onlyWithCover || t.meta.artUri != null))
                      .where((t) => _matchesQuery(t, q))
                      .toList(growable: false);

                  int compareTrack(_TrackEntry a, _TrackEntry b) {
                    int r;
                    switch (_sort) {
                      case _LibrarySort.recent:
                        r = b.modified.compareTo(a.modified);
                        break;
                      case _LibrarySort.title:
                        r = a.displayTitle.compareTo(b.displayTitle);
                        break;
                      case _LibrarySort.artist:
                        r = a.meta.artist.compareTo(b.meta.artist);
                        break;
                      case _LibrarySort.album:
                        r = a.meta.album.compareTo(b.meta.album);
                        break;
                      case _LibrarySort.size:
                        r = b.bytes.compareTo(a.bytes);
                        break;
                    }
                    return _ascending ? -r : r;
                  }

                  final sortedTracks = tracks.toList()..sort(compareTrack);

                  switch (_view) {
                    case _LibraryView.tracks:
                      return _TracksSliver(
                        controller: controller,
                        tracks: sortedTracks,
                        bytesFmt: _fmtBytes,
                      );
                    case _LibraryView.albums:
                      final albums = idx.albums.where((a) {
                        if (!_onlyWithCover) return true;
                        return a.artUri != null;
                      }).where((a) {
                        if (q.isEmpty) return true;
                        return a.title.toLowerCase().contains(q) ||
                            a.subtitle.toLowerCase().contains(q);
                      }).toList(growable: false);
                      return _AlbumsSliver(
                          controller: controller, albums: albums);
                    case _LibraryView.artists:
                      final artists = idx.artists.where((a) {
                        if (!_onlyWithCover) return true;
                        return a.artUri != null;
                      }).where((a) {
                        if (q.isEmpty) return true;
                        return a.title.toLowerCase().contains(q);
                      }).toList(growable: false);
                      return _ArtistsSliver(
                          controller: controller, artists: artists);
                    case _LibraryView.queue:
                      return _QueueSliver(controller: controller);
                  }
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

    const outerRadius = BorderRadius.all(Radius.circular(28));
    final dividerColor = _withOpacityCompat(cs.outlineVariant, 0.28);

    Widget tile({
      required _LibraryView v,
      required IconData icon,
      required String title,
      required String subtitle,
      required bool first,
      required bool last,
    }) {
      final selected = value == v;
      final fg = selected ? cs.onSecondaryContainer : cs.onSurface;
      final iconColor = selected ? cs.onSecondaryContainer : cs.primary;
      final subtitleColor = selected
          ? _withOpacityCompat(cs.onSecondaryContainer, 0.78)
          : cs.onSurfaceVariant;

      return ListTile(
        onTap: () => onChanged(v),
        selected: selected,
        selectedTileColor: cs.secondaryContainer,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        minVerticalPadding: 14,
        leading: Icon(icon, color: iconColor),
        title: Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: fg,
              ),
        ),
        subtitle: Text(
          subtitle,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: subtitleColor,
              ),
        ),
        trailing: Icon(
          Icons.chevron_right_rounded,
          color: selected
              ? _withOpacityCompat(cs.onSecondaryContainer, 0.82)
              : cs.onSurfaceVariant,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.only(
            topLeft: first ? outerRadius.topLeft : Radius.zero,
            topRight: first ? outerRadius.topRight : Radius.zero,
            bottomLeft: last ? outerRadius.bottomLeft : Radius.zero,
            bottomRight: last ? outerRadius.bottomRight : Radius.zero,
          ),
        ),
      );
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: cs.surfaceContainer,
      shape: const RoundedRectangleBorder(borderRadius: outerRadius),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          tile(
            v: _LibraryView.tracks,
            icon: Icons.music_note_rounded,
            title: '歌曲',
            subtitle: '按单曲浏览与播放',
            first: true,
            last: false,
          ),
          Divider(height: 1, thickness: 1, color: dividerColor, indent: 72),
          tile(
            v: _LibraryView.albums,
            icon: Icons.album_rounded,
            title: '专辑',
            subtitle: '按专辑归类，沉浸式封面网格',
            first: false,
            last: false,
          ),
          Divider(height: 1, thickness: 1, color: dividerColor, indent: 72),
          tile(
            v: _LibraryView.artists,
            icon: Icons.person_rounded,
            title: '歌手',
            subtitle: '按歌手整理，快速定位作品',
            first: false,
            last: false,
          ),
          Divider(height: 1, thickness: 1, color: dividerColor, indent: 72),
          tile(
            v: _LibraryView.queue,
            icon: Icons.queue_music_rounded,
            title: '队列',
            subtitle: '管理接下来要播放的内容',
            first: false,
            last: true,
          ),
        ],
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
  static const double miniHeightPx = 88;

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
  static const double miniHeightPx = 88;
  static const double miniGapPx = 10;

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
        final showMore = constraints.maxWidth >= 420;
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
              borderRadius: BorderRadius.circular(28),
              side: BorderSide(
                  color: _withOpacityCompat(cs.outlineVariant, 0.55)),
            ),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              height: NowPlayingPanel.miniHeightPx,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: onOpen,
                        borderRadius: BorderRadius.circular(22),
                        child: Row(
                          children: [
                            Hero(
                              tag: heroTag,
                              child: _CoverThumb(artUri: np.artUri),
                            ),
                            const SizedBox(width: 12),
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
                                  const SizedBox(height: 8),
                                  _MiniProgress(controller: controller),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconButton.filledTonal(
                      tooltip: '上一首',
                      onPressed: controller.canPlayPreviousTrack
                          ? () {
                              HapticFeedback.selectionClick();
                              controller.playPreviousTrack();
                            }
                          : null,
                      icon: const Icon(Icons.skip_previous_rounded),
                    ),
                    const SizedBox(width: 8),
                    _MiniPlayPause(controller: controller),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: '下一首',
                      onPressed: controller.canPlayNextTrack
                          ? () {
                              HapticFeedback.selectionClick();
                              controller.playNextTrack();
                            }
                          : null,
                      icon: const Icon(Icons.skip_next_rounded),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: '展开',
                      onPressed: () {
                        HapticFeedback.selectionClick();
                        onOpen();
                      },
                      icon: const Icon(Icons.keyboard_arrow_up_rounded),
                    ),
                    if (showMore) ...[
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        tooltip: '更多',
                        onPressed: () {
                          HapticFeedback.selectionClick();
                          _showNowPlayingActionsSheet(
                            context: context,
                            controller: controller,
                            np: np,
                          );
                        },
                        icon: const Icon(Icons.more_horiz_rounded),
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
  const _MiniPlayPause({required this.controller});
  final _AppController controller;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlayerState>(
      stream: controller.playerStateStream,
      builder: (context, snap) {
        final playing = snap.data?.playing ?? false;
        final processing = snap.data?.processingState ?? ProcessingState.idle;
        final busy = processing == ProcessingState.loading ||
            processing == ProcessingState.buffering;
        return IconButton.filled(
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
                ? const SizedBox(
                    key: ValueKey<String>('busy'),
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    key: ValueKey<bool>(playing),
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
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

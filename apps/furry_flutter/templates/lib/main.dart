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
import 'dart:collection';
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
part 'src/library_page.dart';
part 'src/library_page_state.dart';
part 'src/library_page_filter_state.dart';
part 'src/library_page_widgets.dart';
part 'src/library_page_logic.dart';
part 'src/now_playing_panel.dart';
part 'src/settings_page.dart';
part 'src/converter_page.dart';
part 'src/media_models.dart';
part 'src/app_controller.dart';

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

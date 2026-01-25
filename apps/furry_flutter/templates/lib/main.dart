import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'furry_api.dart';
import 'furry_api_selector.dart';
import 'in_memory_audio_source.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
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

class _AppShellState extends State<AppShell> {
  late final _controller = _AppController();
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    _controller.init();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final destinations = <NavigationDestination>[
      const NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: '本地'),
      const NavigationDestination(icon: Icon(Icons.swap_horiz_outlined), selectedIcon: Icon(Icons.swap_horiz), label: '转换'),
      const NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: '设置'),
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

  final ValueNotifier<_NowPlaying?> nowPlaying = ValueNotifier<_NowPlaying?>(null);
  final ValueNotifier<List<File>> furryOutputs = ValueNotifier<List<File>>(<File>[]);
  final ValueNotifier<String> log = ValueNotifier<String>('');

  int paddingKb = 0;

  File? pickedForPack;
  String? pickedForPackName;

  Future<void> init() async {
    try {
      await api.init();
      await refreshOutputs();
      appendLog('Native init ok');
    } catch (e) {
      appendLog('Native init failed: $e');
    }
  }

  void dispose() {
    player.dispose();
    nowPlaying.dispose();
    furryOutputs.dispose();
    log.dispose();
  }

  void appendLog(String msg) {
    log.value = '${DateTime.now().toIso8601String()}  $msg\n${log.value}';
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
    final out = File(p.join(tmp.path, 'import_${DateTime.now().millisecondsSinceEpoch}_$safeName'));
    await out.writeAsBytes(bytes, flush: true);
    return out;
  }

  Future<void> pickForPack() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      withData: true,
    );
    final file = result?.files.single;
    if (file == null) return;
    if (file.bytes == null) {
      appendLog('Pick failed: bytes is null (try a different picker / storage)');
      return;
    }
    final tmp = await writePickedBytesToTemp(filenameHint: file.name, bytes: file.bytes!);
    pickedForPack = tmp;
    pickedForPackName = file.name;
    appendLog('Picked for pack: ${file.name} (${file.size} bytes)');
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
      withData: true,
    );
    final file = result?.files.single;
    if (file == null) return null;
    if (file.bytes == null) {
      appendLog('Pick failed: bytes is null (try a different picker / storage)');
      return null;
    }
    final tmp = await writePickedBytesToTemp(filenameHint: file.name, bytes: file.bytes!);
    appendLog('Picked for play: ${file.name} (${file.size} bytes)');
    return tmp;
  }

  String? _mimeFromExt(String ext) {
    switch (ext.toLowerCase()) {
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'ogg':
        return 'audio/ogg';
      case 'flac':
        return 'audio/flac';
      default:
        return null;
    }
  }

  Future<void> playFile({
    required File file,
    String? displayName,
  }) async {
    final name = displayName ?? p.basename(file.path);
    try {
      final ext = p.extension(name).toLowerCase();
      final isFurry = ext == '.furry' || await api.isValidFurryFile(filePath: file.path);

      if (isFurry) {
        appendLog('Unpacking .furry to bytes…');
        final originalExt = await api.getOriginalFormat(filePath: file.path);
        final bytes = await api.unpackFromFurryToBytes(inputPath: file.path);
        if (bytes == null) {
          appendLog('Unpack failed: null');
          return;
        }
        await player.setAudioSource(
          InMemoryAudioSource(bytes: bytes, contentType: _mimeFromExt(originalExt)),
        );
        await player.play();
        nowPlaying.value = _NowPlaying(title: name, subtitle: '.furry → $originalExt', sourcePath: file.path);
        appendLog('Playing (.furry → $originalExt), ${bytes.length} bytes');
      } else {
        await player.setAudioSource(AudioSource.uri(file.uri));
        await player.play();
        nowPlaying.value = _NowPlaying(title: name, subtitle: '本地文件', sourcePath: file.path);
        appendLog('Playing (raw): $name');
      }
    } catch (e) {
      appendLog('Play failed: $e');
    }
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
}

class _NowPlaying {
  final String title;
  final String subtitle;
  final String sourcePath;

  _NowPlaying({
    required this.title,
    required this.subtitle,
    required this.sourcePath,
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
                return p.basename(f.path).toLowerCase().contains(_query.toLowerCase());
              }).toList();

              if (filtered.isEmpty) {
                return const Text('暂无 .furry 输出文件（去“转换”页打包试试）');
              }

              return Column(
                children: [
                  for (final f in filtered)
                    ListTile(
                      leading: const Icon(Icons.library_music),
                      title: Text(p.basename(f.path)),
                      subtitle: Text('${_fmtBytes(f.lengthSync())} · ${f.lastModifiedSync().toLocal()}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => controller.playFile(file: f, displayName: p.basename(f.path)),
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
                      const Text('打包（音频 → .furry）', style: TextStyle(fontWeight: FontWeight.w700)),
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
                  Text(controller.pickedForPackName == null ? '未选择输入文件' : '输入：${controller.pickedForPackName}'),
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
                          onChanged: (v) => setState(() => controller.paddingKb = v.round()),
                        ),
                      ),
                    ],
                  ),
                  Text('当前 padding: ${controller.paddingKb} KB', style: Theme.of(context).textTheme.bodySmall),
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
                      const Text('播放（文件或 .furry）', style: TextStyle(fontWeight: FontWeight.w700)),
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
                  const Text('诊断日志', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  ValueListenableBuilder<String>(
                    valueListenable: controller.log,
                    builder: (context, log, _) {
                      return SelectableText(
                        log.isEmpty ? '(empty)' : log,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
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
            onTap: () => _showNowPlaying(context, controller, np),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.music_note, color: cs.onPrimaryContainer),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(np.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text(np.subtitle, style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  StreamBuilder<PlayerState>(
                    stream: controller.player.playerStateStream,
                    builder: (context, snap) {
                      final playing = snap.data?.playing ?? false;
                      final processing = snap.data?.processingState ?? ProcessingState.idle;
                      final busy = processing == ProcessingState.loading || processing == ProcessingState.buffering;
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
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : Icon(playing ? Icons.pause : Icons.play_arrow),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showNowPlaying(BuildContext context, _AppController controller, _NowPlaying np) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => NowPlayingSheet(controller: controller, np: np),
    );
  }
}

class NowPlayingSheet extends StatelessWidget {
  final _AppController controller;
  final _NowPlaying np;
  const NowPlayingSheet({super.key, required this.controller, required this.np});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
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
                  child: Icon(Icons.album, size: 96, color: cs.primary),
                ),
              ),
              const SizedBox(height: 16),
              Text(np.title, style: Theme.of(context).textTheme.titleLarge, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Text(np.subtitle, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 16),
              StreamBuilder<Duration?>(
                stream: controller.player.durationStream,
                builder: (context, durSnap) {
                  final duration = durSnap.data ?? Duration.zero;
                  return StreamBuilder<Duration>(
                    stream: controller.player.positionStream,
                    builder: (context, posSnap) {
                      final position = posSnap.data ?? Duration.zero;
                      final max = duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 1.0;
                      final value = position.inMilliseconds.clamp(0, max.toInt()).toDouble();
                      return Column(
                        children: [
                          Slider(
                            value: value,
                            max: max,
                            onChanged: (v) => controller.player.seek(Duration(milliseconds: v.round())),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(controller._fmt(position), style: Theme.of(context).textTheme.bodySmall),
                              Text(controller._fmt(duration), style: Theme.of(context).textTheme.bodySmall),
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
                    tooltip: '停止',
                    onPressed: controller.stop,
                    icon: const Icon(Icons.stop),
                  ),
                  const SizedBox(width: 12),
                  StreamBuilder<PlayerState>(
                    stream: controller.player.playerStateStream,
                    builder: (context, snap) {
                      final playing = snap.data?.playing ?? false;
                      final processing = snap.data?.processingState ?? ProcessingState.idle;
                      final busy = processing == ProcessingState.loading || processing == ProcessingState.buffering;
                      return FilledButton.tonalIcon(
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
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : Icon(playing ? Icons.pause : Icons.play_arrow),
                        label: Text(playing ? '暂停' : '播放'),
                      );
                    },
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
  }
}

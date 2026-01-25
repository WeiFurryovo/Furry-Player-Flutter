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
    return MaterialApp(
      title: 'Furry Player (Flutter)',
      theme: ThemeData.dark(useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final AudioPlayer _player = AudioPlayer();
  late final FurryApi _api = createFurryApi();

  String _log = '';
  int _paddingKb = 0;

  File? _pickedForPack;
  String? _pickedForPackName;

  File? _pickedForPlay;
  String? _pickedForPlayName;

  List<FileSystemEntity> _outputs = const [];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await _api.init();
      await _refreshOutputs();
      _appendLog('Native init ok');
    } catch (e) {
      _appendLog('Native init failed: $e');
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  void _appendLog(String msg) {
    setState(() {
      _log = '${DateTime.now().toIso8601String()}  $msg\n$_log';
    });
  }

  Future<Directory> _outputsDir() async {
    final doc = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(doc.path, 'outputs'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _writePickedBytesToTemp({
    required String filenameHint,
    required Uint8List bytes,
  }) async {
    final tmp = await getTemporaryDirectory();
    final safeName = filenameHint.isEmpty ? 'input.bin' : filenameHint;
    final out = File(p.join(tmp.path, 'import_${DateTime.now().millisecondsSinceEpoch}_$safeName'));
    await out.writeAsBytes(bytes, flush: true);
    return out;
  }

  Future<void> _pickForPack() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      withData: true,
    );
    final file = result?.files.single;
    if (file == null) return;
    if (file.bytes == null) {
      _appendLog('Pick failed: bytes is null (try a different picker / storage)');
      return;
    }
    final tmp = await _writePickedBytesToTemp(filenameHint: file.name, bytes: file.bytes!);
    setState(() {
      _pickedForPack = tmp;
      _pickedForPackName = file.name;
    });
    _appendLog('Picked for pack: ${file.name} (${file.size} bytes)');
  }

  Future<void> _startPack() async {
    final input = _pickedForPack;
    if (input == null) {
      _appendLog('No pack input selected');
      return;
    }

    final outDir = await _outputsDir();
    final base = p.basenameWithoutExtension(_pickedForPackName ?? input.path);
    final outPath = p.join(outDir.path, '$base.furry');

    _appendLog('Packing…');
    final rc = await _api.packToFurry(
      inputPath: input.path,
      outputPath: outPath,
      paddingKb: _paddingKb,
    );
    if (rc == 0) {
      _appendLog('Pack ok: ${p.basename(outPath)}');
      await _refreshOutputs();
    } else {
      _appendLog('Pack failed: rc=$rc');
    }
  }

  Future<void> _refreshOutputs() async {
    final outDir = await _outputsDir();
    final files = outDir
        .listSync()
        .whereType<File>()
        .where((f) => p.extension(f.path).toLowerCase() == '.furry')
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    setState(() => _outputs = files);
  }

  Future<void> _pickForPlay() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['mp3', 'wav', 'ogg', 'flac', 'furry'],
      withData: true,
    );
    final file = result?.files.single;
    if (file == null) return;
    if (file.bytes == null) {
      _appendLog('Pick failed: bytes is null (try a different picker / storage)');
      return;
    }
    final tmp = await _writePickedBytesToTemp(filenameHint: file.name, bytes: file.bytes!);
    setState(() {
      _pickedForPlay = tmp;
      _pickedForPlayName = file.name;
    });
    _appendLog('Picked for play: ${file.name} (${file.size} bytes)');
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

  Future<void> _startPlaySelected() async {
    final input = _pickedForPlay;
    if (input == null) {
      _appendLog('No play input selected');
      return;
    }

    final isFurry = p.extension(_pickedForPlayName ?? input.path).toLowerCase() == '.furry' ||
        await _api.isValidFurryFile(filePath: input.path);

    if (isFurry) {
      _appendLog('Unpacking .furry to bytes…');
      final ext = await _api.getOriginalFormat(filePath: input.path);
      final bytes = await _api.unpackFromFurryToBytes(inputPath: input.path);
      if (bytes == null) {
        _appendLog('Unpack failed: null');
        return;
      }
      await _player.setAudioSource(
        InMemoryAudioSource(
          bytes: bytes,
          contentType: _mimeFromExt(ext),
        ),
      );
      await _player.play();
      _appendLog('Playing (.furry → $ext), ${bytes.length} bytes');
    } else {
      await _player.setAudioSource(AudioSource.uri(input.uri));
      await _player.play();
      _appendLog('Playing (raw): ${_pickedForPlayName ?? p.basename(input.path)}');
    }
  }

  Future<void> _stop() async {
    await _player.stop();
    _appendLog('Stopped');
  }

  String _fmt(Duration? d) {
    if (d == null) return '--:--';
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Furry Player (Flutter/Android)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('打包（音频 → .furry）', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton(onPressed: _pickForPack, child: const Text('选择音频')),
                      FilledButton(onPressed: _startPack, child: const Text('开始打包')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(_pickedForPackName == null ? '未选择输入文件' : '输入：$_pickedForPackName'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Padding(KB)'),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Slider(
                          value: _paddingKb.toDouble(),
                          min: 0,
                          max: 256,
                          divisions: 256,
                          label: '$_paddingKb',
                          onChanged: (v) => setState(() => _paddingKb = v.round()),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('输出文件（.furry）', style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                      TextButton(onPressed: _refreshOutputs, child: const Text('刷新')),
                    ],
                  ),
                  if (_outputs.isEmpty) const Text('（暂无）'),
                  for (final f in _outputs.whereType<File>())
                    ListTile(
                      dense: true,
                      title: Text(p.basename(f.path)),
                      subtitle: Text('${f.lengthSync()} bytes'),
                      onTap: () async {
                        setState(() {
                          _pickedForPlay = f;
                          _pickedForPlayName = p.basename(f.path);
                        });
                        _appendLog('Selected output for play: ${p.basename(f.path)}');
                      },
                    ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('播放器', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton(onPressed: _pickForPlay, child: const Text('选择音频/.furry')),
                      FilledButton(onPressed: _startPlaySelected, child: const Text('播放')),
                      OutlinedButton(
                        onPressed: () => _player.pause(),
                        child: const Text('暂停'),
                      ),
                      OutlinedButton(
                        onPressed: () => _player.play(),
                        child: const Text('继续'),
                      ),
                      TextButton(onPressed: _stop, child: const Text('停止')),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(_pickedForPlayName == null ? '未选择播放文件' : '播放：$_pickedForPlayName'),
                  const SizedBox(height: 8),
                  StreamBuilder<Duration>(
                    stream: _player.positionStream,
                    builder: (context, snapPos) {
                      return StreamBuilder<Duration?>(
                        stream: _player.durationStream,
                        builder: (context, snapDur) {
                          final pos = snapPos.data ?? Duration.zero;
                          final dur = snapDur.data ?? Duration.zero;
                          final max =
                              (dur.inMilliseconds.toDouble()).clamp(0.0, double.infinity) as double;
                          final value = (pos.inMilliseconds.toDouble()).clamp(0.0, max) as double;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Slider(
                                value: value.isNaN ? 0.0 : value,
                                max: max == 0 ? 1 : max,
                                onChanged: (v) async {
                                  await _player.seek(Duration(milliseconds: v.round()));
                                },
                              ),
                              Text('${_fmt(pos)} / ${_fmt(dur)}'),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('日志', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  SelectableText(_log.isEmpty ? '（空）' : _log),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

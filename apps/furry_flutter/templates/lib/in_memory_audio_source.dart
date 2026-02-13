// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

/// 将一段内存字节作为音频源提供给 `just_audio`。
///
/// 用途：
/// - `.furry` 解包到内存后直接播放（无需落盘）
/// - 适合体积中等的音频；大文件建议落盘再用 FileAudioSource
///
/// 实现细节：
/// - `request(start, end)` 需要支持分段读取；播放器会按需拉取范围
/// - 这里用 `Uint8List.sublistView` 避免多余拷贝
class InMemoryAudioSource extends StreamAudioSource {
  final Uint8List bytes;
  final String? contentType;

  InMemoryAudioSource({
    required this.bytes,
    this.contentType,
    super.tag,
  });

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final int effectiveStart = start ?? 0;
    final int effectiveEnd =
        end == null ? bytes.length : end.clamp(0, bytes.length);
    final view = Uint8List.sublistView(bytes, effectiveStart, effectiveEnd);

    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: view.length,
      offset: effectiveStart,
      contentType: contentType ?? 'audio/mpeg',
      stream: Stream<Uint8List>.value(view),
    );
  }
}

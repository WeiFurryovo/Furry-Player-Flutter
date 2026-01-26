import 'dart:async';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

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
    final int effectiveEnd = end == null ? bytes.length : end.clamp(0, bytes.length);
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

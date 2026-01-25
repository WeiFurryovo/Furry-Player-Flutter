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
    final int effectiveEnd = end ?? bytes.length;
    final chunk = bytes.sublist(effectiveStart, effectiveEnd);

    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: chunk.length,
      offset: effectiveStart,
      contentType: contentType ?? 'audio/mpeg',
      stream: Stream<Uint8List>.value(chunk),
    );
  }
}

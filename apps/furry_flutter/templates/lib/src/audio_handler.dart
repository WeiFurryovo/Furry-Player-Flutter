part of '../main.dart';

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

part of '../main.dart';

extension _AppControllerQueueExtension on _AppController {
  bool get canPlayPreviousTrack => _queue != null && _queue!.length > 1;
  bool get canPlayNextTrack => _queue != null && _queue!.length > 1;

  Future<void> playPreviousTrack() async {
    final queue = _queue;
    if (queue == null) return;

    final playToken = _beginPlayRequest();

    final now = DateTime.now();
    final withinWindow = _lastPreviousPressedAt != null &&
        now.difference(_lastPreviousPressedAt!) <=
            _AppController._previousDoublePressWindow;
    _lastPreviousPressedAt = now;

    if (!withinWindow) {
      await player.seek(Duration.zero);
      if (!_isPlayRequestCurrent(playToken)) return;

      await play();
      return;
    }

    if (queue.length <= 1) return;
    final nextIdx = (_queueIndex - 1 + queue.length) % queue.length;
    if (_useAndroidPlaylistControls) {
      _queueIndex = nextIdx;
      _publishQueueStateAndAvailability();
      await player.seek(Duration.zero, index: nextIdx);
      await play();
      if (!_isPlayRequestCurrent(playToken)) return;

      await _syncNowPlayingFromQueueIndex(nextIdx);
      return;
    }
    await playFromQueue(
      queue: queue,
      index: nextIdx,
      requestToken: playToken,
    );
  }

  Future<void> playNextTrack() async {
    final queue = _queue;
    if (queue == null) return;
    if (queue.length <= 1) return;

    final playToken = _beginPlayRequest();

    final nextIdx = (_queueIndex + 1) % queue.length;
    if (_useAndroidPlaylistControls) {
      _queueIndex = nextIdx;
      _publishQueueStateAndAvailability();
      await player.seek(Duration.zero, index: nextIdx);
      await play();
      if (!_isPlayRequestCurrent(playToken)) return;

      await _syncNowPlayingFromQueueIndex(nextIdx);
      return;
    }
    await playFromQueue(
      queue: queue,
      index: nextIdx,
      requestToken: playToken,
    );
  }

  Future<void> stop() async {
    _invalidatePlayRequests();
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

  Future<void> seek(Duration position) async {
    await player.seek(position);
  }

  String _fmt(Duration? d) {
    if (d == null) return '--:--';
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> playAtQueueIndex(int index) async {
    final queue = _queue;
    if (queue == null || queue.isEmpty) return;
    if (index < 0 || index >= queue.length) return;

    final playToken = _beginPlayRequest();

    if (_useAndroidPlaylistControls) {
      _queueIndex = index;
      _publishQueueStateAndAvailability();
      await player.seek(Duration.zero, index: index);
      await play();
      if (!_isPlayRequestCurrent(playToken)) return;

      await _syncNowPlayingFromQueueIndex(index);
      return;
    }

    await playFromQueue(
      queue: queue,
      index: index,
      requestToken: playToken,
    );
  }

  void clearQueue({bool keepPlaying = true}) {
    _queue = null;
    _queueIndex = -1;
    _androidPlaylistActive = false;
    _publishQueueStateAndAvailability();
    if (!keepPlaying) {
      unawaited(stop());
      nowPlaying.value = null;
    }
  }

  Future<void> removeFromQueueByPath(String path) async {
    final result = _queueMutationPlanner.removeByPath(
      queue: _queue,
      path: path,
      currentPath: nowPlaying.value?.sourcePath,
      currentIndex: _queueIndex,
    );
    if (!result.removed) return;
    if (result.cleared) {
      clearQueue(keepPlaying: false);
      return;
    }

    _queue = result.queue;
    _queueIndex = result.index;
    _publishQueueStateAndAvailability();
  }

  Future<void> enqueueFile(File file, {bool playNext = false}) async {
    final result = _queueMutationPlanner.enqueue(
      queue: _queue,
      file: file,
      currentPath: nowPlaying.value?.sourcePath,
      currentIndex: _queueIndex,
      playNext: playNext,
    );
    if (!result.inserted) return;

    _queue = result.queue;
    _queueIndex = result.index;
    _publishQueueStateAndAvailability();
  }

  void moveQueueItem(int oldIndex, int newIndex) {
    final result = _queueMutationPlanner.move(
      queue: _queue,
      oldIndex: oldIndex,
      newIndex: newIndex,
      currentPath: nowPlaying.value?.sourcePath,
      currentIndex: _queueIndex,
    );
    if (!result.moved) return;

    _queue = result.queue;
    _queueIndex = result.index;
    _publishQueueState();
  }
}

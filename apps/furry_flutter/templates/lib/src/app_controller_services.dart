part of '../main.dart';

class _EpochTokenGate {
  int _epoch = 0;

  int begin() => ++_epoch;

  bool isCurrent(int token) => token == _epoch;

  void invalidate() {
    _epoch++;
  }
}

class _QueueSnapshotBuilder {
  const _QueueSnapshotBuilder();

  _QueueState build(List<File>? queue, int index) {
    final q = queue;
    if (q == null || q.isEmpty) {
      return const _QueueState(queue: <File>[], index: -1);
    }
    return _QueueState(
      queue: List<File>.unmodifiable(q),
      index: index,
    );
  }
}

typedef _QueueRemoveResult = ({
  List<File>? queue,
  int index,
  bool removed,
  bool cleared,
});

typedef _QueueEnqueueResult = ({
  List<File> queue,
  int index,
  bool inserted,
});

typedef _QueueMoveResult = ({
  List<File>? queue,
  int index,
  bool moved,
});

class _QueueMutationPlanner {
  const _QueueMutationPlanner();

  _QueueRemoveResult removeByPath({
    required List<File>? queue,
    required String path,
    required String? currentPath,
    required int currentIndex,
  }) {
    final q = queue;
    if (q == null || q.isEmpty) {
      return (
        queue: q,
        index: currentIndex,
        removed: false,
        cleared: false,
      );
    }

    final removedIndex = q.indexWhere((file) => file.path == path);
    if (removedIndex < 0) {
      return (
        queue: q,
        index: currentIndex,
        removed: false,
        cleared: false,
      );
    }

    final nextQueue = List<File>.from(q)..removeAt(removedIndex);
    if (nextQueue.isEmpty) {
      return (
        queue: null,
        index: -1,
        removed: true,
        cleared: true,
      );
    }

    final nextIndex = currentPath != null
        ? () {
            final idx =
                nextQueue.indexWhere((file) => file.path == currentPath);
            return idx >= 0 ? idx : 0;
          }()
        : currentIndex.clamp(0, nextQueue.length - 1).toInt();

    return (
      queue: nextQueue,
      index: nextIndex,
      removed: true,
      cleared: false,
    );
  }

  _QueueEnqueueResult enqueue({
    required List<File>? queue,
    required File file,
    required String? currentPath,
    required int currentIndex,
    required bool playNext,
  }) {
    final nextQueue = queue == null ? <File>[] : List<File>.from(queue);
    var nextIndex = currentIndex;

    if (nextQueue.isEmpty && currentPath != null) {
      nextQueue.add(File(currentPath));
      nextIndex = 0;
    }

    if (nextQueue.any((entry) => entry.path == file.path)) {
      return (
        queue: nextQueue,
        index: nextIndex,
        inserted: false,
      );
    }

    if (playNext && nextQueue.isNotEmpty && nextIndex >= 0) {
      final insertIndex = (nextIndex + 1).clamp(0, nextQueue.length).toInt();
      nextQueue.insert(insertIndex, file);
    } else {
      nextQueue.add(file);
    }

    return (
      queue: nextQueue,
      index: nextIndex,
      inserted: true,
    );
  }

  _QueueMoveResult move({
    required List<File>? queue,
    required int oldIndex,
    required int newIndex,
    required String? currentPath,
    required int currentIndex,
  }) {
    final q = queue;
    if (q == null || q.isEmpty) {
      return (
        queue: q,
        index: currentIndex,
        moved: false,
      );
    }
    if (oldIndex < 0 || oldIndex >= q.length) {
      return (
        queue: q,
        index: currentIndex,
        moved: false,
      );
    }
    if (newIndex < 0 || newIndex >= q.length) {
      return (
        queue: q,
        index: currentIndex,
        moved: false,
      );
    }
    if (oldIndex == newIndex) {
      return (
        queue: q,
        index: currentIndex,
        moved: false,
      );
    }

    final nextQueue = List<File>.from(q);
    final item = nextQueue.removeAt(oldIndex);
    nextQueue.insert(newIndex, item);

    final nextIndex = currentPath != null
        ? nextQueue.indexWhere((entry) => entry.path == currentPath)
        : currentIndex.clamp(0, nextQueue.length - 1).toInt();

    return (
      queue: nextQueue,
      index: nextIndex,
      moved: true,
    );
  }
}

@visibleForTesting
class EpochTokenGateHarness {
  final _EpochTokenGate _inner = _EpochTokenGate();

  int begin() => _inner.begin();

  bool isCurrent(int token) => _inner.isCurrent(token);

  void invalidate() {
    _inner.invalidate();
  }
}

@visibleForTesting
class QueueSnapshotBuilderHarness {
  final _QueueSnapshotBuilder _inner = const _QueueSnapshotBuilder();

  _QueueState build(List<File>? queue, int index) => _inner.build(queue, index);
}

@visibleForTesting
class QueueMutationPlannerHarness {
  final _QueueMutationPlanner _inner = const _QueueMutationPlanner();

  ({List<String>? queue, int index, bool removed, bool cleared}) removeByPath({
    required List<String>? queue,
    required String path,
    required String? currentPath,
    required int currentIndex,
  }) {
    final result = _inner.removeByPath(
      queue: _toFiles(queue),
      path: path,
      currentPath: currentPath,
      currentIndex: currentIndex,
    );
    return (
      queue: _toPaths(result.queue),
      index: result.index,
      removed: result.removed,
      cleared: result.cleared,
    );
  }

  ({List<String>? queue, int index, bool inserted}) enqueue({
    required List<String>? queue,
    required String filePath,
    required String? currentPath,
    required int currentIndex,
    required bool playNext,
  }) {
    final result = _inner.enqueue(
      queue: _toFiles(queue),
      file: File(filePath),
      currentPath: currentPath,
      currentIndex: currentIndex,
      playNext: playNext,
    );
    return (
      queue: _toPaths(result.queue),
      index: result.index,
      inserted: result.inserted,
    );
  }

  ({List<String>? queue, int index, bool moved}) move({
    required List<String>? queue,
    required int oldIndex,
    required int newIndex,
    required String? currentPath,
    required int currentIndex,
  }) {
    final result = _inner.move(
      queue: _toFiles(queue),
      oldIndex: oldIndex,
      newIndex: newIndex,
      currentPath: currentPath,
      currentIndex: currentIndex,
    );
    return (
      queue: _toPaths(result.queue),
      index: result.index,
      moved: result.moved,
    );
  }

  static List<File>? _toFiles(List<String>? paths) {
    if (paths == null) return null;
    return paths.map(File.new).toList(growable: false);
  }

  static List<String>? _toPaths(List<File>? files) {
    if (files == null) return null;
    return files.map((file) => file.path).toList(growable: false);
  }
}

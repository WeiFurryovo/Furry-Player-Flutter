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

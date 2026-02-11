import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: avoid_relative_lib_imports
import '../lib/main.dart';

void main() {
  group('EpochTokenGateHarness', () {
    test('tracks latest token and invalidation', () {
      final gate = EpochTokenGateHarness();
      final first = gate.begin();
      expect(gate.isCurrent(first), isTrue);

      final second = gate.begin();
      expect(gate.isCurrent(first), isFalse);
      expect(gate.isCurrent(second), isTrue);

      gate.invalidate();
      expect(gate.isCurrent(second), isFalse);
    });
  });

  group('QueueSnapshotBuilderHarness', () {
    test('builds empty snapshot for null queue', () {
      final snapshot = QueueSnapshotBuilderHarness().build(null, 9);
      expect(snapshot.hasQueue, isFalse);
      expect(snapshot.index, -1);
      expect(snapshot.currentFile, isNull);
    });

    test('builds immutable queue snapshot with current item', () {
      final snapshot = QueueSnapshotBuilderHarness().build(
        <File>[File('/music/a.furry'), File('/music/b.furry')],
        1,
      );

      expect(snapshot.hasQueue, isTrue);
      expect(snapshot.index, 1);
      expect(snapshot.currentFile?.path, '/music/b.furry');
      expect(
        () => snapshot.queue.add(File('/music/c.furry')),
        throwsUnsupportedError,
      );
    });
  });

  group('LibraryPageSearchStateHarness', () {
    testWidgets('applyQueryImmediately trims and updates instantly',
        (tester) async {
      final state = LibraryPageSearchStateHarness();
      var changed = 0;

      state.applyQueryImmediately(
        '  Hello  ',
        onChanged: () => changed++,
      );

      expect(state.pendingQuery, 'Hello');
      expect(state.query, 'Hello');
      expect(changed, 1);
      state.dispose();
    });

    testWidgets('scheduleQueryUpdate keeps latest debounced value',
        (tester) async {
      final state = LibraryPageSearchStateHarness();
      var changed = 0;

      state.scheduleQueryUpdate(' first ', onChanged: () => changed++);
      await tester.pump(const Duration(milliseconds: 100));

      state.scheduleQueryUpdate(' second ', onChanged: () => changed++);
      await tester.pump(const Duration(milliseconds: 100));
      expect(state.query, '');

      await tester.pump(const Duration(milliseconds: 90));
      expect(state.query, 'second');
      expect(state.pendingQuery, 'second');
      expect(changed, 1);
      state.dispose();
    });
  });

  group('LibraryPageFilterStateHarness', () {
    test('applyOptions updates sorting and filter flags', () {
      final state = LibraryPageFilterStateHarness();

      state.applyOptions(
        sortIndex: 4,
        ascending: true,
        onlyWithCover: true,
      );

      expect(state.sortIndex, 4);
      expect(state.ascending, isTrue);
      expect(state.onlyWithCover, isTrue);
    });

    test('setViewIndex updates selected view', () {
      final state = LibraryPageFilterStateHarness();
      state.setViewIndex(3);
      expect(state.viewIndex, 3);
    });
  });

  group('trackMatchesQueryForTest', () {
    test('matches title, artist, album and path content', () {
      expect(
        trackMatchesQueryForTest(
          filePath: '/music/song_abc.furry',
          title: 'Night Walk',
          artist: 'Alpha',
          album: 'Moon',
          query: 'night',
        ),
        isTrue,
      );

      expect(
        trackMatchesQueryForTest(
          filePath: '/music/song_abc.furry',
          title: 'Night Walk',
          artist: 'Alpha',
          album: 'Moon',
          query: 'alpha',
        ),
        isTrue,
      );

      expect(
        trackMatchesQueryForTest(
          filePath: '/music/song_abc.furry',
          title: 'Night Walk',
          artist: 'Alpha',
          album: 'Moon',
          query: 'song_abc',
        ),
        isTrue,
      );

      expect(
        trackMatchesQueryForTest(
          filePath: '/music/song_abc.furry',
          title: 'Night Walk',
          artist: 'Alpha',
          album: 'Moon',
          query: 'unmatched',
        ),
        isFalse,
      );
    });
  });

  group('diagnosticsLogTailWindowForTest', () {
    test('handles empty and negative values safely', () {
      expect(
        diagnosticsLogTailWindowForTest(fileLength: 0, keepBytes: 256),
        (start: 0, length: 0),
      );
      expect(
        diagnosticsLogTailWindowForTest(fileLength: -20, keepBytes: 256),
        (start: 0, length: 0),
      );
      expect(
        diagnosticsLogTailWindowForTest(fileLength: 20, keepBytes: -1),
        (start: 20, length: 0),
      );
    });

    test('returns whole file when smaller than keepBytes', () {
      expect(
        diagnosticsLogTailWindowForTest(fileLength: 123, keepBytes: 256),
        (start: 0, length: 123),
      );
    });

    test('returns tail window when file is larger than keepBytes', () {
      expect(
        diagnosticsLogTailWindowForTest(fileLength: 2048, keepBytes: 512),
        (start: 1536, length: 512),
      );
    });
  });

  group('QueueMutationPlannerHarness', () {
    test('removeByPath keeps current track when still present', () {
      final planner = QueueMutationPlannerHarness();
      final result = planner.removeByPath(
        queue: <String>['/music/a.furry', '/music/b.furry', '/music/c.furry'],
        path: '/music/c.furry',
        currentPath: '/music/b.furry',
        currentIndex: 1,
      );

      expect(result.removed, isTrue);
      expect(result.cleared, isFalse);
      expect(result.queue, <String>['/music/a.furry', '/music/b.furry']);
      expect(result.index, 1);
    });

    test('removeByPath clears when queue becomes empty', () {
      final planner = QueueMutationPlannerHarness();
      final result = planner.removeByPath(
        queue: <String>['/music/only.furry'],
        path: '/music/only.furry',
        currentPath: '/music/only.furry',
        currentIndex: 0,
      );

      expect(result.removed, isTrue);
      expect(result.cleared, isTrue);
      expect(result.queue, isNull);
      expect(result.index, -1);
    });

    test('enqueue inserts next to current index when playNext', () {
      final planner = QueueMutationPlannerHarness();
      final result = planner.enqueue(
        queue: <String>['/music/a.furry', '/music/b.furry'],
        filePath: '/music/c.furry',
        currentPath: '/music/a.furry',
        currentIndex: 0,
        playNext: true,
      );

      expect(result.inserted, isTrue);
      expect(
        result.queue,
        <String>['/music/a.furry', '/music/c.furry', '/music/b.furry'],
      );
      expect(result.index, 0);
    });

    test('enqueue de-duplicates by path', () {
      final planner = QueueMutationPlannerHarness();
      final result = planner.enqueue(
        queue: <String>['/music/a.furry'],
        filePath: '/music/a.furry',
        currentPath: '/music/a.furry',
        currentIndex: 0,
        playNext: false,
      );

      expect(result.inserted, isFalse);
      expect(result.queue, <String>['/music/a.furry']);
      expect(result.index, 0);
    });

    test('move tracks current item position after reorder', () {
      final planner = QueueMutationPlannerHarness();
      final result = planner.move(
        queue: <String>['/music/a.furry', '/music/b.furry', '/music/c.furry'],
        oldIndex: 0,
        newIndex: 2,
        currentPath: '/music/b.furry',
        currentIndex: 1,
      );

      expect(result.moved, isTrue);
      expect(
        result.queue,
        <String>['/music/b.furry', '/music/c.furry', '/music/a.furry'],
      );
      expect(result.index, 0);
    });
  });
}

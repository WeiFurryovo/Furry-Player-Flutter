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
}

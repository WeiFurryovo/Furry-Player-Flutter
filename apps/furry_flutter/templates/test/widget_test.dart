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

  group('LibraryPageSuggestionHarness', () {
    test('buildSuggestions returns top 6 when query is empty', () {
      final state = LibraryPageSearchStateHarness();
      final result = state.buildSuggestions(
        tracks: List.generate(
          10,
          (index) => (
            title: 'Song $index',
            artist: 'Artist',
            album: 'Album',
            hasCover: index.isEven,
          ),
        ),
        query: '',
        sourceHash: 1,
      );

      expect(result.length, 6);
      expect(result.first, 'Song 0');
      expect(result.last, 'Song 5');
      state.dispose();
    });

    test('buildSuggestions caps at 8 and resets cache on source hash change',
        () {
      final state = LibraryPageSearchStateHarness();
      final first = state.buildSuggestions(
        tracks: List.generate(
          20,
          (index) => (
            title: 'Alpha $index',
            artist: 'Artist',
            album: 'Album',
            hasCover: true,
          ),
        ),
        query: 'alpha',
        sourceHash: 1,
      );
      expect(first.length, 8);
      expect(state.suggestionCacheSize, 1);

      final second = state.buildSuggestions(
        tracks: const <({
          String title,
          String artist,
          String album,
          bool hasCover,
        })>[
          (
            title: 'Beta One',
            artist: 'Another',
            album: 'New',
            hasCover: false,
          ),
        ],
        query: 'alpha',
        sourceHash: 2,
      );

      expect(second, isEmpty);
      expect(state.suggestionCacheSize, 1);
      state.dispose();
    });

    test('buildSuggestions keeps cache bounded to avoid memory growth', () {
      final state = LibraryPageSearchStateHarness();

      for (var i = 0; i < 64; i++) {
        state.buildSuggestions(
          tracks: const <({
            String title,
            String artist,
            String album,
            bool hasCover,
          })>[
            (
              title: 'Song',
              artist: 'Artist',
              album: 'Album',
              hasCover: false,
            ),
          ],
          query: 'q$i',
          sourceHash: 1,
        );
      }

      expect(state.suggestionCacheSize, lessThanOrEqualTo(32));
      state.dispose();
    });
  });

  group('libraryLoadingPlaceholderCountForTest', () {
    test('returns stable placeholder counts per library view', () {
      expect(libraryLoadingPlaceholderCountForTest(0), 6);
      expect(libraryLoadingPlaceholderCountForTest(1), 4);
      expect(libraryLoadingPlaceholderCountForTest(2), 5);
      expect(libraryLoadingPlaceholderCountForTest(3), 5);
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

    test('buildFilteredTrackTitles sorts by size and supports ascending toggle',
        () {
      final state = LibraryPageFilterStateHarness();
      state.applyOptions(
        sortIndex: 4,
        ascending: false,
        onlyWithCover: false,
      );

      final descending = state.buildFilteredTrackTitles(
        tracks: const <({
          String title,
          String artist,
          String album,
          int bytes,
          int modifiedMs,
          bool hasCover,
        })>[
          (
            title: 'Tiny',
            artist: 'A',
            album: 'X',
            bytes: 1,
            modifiedMs: 1,
            hasCover: false,
          ),
          (
            title: 'Huge',
            artist: 'B',
            album: 'X',
            bytes: 9,
            modifiedMs: 2,
            hasCover: true,
          ),
          (
            title: 'Medium',
            artist: 'C',
            album: 'X',
            bytes: 5,
            modifiedMs: 3,
            hasCover: true,
          ),
        ],
      );
      expect(descending, <String>['Huge', 'Medium', 'Tiny']);

      state.applyOptions(
        sortIndex: 4,
        ascending: true,
        onlyWithCover: false,
      );
      final ascending = state.buildFilteredTrackTitles(
        tracks: const <({
          String title,
          String artist,
          String album,
          int bytes,
          int modifiedMs,
          bool hasCover,
        })>[
          (
            title: 'Tiny',
            artist: 'A',
            album: 'X',
            bytes: 1,
            modifiedMs: 1,
            hasCover: false,
          ),
          (
            title: 'Huge',
            artist: 'B',
            album: 'X',
            bytes: 9,
            modifiedMs: 2,
            hasCover: true,
          ),
          (
            title: 'Medium',
            artist: 'C',
            album: 'X',
            bytes: 5,
            modifiedMs: 3,
            hasCover: true,
          ),
        ],
      );
      expect(ascending, <String>['Tiny', 'Medium', 'Huge']);
    });

    test('buildFilteredTrackTitles applies cover and query filtering', () {
      final state = LibraryPageFilterStateHarness();
      state.applyOptions(
        sortIndex: 1,
        ascending: false,
        onlyWithCover: true,
      );

      final filtered = state.buildFilteredTrackTitles(
        tracks: const <({
          String title,
          String artist,
          String album,
          int bytes,
          int modifiedMs,
          bool hasCover,
        })>[
          (
            title: 'Night Drive',
            artist: 'A',
            album: 'M1',
            bytes: 3,
            modifiedMs: 1,
            hasCover: true,
          ),
          (
            title: 'Night Walk',
            artist: 'B',
            album: 'M2',
            bytes: 4,
            modifiedMs: 2,
            hasCover: false,
          ),
          (
            title: 'Sunny Day',
            artist: 'C',
            album: 'M3',
            bytes: 5,
            modifiedMs: 3,
            hasCover: true,
          ),
        ],
        query: 'night',
      );

      expect(filtered, <String>['Night Drive']);
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

    test('removeByPath keeps queue unchanged for missing path', () {
      final planner = QueueMutationPlannerHarness();
      final result = planner.removeByPath(
        queue: <String>['/music/a.furry', '/music/b.furry'],
        path: '/music/missing.furry',
        currentPath: '/music/a.furry',
        currentIndex: 0,
      );

      expect(result.removed, isFalse);
      expect(result.cleared, isFalse);
      expect(result.queue, <String>['/music/a.furry', '/music/b.furry']);
      expect(result.index, 0);
    });

    test('enqueue bootstraps queue when currently empty', () {
      final planner = QueueMutationPlannerHarness();
      final result = planner.enqueue(
        queue: null,
        filePath: '/music/new.furry',
        currentPath: null,
        currentIndex: -1,
        playNext: true,
      );

      expect(result.inserted, isTrue);
      expect(result.queue, <String>['/music/new.furry']);
      expect(result.index, -1);
    });

    test('move ignores invalid indexes', () {
      final planner = QueueMutationPlannerHarness();
      final result = planner.move(
        queue: <String>['/music/a.furry', '/music/b.furry'],
        oldIndex: -1,
        newIndex: 1,
        currentPath: '/music/a.furry',
        currentIndex: 0,
      );

      expect(result.moved, isFalse);
      expect(result.queue, <String>['/music/a.furry', '/music/b.furry']);
      expect(result.index, 0);
    });
  });
}

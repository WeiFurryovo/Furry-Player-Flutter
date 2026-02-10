import 'package:flutter_test/flutter_test.dart';
// ignore: avoid_relative_lib_imports
import '../lib/main.dart';

void main() {
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

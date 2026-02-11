part of '../main.dart';

/// 本地音乐库页的状态协调器（搜索输入、建议缓存、索引 Future 缓存）。
///
/// 目标：让 `LibraryPage` 只负责视图拼装，减少 StatefulWidget 内的状态细节。
class _LibraryPageSearchState {
  final SearchController searchController = SearchController();

  String query = '';
  String pendingQuery = '';

  Timer? _queryDebounceTimer;
  int? _suggestionCacheSourceHash;
  final Map<String, _SuggestionCacheEntry> _suggestionCache =
      <String, _SuggestionCacheEntry>{};

  static const Duration _searchDebounceDelay = Duration(milliseconds: 180);
  static const int _suggestionCacheLimit = 32;
  static const int _suggestionMaxStoredMatches = 256;

  int? _lastFilesHash;
  Future<_LibraryIndex>? _indexFuture;

  void dispose() {
    _queryDebounceTimer?.cancel();
    _suggestionCache.clear();
    searchController.dispose();
  }

  void applyQueryImmediately(String value, VoidCallback onStateChanged) {
    final next = value.trim();
    _queryDebounceTimer?.cancel();
    pendingQuery = next;
    if (query == next) return;
    query = next;
    onStateChanged();
  }

  void scheduleQueryUpdate(String value, VoidCallback onStateChanged) {
    final next = value.trim();
    pendingQuery = next;
    _queryDebounceTimer?.cancel();
    _queryDebounceTimer = Timer(_searchDebounceDelay, () {
      if (query == pendingQuery) return;
      query = pendingQuery;
      onStateChanged();
    });
  }

  Future<_LibraryIndex> getIndexFuture(
    _AppController controller,
    List<File> files,
    int sourceHash,
  ) {
    if (_indexFuture != null && _lastFilesHash == sourceHash) {
      return _indexFuture!;
    }

    _lastFilesHash = sourceHash;
    _indexFuture = controller.buildLibraryIndex(files);
    return _indexFuture!;
  }

  List<_TrackEntry> buildSuggestions(
    List<_TrackEntry> tracks,
    String queryLower,
    int sourceHash, {
    required bool Function(_TrackEntry track, String queryLower) matchesQuery,
  }) {
    if (queryLower.isEmpty) {
      return tracks.take(6).toList(growable: false);
    }

    if (_suggestionCacheSourceHash != sourceHash) {
      _suggestionCacheSourceHash = sourceHash;
      _suggestionCache.clear();
    }

    final exactCached = _suggestionCache[queryLower];
    if (exactCached != null) {
      return exactCached.matches.take(8).toList(growable: false);
    }

    List<_TrackEntry>? basePool;
    if (queryLower.length >= 2) {
      final prefixes = _suggestionCache.keys
          .where((key) =>
              key.isNotEmpty &&
              queryLower.startsWith(key) &&
              _suggestionCache[key]!.complete)
          .toList(growable: false)
        ..sort((a, b) => b.length.compareTo(a.length));
      if (prefixes.isNotEmpty) {
        basePool = _suggestionCache[prefixes.first]!.matches;
      }
    }

    final input = basePool ?? tracks;
    final matches = <_TrackEntry>[];
    var complete = true;
    for (final track in input) {
      if (matchesQuery(track, queryLower)) {
        if (matches.length < _suggestionMaxStoredMatches) {
          matches.add(track);
        } else {
          complete = false;
          break;
        }
      }
    }

    final entry = _SuggestionCacheEntry(
      matches: List<_TrackEntry>.unmodifiable(matches),
      complete: complete,
    );
    _suggestionCache[queryLower] = entry;

    if (_suggestionCache.length > _suggestionCacheLimit) {
      _suggestionCache.remove(_suggestionCache.keys.first);
    }

    return matches.take(8).toList(growable: false);
  }
}

@visibleForTesting
class LibraryPageSearchStateHarness {
  final _LibraryPageSearchState _inner = _LibraryPageSearchState();

  String get query => _inner.query;
  String get pendingQuery => _inner.pendingQuery;

  void applyQueryImmediately(String value, {VoidCallback? onChanged}) {
    _inner.applyQueryImmediately(value, onChanged ?? () {});
  }

  void scheduleQueryUpdate(String value, {VoidCallback? onChanged}) {
    _inner.scheduleQueryUpdate(value, onChanged ?? () {});
  }

  int get suggestionCacheSize => _inner._suggestionCache.length;

  List<String> buildSuggestions({
    required List<
            ({
              String title,
              String artist,
              String album,
              bool hasCover,
            })>
        tracks,
    required String query,
    required int sourceHash,
  }) {
    final q = query.trim().toLowerCase();
    final entries = <_TrackEntry>[];
    for (var index = 0; index < tracks.length; index++) {
      final item = tracks[index];
      entries.add(
        _TrackEntry(
          file: File('/music/t_$index.furry'),
          meta: _MetaPreview(
            title: item.title,
            artist: item.artist,
            album: item.album,
            subtitle: [
              if (item.artist.trim().isNotEmpty) item.artist.trim(),
              if (item.album.trim().isNotEmpty) item.album.trim(),
            ].join(' · '),
            artUri: item.hasCover ? Uri.file('/cover/$index.jpg') : null,
            coverBytesLen: null,
          ),
          modified: DateTime.fromMillisecondsSinceEpoch(index),
          bytes: index,
        ),
      );
    }

    final suggestions = _inner.buildSuggestions(
      entries,
      q,
      sourceHash,
      matchesQuery: (track, queryLower) => track.matchesQuery(queryLower),
    );
    return suggestions
        .map((track) => track.displayTitle)
        .toList(growable: false);
  }

  void dispose() => _inner.dispose();
}

part of '../main.dart';

/// 本地音乐库筛选/排序状态协调器。
///
/// 仅封装“状态与判定逻辑”，不关心具体 UI 组件，方便页面复用与测试。
class _LibraryPageFilterState {
  _LibraryView view = _LibraryView.tracks;
  _LibrarySort sort = _LibrarySort.recent;
  bool ascending = false;
  bool onlyWithCover = false;

  _LibraryOptions toOptions() {
    return _LibraryOptions(
      sort: sort,
      ascending: ascending,
      onlyWithCover: onlyWithCover,
    );
  }

  void applyOptions(_LibraryOptions options) {
    sort = options.sort;
    ascending = options.ascending;
    onlyWithCover = options.onlyWithCover;
  }

  int _compareTrack(_TrackEntry a, _TrackEntry b) {
    int result;
    switch (sort) {
      case _LibrarySort.recent:
        result = b.modified.compareTo(a.modified);
        break;
      case _LibrarySort.title:
        result = a.displayTitle.compareTo(b.displayTitle);
        break;
      case _LibrarySort.artist:
        result = a.meta.artist.compareTo(b.meta.artist);
        break;
      case _LibrarySort.album:
        result = a.meta.album.compareTo(b.meta.album);
        break;
      case _LibrarySort.size:
        result = b.bytes.compareTo(a.bytes);
        break;
    }
    return ascending ? -result : result;
  }

  List<_TrackEntry> buildFilteredTracks(
    _LibraryIndex index,
    String queryLower, {
    required bool Function(_TrackEntry track, String queryLower) matchesQuery,
  }) {
    final tracks = index.tracks
        .where((track) => !onlyWithCover || track.meta.artUri != null)
        .where((track) => matchesQuery(track, queryLower))
        .toList(growable: false)
      ..sort(_compareTrack);
    return tracks;
  }

  List<_AlbumGroup> buildFilteredAlbums(
      _LibraryIndex index, String queryLower) {
    return index.albums.where((album) {
      if (onlyWithCover && album.artUri == null) return false;
      if (queryLower.isEmpty) return true;
      return album.title.toLowerCase().contains(queryLower) ||
          album.subtitle.toLowerCase().contains(queryLower);
    }).toList(growable: false);
  }

  List<_ArtistGroup> buildFilteredArtists(
      _LibraryIndex index, String queryLower) {
    return index.artists.where((artist) {
      if (onlyWithCover && artist.artUri == null) return false;
      if (queryLower.isEmpty) return true;
      return artist.title.toLowerCase().contains(queryLower);
    }).toList(growable: false);
  }
}

@visibleForTesting
class LibraryPageFilterStateHarness {
  final _LibraryPageFilterState _inner = _LibraryPageFilterState();

  int get viewIndex => _inner.view.index;
  int get sortIndex => _inner.sort.index;
  bool get ascending => _inner.ascending;
  bool get onlyWithCover => _inner.onlyWithCover;

  void setViewIndex(int index) {
    _inner.view = _LibraryView.values[index];
  }

  void applyOptions({
    required int sortIndex,
    required bool ascending,
    required bool onlyWithCover,
  }) {
    _inner.applyOptions(
      _LibraryOptions(
        sort: _LibrarySort.values[sortIndex],
        ascending: ascending,
        onlyWithCover: onlyWithCover,
      ),
    );
  }
}

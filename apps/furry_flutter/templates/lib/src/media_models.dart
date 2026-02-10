part of '../main.dart';

/// 当前正在播放的条目（供 UI 展示）。
///
/// 该结构只保存 UI 需要的摘要信息：标题/副标题/来源路径/封面 URI。
/// 真实播放源与队列由 `_AppController.player` / `_AppController.queueState` 管理。
class _NowPlaying {
  final String title;
  final String subtitle;
  final String sourcePath;
  final Uri? artUri;

  _NowPlaying({
    required this.title,
    required this.subtitle,
    required this.sourcePath,
    required this.artUri,
  });
}

/// 播放队列快照（供 UI 订阅）。
///
/// `queue` 是文件列表；`index` 指向当前播放项（-1 表示无有效索引）。
class _QueueState {
  final List<File> queue;
  final int index;

  const _QueueState({required this.queue, required this.index});

  bool get hasQueue => queue.isNotEmpty;

  File? get currentFile {
    if (index < 0 || index >= queue.length) return null;
    return queue[index];
  }
}

/// `.furry` 文件的轻量元信息预览（用于列表页快速渲染）。
///
/// 该结构会从 `.furry` 的 tags JSON + cover payload 中提取：
/// - 标题/歌手/专辑
/// - 组合副标题（artist · album）
/// - 封面临时文件 URI（避免在列表里直接持有大字节数组）
class _MetaPreview {
  final String title;
  final String artist;
  final String album;
  final String subtitle;
  final Uri? artUri;
  final int? coverBytesLen;

  _MetaPreview({
    required this.title,
    required this.artist,
    required this.album,
    required this.subtitle,
    required this.artUri,
    required this.coverBytesLen,
  });
}

enum _LibraryView { tracks, albums, artists, queue }

enum _LibrarySort { recent, title, artist, album, size }

class _LibraryOptions {
  final _LibrarySort sort;
  final bool ascending;
  final bool onlyWithCover;

  const _LibraryOptions({
    required this.sort,
    required this.ascending,
    required this.onlyWithCover,
  });
}

class _SuggestionCacheEntry {
  final List<_TrackEntry> matches;
  final bool complete;

  const _SuggestionCacheEntry({
    required this.matches,
    required this.complete,
  });
}

class _TrackEntry {
  final File file;
  final _MetaPreview meta;
  final DateTime modified;
  final int bytes;

  _TrackEntry({
    required this.file,
    required this.meta,
    required this.modified,
    required this.bytes,
  });

  String get path => file.path;

  String get displayTitle =>
      meta.title.isEmpty ? p.basename(file.path) : meta.title;

  String get displayArtist {
    if (meta.artist.isNotEmpty) return meta.artist;
    final parts = meta.subtitle.split(' · ');
    return parts.isEmpty ? '' : parts.first;
  }

  String get displayAlbum => meta.album;

  late final String _searchableLower = [
    p.basename(file.path),
    displayTitle,
    meta.artist,
    meta.album,
  ].join('\n').toLowerCase();

  bool matchesQuery(String queryLower) {
    if (queryLower.isEmpty) return true;
    return _searchableLower.contains(queryLower);
  }
}

@visibleForTesting
bool trackMatchesQueryForTest({
  required String filePath,
  required String query,
  String title = '',
  String artist = '',
  String album = '',
}) {
  final subtitle = [
    if (artist.trim().isNotEmpty) artist.trim(),
    if (album.trim().isNotEmpty) album.trim(),
  ].join(' · ');

  final track = _TrackEntry(
    file: File(filePath),
    meta: _MetaPreview(
      title: title,
      artist: artist,
      album: album,
      subtitle: subtitle,
      artUri: null,
      coverBytesLen: null,
    ),
    modified: DateTime.fromMillisecondsSinceEpoch(0),
    bytes: 0,
  );
  return track.matchesQuery(query.toLowerCase());
}

class _AlbumGroup {
  final String album;
  final String artist;
  Uri? artUri;
  final List<_TrackEntry> tracks = <_TrackEntry>[];

  _AlbumGroup({
    required this.album,
    required this.artist,
    required this.artUri,
  });

  String get title => album.isEmpty ? '未知专辑' : album;
  String get subtitle => artist.isEmpty ? '未知歌手' : artist;
}

class _ArtistGroup {
  final String artist;
  Uri? artUri;
  final Map<String, _AlbumGroup> albumsByKey = <String, _AlbumGroup>{};
  final List<_TrackEntry> tracks = <_TrackEntry>[];

  _ArtistGroup({required this.artist, required this.artUri});

  String get title => artist.isEmpty ? '未知歌手' : artist;
}

class _LibraryIndex {
  final List<_TrackEntry> tracks;
  final List<_AlbumGroup> albums;
  final List<_ArtistGroup> artists;

  const _LibraryIndex({
    required this.tracks,
    required this.albums,
    required this.artists,
  });
}

class _CoverThumb extends StatelessWidget {
  final Uri? artUri;
  const _CoverThumb({required this.artUri});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final uri = artUri;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 48,
        height: 48,
        color: cs.surfaceContainerHigh,
        child: uri == null
            ? Icon(Icons.music_note, color: cs.primary)
            : Image.file(
                File.fromUri(uri),
                fit: BoxFit.cover,
                // Hint decoder to avoid full-res bitmap allocations on Android.
                cacheWidth: 96,
                cacheHeight: 96,
              ),
      ),
    );
  }
}

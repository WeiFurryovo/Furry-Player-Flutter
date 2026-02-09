part of '../main.dart';

/// 本地音乐库页：搜索 + 模块入口（歌曲/专辑/歌手/队列）+ 内容区。
///
/// 数据来源：`_AppController.furryOutputs`（最近输出的 `.furry` 文件列表）。
/// 为避免重复解析，索引构建使用 `Future<_LibraryIndex>` + hash 缓存。
class LibraryPage extends StatefulWidget {
  final _AppController controller;
  const LibraryPage({super.key, required this.controller});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final SearchController _searchController = SearchController();
  String _query = '';
  String _pendingQuery = '';
  Timer? _queryDebounceTimer;
  static const Duration _searchDebounceDelay = Duration(milliseconds: 180);
  int? _suggestionCacheSourceHash;
  final Map<String, _SuggestionCacheEntry> _suggestionCache =
      <String, _SuggestionCacheEntry>{};
  static const int _suggestionCacheLimit = 32;
  static const int _suggestionMaxStoredMatches = 256;
  _LibraryView _view = _LibraryView.tracks;
  _LibrarySort _sort = _LibrarySort.recent;
  bool _ascending = false;
  bool _onlyWithCover = false;

  int? _lastFilesHash;
  List<File>? _lastIndexedFiles;
  Future<_LibraryIndex>? _indexFuture;

  @override
  void dispose() {
    _queryDebounceTimer?.cancel();
    _suggestionCache.clear();
    _searchController.dispose();
    super.dispose();
  }

  void _applyQueryImmediately(String value) {
    final next = value.trim();
    _queryDebounceTimer?.cancel();
    _pendingQuery = next;
    if (_query == next) return;
    setState(() => _query = next);
  }

  void _scheduleQueryUpdate(String value) {
    final next = value.trim();
    _pendingQuery = next;
    _queryDebounceTimer?.cancel();
    _queryDebounceTimer = Timer(_searchDebounceDelay, () {
      if (!mounted || _query == _pendingQuery) return;
      setState(() => _query = _pendingQuery);
    });
  }

  Future<_LibraryIndex> _getIndexFuture(
      _AppController controller, List<File> files) {
    if (_indexFuture != null && identical(_lastIndexedFiles, files)) {
      return _indexFuture!;
    }

    final hash = _filesStateHash(files);
    if (_indexFuture == null || _lastFilesHash != hash) {
      _lastFilesHash = hash;
      _indexFuture = controller.buildLibraryIndex(files);
    }
    _lastIndexedFiles = files;
    return _indexFuture!;
  }

  int _filesStateHash(List<File> files) {
    final fileHashes = <int>[];
    for (final file in files) {
      try {
        final stat = file.statSync();
        fileHashes.add(Object.hash(
          file.path,
          stat.modified.microsecondsSinceEpoch,
          stat.size,
        ));
      } catch (_) {
        fileHashes.add(Object.hash(file.path, 0, 0));
      }
    }
    return Object.hash(files.length, Object.hashAll(fileHashes));
  }

  List<_TrackEntry> _buildSuggestions(
    List<_TrackEntry> tracks,
    String queryLower,
    int sourceHash,
  ) {
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
      if (_matchesQuery(track, queryLower)) {
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

  Widget _buildSuggestionTile(
    SearchController searchController,
    _TrackEntry track, {
    bool showArrow = false,
  }) {
    return ListTile(
      leading: _CoverThumb(artUri: track.meta.artUri),
      title: Text(track.displayTitle,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        track.meta.subtitle.isEmpty ? '本地文件' : track.meta.subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: showArrow ? const Icon(Icons.north_west_rounded) : null,
      onTap: () {
        searchController.closeView(track.displayTitle);
        _applyQueryImmediately(track.displayTitle);
      },
    );
  }

  Widget _buildSuggestionContent(
    SearchController searchController,
    String queryLower,
    List<_TrackEntry> suggestions,
  ) {
    if (queryLower.isEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(
            leading: Icon(Icons.auto_awesome_rounded),
            title: Text('建议'),
            subtitle: Text('试试搜索歌名、专辑或歌手'),
          ),
          for (final track in suggestions)
            _buildSuggestionTile(searchController, track),
        ],
      );
    }

    if (suggestions.isEmpty) {
      return ListTile(
        leading: const Icon(Icons.search_off_rounded),
        title: Text('无结果：${searchController.text}'),
        subtitle: const Text('试试更短的关键词'),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final track in suggestions)
          _buildSuggestionTile(searchController, track, showArrow: true),
      ],
    );
  }

  bool _matchesQuery(_TrackEntry t, String queryLower) {
    if (queryLower.isEmpty) return true;
    final base = p.basename(t.file.path).toLowerCase();
    final title = t.displayTitle.toLowerCase();
    final artist = t.meta.artist.toLowerCase();
    final album = t.meta.album.toLowerCase();
    return base.contains(queryLower) ||
        title.contains(queryLower) ||
        artist.contains(queryLower) ||
        album.contains(queryLower);
  }

  Future<void> _openOptionsSheet() async {
    final current = _LibraryOptions(
      sort: _sort,
      ascending: _ascending,
      onlyWithCover: _onlyWithCover,
    );
    final next = await showModalBottomSheet<_LibraryOptions>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _LibraryOptionsSheet(value: current),
    );
    if (!mounted || next == null) return;
    setState(() {
      _sort = next.sort;
      _ascending = next.ascending;
      _onlyWithCover = next.onlyWithCover;
    });
  }

  int _compareTrack(_TrackEntry a, _TrackEntry b) {
    int result;
    switch (_sort) {
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
    return _ascending ? -result : result;
  }

  List<_TrackEntry> _buildFilteredTracks(
      _LibraryIndex index, String queryLower) {
    final tracks = index.tracks
        .where((track) => !_onlyWithCover || track.meta.artUri != null)
        .where((track) => _matchesQuery(track, queryLower))
        .toList(growable: false)
      ..sort(_compareTrack);
    return tracks;
  }

  List<_AlbumGroup> _buildFilteredAlbums(
      _LibraryIndex index, String queryLower) {
    return index.albums.where((album) {
      if (_onlyWithCover && album.artUri == null) return false;
      if (queryLower.isEmpty) return true;
      return album.title.toLowerCase().contains(queryLower) ||
          album.subtitle.toLowerCase().contains(queryLower);
    }).toList(growable: false);
  }

  List<_ArtistGroup> _buildFilteredArtists(
      _LibraryIndex index, String queryLower) {
    return index.artists.where((artist) {
      if (_onlyWithCover && artist.artUri == null) return false;
      if (queryLower.isEmpty) return true;
      return artist.title.toLowerCase().contains(queryLower);
    }).toList(growable: false);
  }

  Widget _buildLibraryContentSliver(
    _AppController controller,
    _LibraryIndex index,
    String queryLower,
  ) {
    switch (_view) {
      case _LibraryView.tracks:
        final tracks = _buildFilteredTracks(index, queryLower);
        return _TracksSliver(
          controller: controller,
          tracks: tracks,
          bytesFmt: _fmtBytes,
        );
      case _LibraryView.albums:
        final albums = _buildFilteredAlbums(index, queryLower);
        return _AlbumsSliver(controller: controller, albums: albums);
      case _LibraryView.artists:
        final artists = _buildFilteredArtists(index, queryLower);
        return _ArtistsSliver(controller: controller, artists: artists);
      case _LibraryView.queue:
        return _QueueSliver(controller: controller);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final cs = Theme.of(context).colorScheme;

    return CustomScrollView(
      slivers: [
        SliverAppBar.large(
          title: const Text('本地音乐'),
          actions: [
            IconButton(
              tooltip: '刷新',
              onPressed: controller.refreshOutputs,
              icon: const Icon(Icons.refresh_rounded),
            ),
            const SizedBox(width: 8),
          ],
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SearchAnchor.bar(
              searchController: _searchController,
              barHintText: '搜索音乐库',
              barLeading: const Icon(Icons.search_rounded),
              barTrailing: <Widget>[
                IconButton.filledTonal(
                  tooltip: '排序/筛选',
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    _openOptionsSheet();
                  },
                  icon: const Icon(Icons.tune_rounded),
                ),
              ],
              suggestionsBuilder: (context, searchController) {
                final q = _pendingQuery.toLowerCase();
                final files = controller.furryOutputs.value;
                if (files.isEmpty) {
                  return <Widget>[
                    const ListTile(
                      leading: Icon(Icons.music_off_rounded),
                      title: Text('暂无可搜索内容'),
                    ),
                  ];
                }
                return <Widget>[
                  FutureBuilder<_LibraryIndex>(
                    future: _getIndexFuture(controller, files),
                    builder: (context, snap) {
                      final idx = snap.data;
                      if (idx == null) {
                        return const ListTile(
                          leading: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          title: Text('正在加载…'),
                        );
                      }

                      final tracks = idx.tracks;
                      final sourceHash = _lastFilesHash ?? 0;
                      final suggestions =
                          _buildSuggestions(tracks, q, sourceHash);
                      return _buildSuggestionContent(
                        searchController,
                        q,
                        suggestions,
                      );
                    },
                  ),
                ];
              },
              onChanged: _scheduleQueryUpdate,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _LibraryModulesCard(
              value: _view,
              onChanged: (v) {
                HapticFeedback.selectionClick();
                setState(() => _view = v);
              },
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          sliver: ValueListenableBuilder<List<File>>(
            valueListenable: controller.furryOutputs,
            builder: (context, files, _) {
              if (files.isEmpty) {
                return SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '还没有音乐库内容',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '当前没有检测到 .furry 输出文件。先去“转换”页打包，或直接选择一个音频文件开始播放。',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      Card(
                        margin: EdgeInsets.zero,
                        color: cs.surfaceContainer,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(28),
                        ),
                        child: Column(
                          children: [
                            ListTile(
                              leading: Icon(Icons.swap_horiz_rounded,
                                  color: cs.primary),
                              title: const Text('去转换'),
                              subtitle: const Text('把音频打包成 .furry 并写入封面/标签'),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () {
                                HapticFeedback.selectionClick();
                                controller.requestTabIndex(1);
                              },
                            ),
                            const Divider(height: 1),
                            ListTile(
                              leading: Icon(Icons.audio_file_rounded,
                                  color: cs.primary),
                              title: const Text('选择音频播放'),
                              subtitle: const Text('无需 .furry，也可以先体验播放器'),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () async {
                                HapticFeedback.selectionClick();
                                final f = await controller.pickForPlay();
                                if (f == null) return;
                                await controller.playFile(
                                  file: f,
                                  displayName: p.basename(f.path),
                                );
                              },
                            ),
                            const Divider(height: 1),
                            ListTile(
                              leading: Icon(Icons.refresh_rounded,
                                  color: cs.primary),
                              title: const Text('重新扫描'),
                              subtitle: const Text('更新“最近输出”列表'),
                              onTap: () async {
                                HapticFeedback.selectionClick();
                                await controller.refreshOutputs();
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }

              return FutureBuilder<_LibraryIndex>(
                future: _getIndexFuture(controller, files),
                builder: (context, snap) {
                  final idx = snap.data;
                  if (idx == null) {
                    return const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Center(
                          child: CircularProgressIndicator(),
                        ),
                      ),
                    );
                  }

                  final q = _query.trim().toLowerCase();
                  return _buildLibraryContentSliver(controller, idx, q);
                },
              );
            },
          ),
        ),
        SliverToBoxAdapter(child: _BottomOverlaySpacer(controller: controller)),
      ],
    );
  }
}

String _fmtBytes(int bytes) {
  const kb = 1024;
  const mb = 1024 * 1024;
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(1)} KB';
  return '$bytes B';
}

PageRoute<T> _expressivePageRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      final offset = Tween<Offset>(
        begin: const Offset(0.06, 0),
        end: Offset.zero,
      ).animate(curved);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(position: offset, child: child),
      );
    },
  );
}

String _albumHeroTag(_AlbumGroup album) {
  return 'album_${album.artist.toLowerCase()}|${album.album.toLowerCase()}';
}

String _nowPlayingHeroTag(String sourcePath) {
  // Keep it stable and reasonably short; Hero tags can be any object, but we
  // prefer a string for easier debugging.
  return 'np_${sourcePath.hashCode}';
}

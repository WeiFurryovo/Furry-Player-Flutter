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
  final _LibraryPageSearchState _searchState = _LibraryPageSearchState();
  final _LibraryPageFilterState _filterState = _LibraryPageFilterState();

  @override
  void dispose() {
    _searchState.dispose();
    super.dispose();
  }

  void _onSearchStateChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _applyQueryImmediately(String value) {
    _searchState.applyQueryImmediately(value, _onSearchStateChanged);
  }

  void _scheduleQueryUpdate(String value) {
    _searchState.scheduleQueryUpdate(value, _onSearchStateChanged);
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
    return t.matchesQuery(queryLower);
  }

  Future<void> _openOptionsSheet() async {
    final next = await showModalBottomSheet<_LibraryOptions>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) =>
          _LibraryOptionsSheet(value: _filterState.toOptions()),
    );
    if (!mounted || next == null) return;
    setState(() => _filterState.applyOptions(next));
  }

  Widget _buildLibraryContentSliver(
    _AppController controller,
    _LibraryIndex index,
    String queryLower,
  ) {
    switch (_filterState.view) {
      case _LibraryView.tracks:
        final tracks = _filterState.buildFilteredTracks(
          index,
          queryLower,
          matchesQuery: _matchesQuery,
        );
        return _TracksSliver(
          controller: controller,
          tracks: tracks,
          bytesFmt: _fmtBytes,
        );
      case _LibraryView.albums:
        final albums = _filterState.buildFilteredAlbums(index, queryLower);
        return _AlbumsSliver(controller: controller, albums: albums);
      case _LibraryView.artists:
        final artists = _filterState.buildFilteredArtists(index, queryLower);
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
              searchController: _searchState.searchController,
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
                final q = _searchState.pendingQuery.toLowerCase();
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
                    future: _searchState.getIndexFuture(
                      controller,
                      files,
                      controller.furryOutputsSignature.value,
                    ),
                    builder: (context, snap) {
                      final idx = snap.data;
                      if (idx == null) {
                        return const _LibrarySuggestionLoadingList();
                      }

                      final tracks = idx.tracks;
                      final sourceHash = controller.furryOutputsSignature.value;
                      final suggestions = _searchState.buildSuggestions(
                        tracks,
                        q,
                        sourceHash,
                        matchesQuery: _matchesQuery,
                      );
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
              value: _filterState.view,
              onChanged: (v) {
                HapticFeedback.selectionClick();
                setState(() => _filterState.view = v);
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
                future: _searchState.getIndexFuture(
                  controller,
                  files,
                  controller.furryOutputsSignature.value,
                ),
                builder: (context, snap) {
                  final idx = snap.data;
                  if (idx == null) {
                    return _LibraryLoadingSliver(
                      rows: _libraryLoadingPlaceholderCount(_filterState.view),
                    );
                  }

                  final q = _searchState.query.trim().toLowerCase();
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

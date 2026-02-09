part of '../main.dart';

class _LibraryModulesCard extends StatelessWidget {
  const _LibraryModulesCard({
    required this.value,
    required this.onChanged,
  });

  final _LibraryView value;
  final ValueChanged<_LibraryView> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    const modules = <({
      _LibraryView view,
      IconData icon,
      String title,
      String subtitle,
    })>[
      (
        view: _LibraryView.tracks,
        icon: Icons.music_note_rounded,
        title: '歌曲',
        subtitle: '按单曲浏览与播放',
      ),
      (
        view: _LibraryView.albums,
        icon: Icons.album_rounded,
        title: '专辑',
        subtitle: '按专辑归类，沉浸式封面网格',
      ),
      (
        view: _LibraryView.artists,
        icon: Icons.person_rounded,
        title: '歌手',
        subtitle: '按歌手整理，快速定位作品',
      ),
      (
        view: _LibraryView.queue,
        icon: Icons.queue_music_rounded,
        title: '队列',
        subtitle: '管理接下来要播放的内容',
      ),
    ];

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: cs.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final item in modules) ...[
                _LibraryModuleChip(
                  selected: value == item.view,
                  icon: item.icon,
                  label: item.title,
                  semanticHint: item.subtitle,
                  onTap: () => onChanged(item.view),
                ),
                if (item != modules.last) const SizedBox(width: 8),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LibraryModuleChip extends StatelessWidget {
  const _LibraryModuleChip({
    required this.selected,
    required this.icon,
    required this.label,
    required this.semanticHint,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final String semanticHint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = selected
        ? cs.secondaryContainer
        : _withOpacityCompat(cs.surfaceContainerHighest, 0.8);
    final fg = selected ? cs.onSecondaryContainer : cs.onSurfaceVariant;

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      hint: semanticHint,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: fg),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: fg,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryOptionsSheet extends StatefulWidget {
  const _LibraryOptionsSheet({required this.value});

  final _LibraryOptions value;

  @override
  State<_LibraryOptionsSheet> createState() => _LibraryOptionsSheetState();
}

class _LibraryOptionsSheetState extends State<_LibraryOptionsSheet> {
  late _LibrarySort _sort;
  late bool _ascending;
  late bool _onlyWithCover;

  @override
  void initState() {
    super.initState();
    _sort = widget.value.sort;
    _ascending = widget.value.ascending;
    _onlyWithCover = widget.value.onlyWithCover;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '排序与筛选',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 12),
            Text('排序', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _SortChip(
                  label: '最近',
                  selected: _sort == _LibrarySort.recent,
                  onTap: () => setState(() => _sort = _LibrarySort.recent),
                ),
                _SortChip(
                  label: '标题',
                  selected: _sort == _LibrarySort.title,
                  onTap: () => setState(() => _sort = _LibrarySort.title),
                ),
                _SortChip(
                  label: '歌手',
                  selected: _sort == _LibrarySort.artist,
                  onTap: () => setState(() => _sort = _LibrarySort.artist),
                ),
                _SortChip(
                  label: '专辑',
                  selected: _sort == _LibrarySort.album,
                  onTap: () => setState(() => _sort = _LibrarySort.album),
                ),
                _SortChip(
                  label: '大小',
                  selected: _sort == _LibrarySort.size,
                  onTap: () => setState(() => _sort = _LibrarySort.size),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              value: _ascending,
              onChanged: (v) => setState(() => _ascending = v),
              contentPadding: EdgeInsets.zero,
              title: const Text('升序'),
              subtitle: const Text('关闭时为降序/最近优先'),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              value: _onlyWithCover,
              onChanged: (v) => setState(() => _onlyWithCover = v),
              contentPadding: EdgeInsets.zero,
              title: const Text('仅显示有封面'),
              subtitle: const Text('用于快速筛选更完整的条目'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop(
                        _LibraryOptions(
                          sort: _sort,
                          ascending: _ascending,
                          onlyWithCover: _onlyWithCover,
                        ),
                      );
                    },
                    child: const Text('应用'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SortChip extends StatelessWidget {
  const _SortChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      selected: selected,
      label: Text(label),
      onSelected: (_) => onTap(),
      showCheckmark: false,
      selectedColor: Theme.of(context).colorScheme.secondaryContainer,
    );
  }
}

typedef _BytesFmt = String Function(int bytes);

class _TracksSliver extends StatelessWidget {
  const _TracksSliver({
    required this.controller,
    required this.tracks,
    required this.bytesFmt,
  });

  final _AppController controller;
  final List<_TrackEntry> tracks;
  final _BytesFmt bytesFmt;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final nowPlayingPath = controller.nowPlaying.value?.sourcePath;
    if (tracks.isEmpty) {
      return SliverToBoxAdapter(
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.filter_alt_off_rounded, color: cs.primary),
                const SizedBox(width: 12),
                const Expanded(child: Text('没有匹配结果')),
              ],
            ),
          ),
        ),
      );
    }

    final queueFiles = tracks.map((t) => t.file).toList(growable: false);

    return SliverList.separated(
      itemCount: tracks.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final t = tracks[i];
        final isCurrent = nowPlayingPath != null && nowPlayingPath == t.path;
        final meta = t.meta;
        final subtitleParts = <String>[
          if (meta.artist.isNotEmpty) meta.artist,
          if (meta.album.isNotEmpty) meta.album,
        ];
        final subtitle = subtitleParts.isNotEmpty
            ? subtitleParts.join(' · ')
            : (meta.subtitle.isNotEmpty
                ? meta.subtitle
                : '${bytesFmt(t.bytes)} · ${t.modified.toLocal()}');

        return Card(
          margin: EdgeInsets.zero,
          color: isCurrent
              ? _withOpacityCompat(cs.secondaryContainer, 0.55)
              : null,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: Stack(
              clipBehavior: Clip.none,
              children: [
                _CoverThumb(artUri: t.meta.artUri),
                if (isCurrent)
                  Positioned(
                    right: -6,
                    bottom: -6,
                    child: AnimatedScale(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutBack,
                      scale: 1,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: cs.primary,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: _withOpacityCompat(cs.surface, 0.85),
                          ),
                        ),
                        child: Icon(
                          Icons.equalizer_rounded,
                          size: 14,
                          color: cs.onPrimary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            title: Text(
              t.displayTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '加入队列',
                  onPressed: () async {
                    HapticFeedback.selectionClick();
                    await controller.enqueueFile(t.file, playNext: false);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已加入队列')),
                      );
                    }
                  },
                  icon: const Icon(Icons.queue_music_rounded),
                ),
                _TrackOverflowMenu(
                  controller: controller,
                  track: t,
                  queueFiles: queueFiles,
                  indexInQueue: i,
                ),
              ],
            ),
            onTap: () => controller.playFromQueue(
              queue: queueFiles,
              index: i,
              displayName: p.basename(t.file.path),
            ),
          ),
        );
      },
    );
  }
}

class _TrackOverflowMenu extends StatelessWidget {
  const _TrackOverflowMenu({
    required this.controller,
    required this.track,
    required this.queueFiles,
    required this.indexInQueue,
  });

  final _AppController controller;
  final _TrackEntry track;
  final List<File> queueFiles;
  final int indexInQueue;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '更多',
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'play',
          child: ListTile(
            leading: Icon(Icons.play_arrow_rounded),
            title: Text('播放'),
          ),
        ),
        const PopupMenuItem(
          value: 'play_next',
          child: ListTile(
            leading: Icon(Icons.playlist_play_rounded),
            title: Text('下一首播放（加入队列）'),
          ),
        ),
        const PopupMenuItem(
          value: 'add_queue',
          child: ListTile(
            leading: Icon(Icons.queue_music_rounded),
            title: Text('加入队列'),
          ),
        ),
        const PopupMenuItem(
          value: 'copy_path',
          child: ListTile(
            leading: Icon(Icons.copy_rounded),
            title: Text('复制路径'),
          ),
        ),
      ],
      onSelected: (v) async {
        switch (v) {
          case 'play':
            HapticFeedback.selectionClick();
            await controller.playFromQueue(
              queue: queueFiles,
              index: indexInQueue,
              displayName: p.basename(track.file.path),
            );
            break;
          case 'play_next':
            HapticFeedback.selectionClick();
            await controller.enqueueFile(track.file, playNext: true);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已加入“下一首播放”')),
              );
            }
            break;
          case 'add_queue':
            HapticFeedback.selectionClick();
            await controller.enqueueFile(track.file, playNext: false);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已加入队列')),
              );
            }
            break;
          case 'copy_path':
            HapticFeedback.selectionClick();
            await Clipboard.setData(ClipboardData(text: track.file.path));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制路径')),
              );
            }
            break;
        }
      },
      icon: const Icon(Icons.more_vert_rounded),
    );
  }
}

class _AlbumsSliver extends StatelessWidget {
  const _AlbumsSliver({required this.controller, required this.albums});

  final _AppController controller;
  final List<_AlbumGroup> albums;

  @override
  Widget build(BuildContext context) {
    if (albums.isEmpty) {
      return const SliverToBoxAdapter(
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text('没有匹配的专辑'),
          ),
        ),
      );
    }

    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.crossAxisExtent;
        final crossAxisCount = w >= 980
            ? 5
            : w >= 760
                ? 4
                : w >= 520
                    ? 3
                    : 2;
        return SliverGrid(
          delegate: SliverChildBuilderDelegate(
            childCount: albums.length,
            (context, i) {
              final a = albums[i];
              return _AlbumTile(
                album: a,
                onTap: () {
                  Navigator.of(context).push(
                    _expressivePageRoute(
                      _AlbumDetailPage(controller: controller, album: a),
                    ),
                  );
                },
              );
            },
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.85,
          ),
        );
      },
    );
  }
}

class _AlbumTile extends StatelessWidget {
  const _AlbumTile({required this.album, required this.onTap});

  final _AlbumGroup album;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final heroTag = _albumHeroTag(album);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Hero(
                        tag: heroTag,
                        child: Container(
                          color: cs.surfaceContainerHigh,
                          child: album.artUri == null
                              ? Center(
                                  child: Icon(
                                    Icons.album_rounded,
                                    color: cs.primary,
                                    size: 44,
                                  ),
                                )
                              : Image.file(
                                  File.fromUri(album.artUri!),
                                  fit: BoxFit.cover,
                                  cacheWidth: 512,
                                  cacheHeight: 512,
                                  gaplessPlayback: true,
                                ),
                        ),
                      ),
                      Positioned(
                        right: 10,
                        top: 10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: _withOpacityCompat(
                                cs.surfaceContainerHighest, 0.9),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color:
                                  _withOpacityCompat(cs.outlineVariant, 0.55),
                            ),
                          ),
                          child: Text(
                            '${album.tracks.length} 首',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: cs.onSurface,
                                ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                album.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 2),
              Text(
                album.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArtistsSliver extends StatelessWidget {
  const _ArtistsSliver({required this.controller, required this.artists});

  final _AppController controller;
  final List<_ArtistGroup> artists;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (artists.isEmpty) {
      return const SliverToBoxAdapter(
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text('没有匹配的歌手'),
          ),
        ),
      );
    }

    return SliverList.separated(
      itemCount: artists.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final a = artists[i];
        final albums = a.albumsByKey.values.length;
        final initial = a.title.isEmpty ? '?' : a.title.characters.first;
        return Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: a.artUri == null
                ? CircleAvatar(
                    backgroundColor: cs.secondaryContainer,
                    foregroundColor: cs.onSecondaryContainer,
                    child: Text(
                      initial,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Image.file(
                        File.fromUri(a.artUri!),
                        fit: BoxFit.cover,
                        cacheWidth: 96,
                        cacheHeight: 96,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
            title: Text(
              a.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '$albums 张专辑 · ${a.tracks.length} 首',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              Navigator.of(context).push(
                _expressivePageRoute(
                  _ArtistDetailPage(controller: controller, artist: a),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _QueueSliver extends StatelessWidget {
  const _QueueSliver({required this.controller});

  final _AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<_QueueState>(
      valueListenable: controller.queueState,
      builder: (context, qs, _) {
        if (!qs.hasQueue) {
          return SliverToBoxAdapter(
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(Icons.queue_music_rounded,
                        color: cs.primary, size: 28),
                    const SizedBox(width: 12),
                    const Expanded(
                        child: Text('队列为空：从“歌曲/专辑/歌手”里添加或直接播放即可生成队列')),
                  ],
                ),
              ),
            ),
          );
        }

        return SliverToBoxAdapter(
          child: Column(
            children: [
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Row(
                    children: [
                      Icon(Icons.queue_music_rounded, color: cs.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '播放队列 · ${qs.queue.length} 首',
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w800,
                                  ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () =>
                            controller.clearQueue(keepPlaying: true),
                        icon: const Icon(Icons.clear_all_rounded),
                        label: const Text('清空'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: qs.queue.length,
                onReorder: (oldIndex, newIndex) {
                  var target = newIndex;
                  if (target > oldIndex) target -= 1;
                  controller.moveQueueItem(oldIndex, target);
                },
                itemBuilder: (context, i) {
                  final f = qs.queue[i];
                  final key = ValueKey<String>('q_${f.path}');
                  return _QueueRow(
                    key: key,
                    controller: controller,
                    file: f,
                    index: i,
                    isCurrent: i == qs.index,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    super.key,
    required this.controller,
    required this.file,
    required this.index,
    required this.isCurrent,
  });

  final _AppController controller;
  final File file;
  final int index;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = p.basename(file.path);
    final ext = p.extension(base).toLowerCase();
    final isFurry = ext == '.furry';

    return Card(
      key: key,
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: isFurry
            ? FutureBuilder<_MetaPreview>(
                future: controller.getMetaPreviewForFurry(file),
                builder: (context, snap) {
                  final meta = snap.data;
                  final art = meta?.artUri;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      _CoverThumb(artUri: art),
                      if (isCurrent)
                        Positioned(
                          right: -6,
                          bottom: -6,
                          child: AnimatedScale(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutBack,
                            scale: isCurrent ? 1 : 0.8,
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 180),
                              opacity: isCurrent ? 1 : 0,
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: cs.primary,
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: _withOpacityCompat(cs.surface, 0.85),
                                  ),
                                ),
                                child: Icon(
                                  Icons.equalizer_rounded,
                                  size: 14,
                                  color: cs.onPrimary,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              )
            : Stack(
                clipBehavior: Clip.none,
                children: [
                  CircleAvatar(
                    backgroundColor: cs.surfaceContainerHigh,
                    foregroundColor: cs.onSurfaceVariant,
                    child: Text('${index + 1}'),
                  ),
                  if (isCurrent)
                    Positioned(
                      right: -6,
                      bottom: -6,
                      child: AnimatedScale(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutBack,
                        scale: isCurrent ? 1 : 0.8,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 180),
                          opacity: isCurrent ? 1 : 0,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: cs.primary,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: _withOpacityCompat(cs.surface, 0.85),
                              ),
                            ),
                            child: Icon(
                              Icons.equalizer_rounded,
                              size: 14,
                              color: cs.onPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
        title: isFurry
            ? FutureBuilder<_MetaPreview>(
                future: controller.getMetaPreviewForFurry(file),
                builder: (context, snap) {
                  final meta = snap.data;
                  return Text(
                    meta?.title ?? base,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  );
                },
              )
            : Text(base, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: isFurry
            ? FutureBuilder<_MetaPreview>(
                future: controller.getMetaPreviewForFurry(file),
                builder: (context, snap) {
                  final meta = snap.data;
                  final subtitleParts = <String>[
                    if ((meta?.artist ?? '').isNotEmpty) meta!.artist,
                    if ((meta?.album ?? '').isNotEmpty) meta!.album,
                  ];
                  final subtitle = subtitleParts.isNotEmpty
                      ? subtitleParts.join(' · ')
                      : (meta?.subtitle ?? '');
                  return Text(
                    subtitle.isEmpty ? '本地文件' : subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  );
                },
              )
            : const Text('本地文件'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '移除',
              onPressed: () => controller.removeFromQueueByPath(file.path),
              icon: const Icon(Icons.close_rounded),
            ),
            ReorderableDragStartListener(
              index: index,
              child: const Icon(Icons.drag_handle_rounded),
            ),
          ],
        ),
        onTap: () => controller.playAtQueueIndex(index),
      ),
    );
  }
}

class _AlbumDetailPage extends StatelessWidget {
  const _AlbumDetailPage({required this.controller, required this.album});

  final _AppController controller;
  final _AlbumGroup album;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tracks = album.tracks;
    final heroTag = _albumHeroTag(album);
    final w = MediaQuery.of(context).size.width;
    final coverSize = (w - 48).clamp(200.0, 320.0);
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: Text(album.title),
            actions: [
              FilledButton.tonalIcon(
                onPressed: tracks.isEmpty
                    ? null
                    : () => controller.playFromQueue(
                          queue:
                              tracks.map((t) => t.file).toList(growable: false),
                          index: 0,
                          displayName: p.basename(tracks.first.file.path),
                        ),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('播放全部'),
              ),
              const SizedBox(width: 8),
            ],
          ),
          SliverToBoxAdapter(
            child: TweenAnimationBuilder<double>(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              tween: Tween<double>(begin: 0, end: 1),
              builder: (context, t, child) {
                return Opacity(
                  opacity: t,
                  child: Transform.translate(
                    offset: Offset(0, lerpDouble(12, 0, t)!),
                    child: child,
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: SizedBox(
                          width: coverSize,
                          height: coverSize,
                          child: Hero(
                            tag: heroTag,
                            child: album.artUri == null
                                ? ColoredBox(
                                    color: cs.surfaceContainerHigh,
                                    child: Icon(
                                      Icons.album_rounded,
                                      size: coverSize * 0.28,
                                      color: cs.primary,
                                    ),
                                  )
                                : Image.file(
                                    File.fromUri(album.artUri!),
                                    fit: BoxFit.cover,
                                    cacheWidth: 1024,
                                    cacheHeight: 1024,
                                    gaplessPlayback: true,
                                  ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      album.subtitle,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${tracks.length} 首',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: _TracksSliver(
              controller: controller,
              tracks: tracks,
              bytesFmt: _fmtBytes,
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtistDetailPage extends StatelessWidget {
  const _ArtistDetailPage({required this.controller, required this.artist});

  final _AppController controller;
  final _ArtistGroup artist;

  @override
  Widget build(BuildContext context) {
    final albums = artist.albumsByKey.values.toList(growable: false)
      ..sort((a, b) => a.title.compareTo(b.title));
    final tracks = artist.tracks.toList(growable: false)
      ..sort((a, b) => a.displayTitle.compareTo(b.displayTitle));
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: Text(artist.title),
            actions: [
              FilledButton.tonalIcon(
                onPressed: tracks.isEmpty
                    ? null
                    : () => controller.playFromQueue(
                          queue:
                              tracks.map((t) => t.file).toList(growable: false),
                          index: 0,
                          displayName: p.basename(tracks.first.file.path),
                        ),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('播放全部'),
              ),
              const SizedBox(width: 8),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Icon(Icons.album_rounded, color: cs.primary),
                  const SizedBox(width: 8),
                  Text('专辑', style: Theme.of(context).textTheme.titleLarge),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: _AlbumsSliver(controller: controller, albums: albums),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Icon(Icons.music_note_rounded, color: cs.primary),
                  const SizedBox(width: 8),
                  Text('歌曲', style: Theme.of(context).textTheme.titleLarge),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: _TracksSliver(
              controller: controller,
              tracks: tracks,
              bytesFmt: _fmtBytes,
            ),
          ),
        ],
      ),
    );
  }
}

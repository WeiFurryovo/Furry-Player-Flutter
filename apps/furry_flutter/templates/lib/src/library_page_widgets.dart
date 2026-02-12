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

class _LibrarySuggestionLoadingList extends StatelessWidget {
  const _LibrarySuggestionLoadingList();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text('正在加载搜索建议…'),
          subtitle: Text('首次加载可能需要几秒'),
        ),
      ],
    );
  }
}

class _LibraryLoadingSliver extends StatelessWidget {
  const _LibraryLoadingSliver({required this.rows});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SliverList.separated(
      itemCount: rows,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        return RepaintBoundary(
          child: Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
              leading: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              title: Container(
                height: 14,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: _withOpacityCompat(cs.surfaceContainerHighest, 0.9),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    height: 12,
                    width: 140,
                    decoration: BoxDecoration(
                      color:
                          _withOpacityCompat(cs.surfaceContainerHighest, 0.75),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              trailing: Icon(
                Icons.more_horiz_rounded,
                color: _withOpacityCompat(cs.onSurfaceVariant, 0.6),
              ),
            ),
          ),
        );
      },
    );
  }
}

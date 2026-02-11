part of '../main.dart';

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

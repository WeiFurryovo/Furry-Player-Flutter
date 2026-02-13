part of '../main.dart';

class NowPlayingPanel extends StatefulWidget {
  final _AppController controller;
  final double bottomOverlayBaseline;
  final bool hideDuringTextInput;

  // Tuned by eye: close to M3 mini player height.
  static const double miniHeightPx = 76;
  static const double miniGapPx = 8;

  const NowPlayingPanel({
    super.key,
    required this.controller,
    required this.bottomOverlayBaseline,
    required this.hideDuringTextInput,
  });

  @override
  State<NowPlayingPanel> createState() => _NowPlayingPanelState();
}

class _NowPlayingPanelState extends State<NowPlayingPanel> {
  bool _sheetOpen = false;

  Future<void> _openSheet(_NowPlaying np) async {
    if (_sheetOpen) return;
    setState(() => _sheetOpen = true);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return _NowPlayingSheet(controller: widget.controller, np: np);
      },
    );
    if (mounted) setState(() => _sheetOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_NowPlaying?>(
      valueListenable: widget.controller.nowPlaying,
      builder: (context, np, _) {
        final current = np;
        return Align(
          alignment: Alignment.bottomCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              final offset = Tween<Offset>(
                begin: const Offset(0, 0.12),
                end: Offset.zero,
              ).animate(animation);
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(position: offset, child: child),
              );
            },
            child: current == null || widget.hideDuringTextInput
                ? const SizedBox(key: ValueKey<String>('hidden'))
                : Padding(
                    key: ValueKey<String>('visible_${current.sourcePath}'),
                    padding: EdgeInsets.fromLTRB(
                      16,
                      0,
                      16,
                      widget.bottomOverlayBaseline + NowPlayingPanel.miniGapPx,
                    ),
                    child: _NowPlayingMiniBar(
                      controller: widget.controller,
                      np: current,
                      onOpen: () => _openSheet(current),
                    ),
                  ),
          ),
        );
      },
    );
  }
}

Future<void> _showNowPlayingActionsSheet({
  required BuildContext context,
  required _AppController controller,
  required _NowPlaying np,
}) async {
  final file = File(np.sourcePath);
  final qs = controller.queueState.value;
  final inQueue = qs.queue.any((f) => f.path == np.sourcePath);

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final subtitle =
          np.subtitle.trim().isEmpty ? p.basename(np.sourcePath) : np.subtitle;
      final queueLabel = qs.hasQueue ? '队列 ${qs.queue.length} 首' : '未启用队列';
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Card(
                margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: ListTile(
                  leading: _CoverThumb(artUri: np.artUri),
                  title: Text(np.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(subtitle,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Text(queueLabel),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.queue_music_rounded),
                title: const Text('加入队列'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await controller.enqueueFile(file, playNext: false);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已加入队列')),
                    );
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.playlist_play_rounded),
                title: const Text('下一首播放'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await controller.enqueueFile(file, playNext: true);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已加入“下一首播放”')),
                    );
                  }
                },
              ),
              if (inQueue)
                ListTile(
                  leading: const Icon(Icons.playlist_remove_rounded),
                  title: const Text('从队列移除'),
                  onTap: () async {
                    Navigator.of(context).pop();
                    await controller.removeFromQueueByPath(np.sourcePath);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已从队列移除')),
                      );
                    }
                  },
                ),
              if (qs.hasQueue)
                ListTile(
                  leading: const Icon(Icons.clear_all_rounded),
                  title: const Text('清空队列（不停止播放）'),
                  onTap: () {
                    Navigator.of(context).pop();
                    controller.clearQueue(keepPlaying: true);
                  },
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('复制标题'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await Clipboard.setData(ClipboardData(text: np.title));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制标题')),
                    );
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('复制路径'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await Clipboard.setData(ClipboardData(text: np.sourcePath));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制路径')),
                    );
                  }
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _NowPlayingMiniBar extends StatelessWidget {
  const _NowPlayingMiniBar({
    required this.controller,
    required this.np,
    required this.onOpen,
  });

  final _AppController controller;
  final _NowPlaying np;
  final VoidCallback onOpen;

  static const double _compactControlSize = 40;
  static const double _compactPrimaryControlSize = 42;

  ButtonStyle _compactTonalStyle() {
    return IconButton.styleFrom(
      minimumSize: const Size.square(_compactControlSize),
      maximumSize: const Size.square(_compactControlSize),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final titleStyle = Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        );
    final subtitleStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: cs.onSurfaceVariant,
        );

    return LayoutBuilder(
      builder: (context, constraints) {
        final showPrevious = constraints.maxWidth >= 470;
        final showMore = constraints.maxWidth >= 560;
        final heroTag = _nowPlayingHeroTag(np.sourcePath);
        return Semantics(
          button: true,
          label: '正在播放：${np.title}',
          child: Material(
            elevation: 2,
            color: cs.surfaceContainerHigh,
            surfaceTintColor: cs.surfaceTint,
            shadowColor: _withOpacityCompat(cs.shadow, 0.22),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(
                color: _withOpacityCompat(cs.outlineVariant, 0.55),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              height: NowPlayingPanel.miniHeightPx,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: onOpen,
                        onLongPress: () {
                          HapticFeedback.selectionClick();
                          _showNowPlayingActionsSheet(
                            context: context,
                            controller: controller,
                            np: np,
                          );
                        },
                        borderRadius: BorderRadius.circular(20),
                        child: Row(
                          children: [
                            Hero(
                              tag: heroTag,
                              child: _CoverThumb(artUri: np.artUri),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    np.title,
                                    style: titleStyle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    np.subtitle,
                                    style: subtitleStyle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 6),
                                  _MiniProgress(controller: controller),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (showPrevious) ...[
                      IconButton.filledTonal(
                        style: _compactTonalStyle(),
                        tooltip: '上一首',
                        onPressed: controller.canPlayPreviousTrack
                            ? () {
                                HapticFeedback.selectionClick();
                                controller.playPreviousTrack();
                              }
                            : null,
                        icon: const Icon(
                          Icons.skip_previous_rounded,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    _MiniPlayPause(
                      controller: controller,
                      compact: true,
                    ),
                    const SizedBox(width: 6),
                    IconButton.filledTonal(
                      style: _compactTonalStyle(),
                      tooltip: '下一首',
                      onPressed: controller.canPlayNextTrack
                          ? () {
                              HapticFeedback.selectionClick();
                              controller.playNextTrack();
                            }
                          : null,
                      icon: const Icon(Icons.skip_next_rounded, size: 22),
                    ),
                    const SizedBox(width: 6),
                    IconButton.filledTonal(
                      style: _compactTonalStyle(),
                      tooltip: '展开',
                      onPressed: () {
                        HapticFeedback.selectionClick();
                        onOpen();
                      },
                      icon:
                          const Icon(Icons.keyboard_arrow_up_rounded, size: 24),
                    ),
                    if (showMore) ...[
                      const SizedBox(width: 6),
                      IconButton.filledTonal(
                        style: _compactTonalStyle(),
                        tooltip: '更多',
                        onPressed: () {
                          HapticFeedback.selectionClick();
                          _showNowPlayingActionsSheet(
                            context: context,
                            controller: controller,
                            np: np,
                          );
                        },
                        icon: const Icon(Icons.more_horiz_rounded, size: 22),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MiniPlayPause extends StatelessWidget {
  const _MiniPlayPause({required this.controller, this.compact = false});
  final _AppController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final controlSize =
        compact ? _NowPlayingMiniBar._compactPrimaryControlSize : 48.0;
    final iconSize = compact ? 23.0 : 24.0;
    final indicatorSize = compact ? 16.0 : 18.0;
    return StreamBuilder<PlayerState>(
      stream: controller.playerStateStream,
      builder: (context, snap) {
        final playing = snap.data?.playing ?? false;
        final processing = snap.data?.processingState ?? ProcessingState.idle;
        final busy = processing == ProcessingState.loading ||
            processing == ProcessingState.buffering;
        return IconButton.filled(
          style: IconButton.styleFrom(
            minimumSize: Size.square(controlSize),
            maximumSize: Size.square(controlSize),
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
          tooltip: playing ? '暂停' : '播放',
          onPressed: busy
              ? null
              : () async {
                  HapticFeedback.selectionClick();
                  if (playing) {
                    await controller.pause();
                  } else {
                    await controller.play();
                  }
                },
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) =>
                ScaleTransition(scale: anim, child: child),
            child: busy
                ? SizedBox(
                    key: const ValueKey<String>('busy'),
                    width: indicatorSize,
                    height: indicatorSize,
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    key: ValueKey<bool>(playing),
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: iconSize,
                  ),
          ),
        );
      },
    );
  }
}

class _MiniProgress extends StatelessWidget {
  const _MiniProgress({required this.controller});
  final _AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return StreamBuilder<Duration?>(
      stream: controller.durationStream,
      builder: (context, durSnap) {
        final duration = durSnap.data ?? Duration.zero;
        final maxMs = duration.inMilliseconds <= 0
            ? 1.0
            : duration.inMilliseconds.toDouble();
        return StreamBuilder<Duration>(
          stream: controller.positionStream,
          builder: (context, posSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final posMs = pos.inMilliseconds.toDouble().clamp(0.0, maxMs);
            final progress = (posMs / maxMs).clamp(0.0, 1.0);
            return ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: TweenAnimationBuilder<double>(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                tween: Tween<double>(
                  begin: 0,
                  end: progress.isFinite ? progress : 0,
                ),
                builder: (context, v, _) {
                  return LinearProgressIndicator(
                    value: v,
                    minHeight: 3,
                    backgroundColor:
                        _withOpacityCompat(cs.onSurfaceVariant, 0.16),
                    valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _NowPlayingSheet extends StatelessWidget {
  const _NowPlayingSheet({required this.controller, required this.np});

  final _AppController controller;
  final _NowPlaying np;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final w = MediaQuery.of(context).size.width;
    final coverSize = (w - 48).clamp(220.0, 360.0);
    final heroTag = _nowPlayingHeroTag(np.sourcePath);

    Widget cover() {
      final uri = np.artUri;
      return TweenAnimationBuilder<double>(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        tween: Tween<double>(begin: 0.0, end: 1.0),
        builder: (context, t, child) {
          return Opacity(
            opacity: t,
            child: Transform.scale(
              scale: lerpDouble(0.96, 1.0, t)!,
              child: child,
            ),
          );
        },
        child: Hero(
          tag: heroTag,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Container(
              width: coverSize,
              height: coverSize,
              color: cs.surfaceContainerHigh,
              child: uri == null
                  ? Icon(
                      Icons.album_rounded,
                      size: coverSize * 0.28,
                      color: cs.primary,
                    )
                  : Image.file(
                      File.fromUri(uri),
                      fit: BoxFit.cover,
                      cacheWidth: 1024,
                      cacheHeight: 1024,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.medium,
                    ),
            ),
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '正在播放',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                  ),
                  IconButton(
                    tooltip: '更多',
                    onPressed: () => _showNowPlayingActionsSheet(
                      context: context,
                      controller: controller,
                      np: np,
                    ),
                    icon: const Icon(Icons.more_horiz_rounded),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Center(child: cover()),
              const SizedBox(height: 16),
              Text(np.title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 6),
              Text(
                np.subtitle,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 18),
              _NowPlayingSeekBar(controller: controller),
              const SizedBox(height: 16),
              _NowPlayingControls(controller: controller),
              const SizedBox(height: 18),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.insert_drive_file_rounded, color: cs.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('文件',
                                style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 6),
                            SelectableText(
                              np.sourcePath,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '复制路径',
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: np.sourcePath),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已复制路径')),
                            );
                          }
                        },
                        icon: const Icon(Icons.copy_rounded),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NowPlayingSeekBar extends StatefulWidget {
  final _AppController controller;
  const _NowPlayingSeekBar({required this.controller});

  @override
  State<_NowPlayingSeekBar> createState() => _NowPlayingSeekBarState();
}

class _NowPlayingSeekBarState extends State<_NowPlayingSeekBar> {
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return StreamBuilder<Duration?>(
      stream: controller.durationStream,
      builder: (context, durSnap) {
        final duration = durSnap.data ?? Duration.zero;
        final maxMs = duration.inMilliseconds <= 0
            ? 1.0
            : duration.inMilliseconds.toDouble();
        return StreamBuilder<Duration>(
          stream: controller.positionStream,
          builder: (context, posSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final posMs = pos.inMilliseconds.toDouble().clamp(0.0, maxMs);
            final value = _dragMs ?? posMs;
            return Column(
              children: [
                Semantics(
                  label: '播放进度',
                  value:
                      '${controller._fmt(Duration(milliseconds: posMs.round()))} / ${controller._fmt(duration)}',
                  child: Slider(
                    value: value.clamp(0.0, maxMs),
                    min: 0,
                    max: maxMs,
                    semanticFormatterCallback: (v) => controller._fmt(
                      Duration(
                        milliseconds: v.round().clamp(0, maxMs.toInt()),
                      ),
                    ),
                    onChangeStart: (_) => setState(() => _dragMs = value),
                    onChanged: (v) => setState(() => _dragMs = v),
                    onChangeEnd: (v) async {
                      setState(() => _dragMs = null);
                      await controller.seek(Duration(milliseconds: v.round()));
                    },
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(controller._fmt(Duration(milliseconds: posMs.round())),
                        style: Theme.of(context).textTheme.bodySmall),
                    Text(controller._fmt(duration),
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _NowPlayingControls extends StatelessWidget {
  final _AppController controller;
  const _NowPlayingControls({required this.controller});

  @override
  Widget build(BuildContext context) {
    const sideControlSize = 46.0;
    const centerControlSize = 58.0;

    return Center(
      child: StreamBuilder<PlayerState>(
        stream: controller.playerStateStream,
        builder: (context, snap) {
          final playing = snap.data?.playing ?? false;
          final processing = snap.data?.processingState ?? ProcessingState.idle;
          final busy = processing == ProcessingState.loading ||
              processing == ProcessingState.buffering;

          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.filledTonal(
                tooltip: '上一首',
                style: IconButton.styleFrom(
                  minimumSize: const Size.square(sideControlSize),
                  maximumSize: const Size.square(sideControlSize),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: controller.canPlayPreviousTrack
                    ? () {
                        HapticFeedback.selectionClick();
                        controller.playPreviousTrack();
                      }
                    : null,
                icon: const Icon(Icons.skip_previous_rounded, size: 24),
              ),
              const SizedBox(width: 10),
              Semantics(
                button: true,
                label: playing ? '暂停' : '播放',
                child: Tooltip(
                  message: playing ? '暂停' : '播放',
                  child: IconButton.filled(
                    style: IconButton.styleFrom(
                      minimumSize: const Size.square(centerControlSize),
                      maximumSize: const Size.square(centerControlSize),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: busy
                        ? null
                        : () async {
                            HapticFeedback.selectionClick();
                            if (playing) {
                              await controller.pause();
                            } else {
                              await controller.play();
                            }
                          },
                    icon: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, anim) =>
                          ScaleTransition(scale: anim, child: child),
                      child: busy
                          ? const SizedBox(
                              key: ValueKey<String>('busy'),
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              key: ValueKey<bool>(playing),
                              playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: 30,
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filledTonal(
                tooltip: '下一首',
                style: IconButton.styleFrom(
                  minimumSize: const Size.square(sideControlSize),
                  maximumSize: const Size.square(sideControlSize),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: controller.canPlayNextTrack
                    ? () {
                        HapticFeedback.selectionClick();
                        controller.playNextTrack();
                      }
                    : null,
                icon: const Icon(Icons.skip_next_rounded, size: 24),
              ),
            ],
          );
        },
      ),
    );
  }
}

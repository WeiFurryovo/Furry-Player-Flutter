part of '../main.dart';

class ConverterPage extends StatefulWidget {
  final _AppController controller;
  const ConverterPage({super.key, required this.controller});

  @override
  State<ConverterPage> createState() => _ConverterPageState();
}

class _ConverterPageState extends State<ConverterPage> {
  late final ValueNotifier<double> _paddingDraftKb;

  @override
  void initState() {
    super.initState();
    _paddingDraftKb =
        ValueNotifier<double>(widget.controller.paddingKb.toDouble());
  }

  @override
  void didUpdateWidget(covariant ConverterPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _paddingDraftKb.value = widget.controller.paddingKb.toDouble();
    }
  }

  @override
  void dispose() {
    _paddingDraftKb.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final cs = Theme.of(context).colorScheme;

    return CustomScrollView(
      slivers: [
        SliverAppBar.large(
          title: const Text('转换'),
          actions: const [SizedBox(width: 8)],
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          sliver: SliverToBoxAdapter(
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.lock_rounded, color: cs.primary),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text('打包（音频 → .furry）'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '把音频封装成 .furry（含封面与标签），用于快速导入与统一管理。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () async {
                            await controller.pickForPack();
                            setState(() {});
                          },
                          icon: const Icon(Icons.audio_file_rounded),
                          label: const Text('选择音频'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: controller.pickedForPack == null
                              ? null
                              : controller.startPack,
                          icon: const Icon(Icons.auto_fix_high_rounded),
                          label: const Text('打包'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainer,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.insert_drive_file_rounded,
                              color: cs.onSurfaceVariant),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              controller.pickedForPackName == null
                                  ? '未选择输入文件'
                                  : '输入：${controller.pickedForPackName}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        const Text('Padding (KB)'),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ValueListenableBuilder<double>(
                            valueListenable: _paddingDraftKb,
                            builder: (context, draft, _) {
                              final clamped =
                                  draft.clamp(0.0, 1024.0).toDouble();
                              final rounded = clamped.round();
                              return Slider(
                                value: clamped,
                                min: 0,
                                max: 1024,
                                divisions: null,
                                label: '$rounded KB',
                                onChanged: (v) {
                                  _paddingDraftKb.value = v;
                                  controller.paddingKb = v.round();
                                },
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                    ValueListenableBuilder<double>(
                      valueListenable: _paddingDraftKb,
                      builder: (context, draft, _) => Text(
                        '当前 padding: ${draft.clamp(0.0, 1024.0).round()} KB',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          sliver: SliverToBoxAdapter(
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.play_circle_rounded, color: cs.primary),
                        const SizedBox(width: 10),
                        const Expanded(child: Text('临时播放')),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '从文件选择器中选一个音频或 .furry 立即播放。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: () async {
                            final f = await controller.pickForPlay();
                            if (f == null) return;
                            await controller.playFile(file: f);
                          },
                          icon: const Icon(Icons.folder_open_rounded),
                          label: const Text('选择并播放'),
                        ),
                        OutlinedButton.icon(
                          onPressed: controller.stop,
                          icon: const Icon(Icons.stop_rounded),
                          label: const Text('停止'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(child: _BottomOverlaySpacer(controller: controller)),
      ],
    );
  }
}

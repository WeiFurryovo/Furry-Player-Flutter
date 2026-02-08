part of '../main.dart';

class SettingsPage extends StatelessWidget {
  final _AppController controller;
  const SettingsPage({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return CustomScrollView(
      slivers: [
        const SliverAppBar.large(title: Text('设置')),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
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
                        Icon(Icons.bug_report_rounded, color: cs.primary),
                        const SizedBox(width: 10),
                        const Expanded(child: Text('诊断日志')),
                        IconButton(
                          tooltip: '复制',
                          onPressed: () async {
                            final text = controller.log.value;
                            if (text.trim().isEmpty) return;
                            await Clipboard.setData(ClipboardData(text: text));
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已复制诊断日志')),
                              );
                            }
                          },
                          icon: const Icon(Icons.copy_rounded),
                        ),
                        IconButton(
                          tooltip: '清空',
                          onPressed: () async {
                            await controller.clearLog();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已清空诊断日志')),
                              );
                            }
                          },
                          icon: const Icon(Icons.delete_outline_rounded),
                        ),
                        IconButton(
                          tooltip: '导出',
                          onPressed: () async {
                            final path = await controller.exportLog();
                            if (!context.mounted) return;
                            if (path == null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('导出失败')),
                              );
                              return;
                            }
                            await Clipboard.setData(ClipboardData(text: path));
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('已导出（路径已复制到剪贴板）'),
                                ),
                              );
                            }
                          },
                          icon: const Icon(Icons.file_upload_outlined),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '用于排查闪退/卡顿等问题（持久化保存，重启不会丢）。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainer,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: ValueListenableBuilder<String>(
                        valueListenable: controller.log,
                        builder: (context, log, _) {
                          return SelectableText(
                            log.isEmpty ? '(empty)' : log,
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      fontFamily: 'monospace',
                                      color: cs.onSurfaceVariant,
                                    ),
                          );
                        },
                      ),
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

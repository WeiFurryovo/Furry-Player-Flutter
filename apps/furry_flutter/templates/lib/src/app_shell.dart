part of '../main.dart';

class _BottomOverlayLayout {
  final bool showBottomNav;
  final double bottomOverlayBaseline;
  final double spacerHeight;

  const _BottomOverlayLayout({
    required this.showBottomNav,
    required this.bottomOverlayBaseline,
    required this.spacerHeight,
  });
}

_BottomOverlayLayout _computeBottomOverlayLayout({
  required bool useRail,
  required bool keyboardVisible,
  required bool hasNowPlaying,
  required double navBarHeight,
  required double bottomInset,
  required double keyboardInset,
  required double bottomNavMarginBottom,
  required double miniHeight,
  required double miniGap,
  required double extraGap,
}) {
  final showBottomNav = !useRail && !keyboardVisible;
  final bottomOverlayBaseline = keyboardVisible
      ? keyboardInset
      : (useRail
          ? bottomInset
          : navBarHeight + bottomInset + bottomNavMarginBottom);

  final mini = (keyboardVisible || !hasNowPlaying) ? 0.0 : miniHeight;
  final gap = keyboardVisible ? 12.0 : (miniGap + extraGap);

  return _BottomOverlayLayout(
    showBottomNav: showBottomNav,
    bottomOverlayBaseline: bottomOverlayBaseline,
    spacerHeight: bottomOverlayBaseline + mini + gap,
  );
}

@visibleForTesting
class BottomOverlayLayoutHarness {
  static ({bool showBottomNav, double baseline, double spacerHeight}) compute({
    required bool useRail,
    required bool keyboardVisible,
    required bool hasNowPlaying,
    required double navBarHeight,
    required double bottomInset,
    required double keyboardInset,
    required double bottomNavMarginBottom,
    required double miniHeight,
    required double miniGap,
    required double extraGap,
  }) {
    final layout = _computeBottomOverlayLayout(
      useRail: useRail,
      keyboardVisible: keyboardVisible,
      hasNowPlaying: hasNowPlaying,
      navBarHeight: navBarHeight,
      bottomInset: bottomInset,
      keyboardInset: keyboardInset,
      bottomNavMarginBottom: bottomNavMarginBottom,
      miniHeight: miniHeight,
      miniGap: miniGap,
      extraGap: extraGap,
    );
    return (
      showBottomNav: layout.showBottomNav,
      baseline: layout.bottomOverlayBaseline,
      spacerHeight: layout.spacerHeight,
    );
  }
}

/// 应用主壳（3 个主 tab + 自定义底部导航 + 迷你播放器浮层）。
///
/// - 窄屏：底部导航（自定义 Expressive 样式，减少无效留白）
/// - 宽屏：NavigationRail
/// - `NowPlayingPanel` 作为底部浮层，始终保持在页面内容上方
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.player});

  final AudioPlayer player;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  late final _AppController _controller;
  int _tabIndex = 0;
  static const double _wideRailBreakpoint = 700;
  static const double _bottomNavMarginH = 16;
  static const double _bottomNavMarginBottom = 4;

  void _onRequestedTab() {
    final idx = _controller.requestedTab.value;
    if (idx == null) return;
    _controller.requestedTab.value = null;
    if (!mounted) return;
    setState(() => _tabIndex = idx.clamp(0, 2));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = _AppController(widget.player);
    _controller.requestedTab.addListener(_onRequestedTab);
    _controller.init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.requestedTab.removeListener(_onRequestedTab);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controller.appendLog('Lifecycle: $state');
  }

  @override
  Widget build(BuildContext context) {
    final navItems = <_NavItem>[
      const _NavItem(
        label: '本地',
        icon: Icons.library_music_outlined,
        selectedIcon: Icons.library_music,
      ),
      const _NavItem(
        label: '转换',
        icon: Icons.swap_horiz_outlined,
        selectedIcon: Icons.swap_horiz,
      ),
      const _NavItem(
        label: '设置',
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings,
      ),
    ];

    final mediaQuery = MediaQuery.of(context);
    final navBarHeight = NavigationBarTheme.of(context).height ?? 80.0;
    final bottomInset = mediaQuery.padding.bottom;
    final keyboardInset = mediaQuery.viewInsets.bottom;
    final keyboardVisible = keyboardInset > 0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final useRail = constraints.maxWidth >= _wideRailBreakpoint;
        final pages = <Widget>[
          LibraryPage(controller: _controller),
          ConverterPage(controller: _controller),
          SettingsPage(controller: _controller),
        ];

        final layout = _computeBottomOverlayLayout(
          useRail: useRail,
          keyboardVisible: keyboardVisible,
          hasNowPlaying: false,
          navBarHeight: navBarHeight,
          bottomInset: bottomInset,
          keyboardInset: keyboardInset,
          bottomNavMarginBottom: _bottomNavMarginBottom,
          miniHeight: NowPlayingPanel.miniHeightPx,
          miniGap: NowPlayingPanel.miniGapPx,
          extraGap: _BottomOverlaySpacer.extraGap,
        );
        final showBottomNav = layout.showBottomNav;
        final bottomOverlayBaseline = layout.bottomOverlayBaseline;

        Widget contentStack() {
          return Stack(
            children: [
              SafeArea(
                top: false,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: IndexedStack(
                    key: ValueKey<int>(_tabIndex),
                    index: _tabIndex,
                    children: pages,
                  ),
                ),
              ),
              Positioned.fill(
                child: NowPlayingPanel(
                  controller: _controller,
                  bottomOverlayBaseline: bottomOverlayBaseline,
                  hideDuringTextInput: keyboardVisible,
                ),
              ),
            ],
          );
        }

        if (useRail) {
          final railDestinations = navItems
              .map(
                (d) => NavigationRailDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selectedIcon),
                  label: Text(d.label),
                ),
              )
              .toList(growable: false);

          return Scaffold(
            body: Row(
              children: [
                SafeArea(
                  child: NavigationRail(
                    selectedIndex: _tabIndex,
                    onDestinationSelected: (i) => setState(() => _tabIndex = i),
                    labelType: NavigationRailLabelType.all,
                    destinations: railDestinations,
                  ),
                ),
                Expanded(
                  child: contentStack(),
                ),
              ],
            ),
          );
        }

        return Scaffold(
          extendBody: true,
          body: Stack(
            children: [
              contentStack(),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  ignoring: !showBottomNav,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    offset: showBottomNav ? Offset.zero : const Offset(0, 1.12),
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      opacity: showBottomNav ? 1 : 0,
                      child: _ExpressiveBottomNavBar(
                        selectedIndex: _tabIndex,
                        items: navItems,
                        onDestinationSelected: (i) =>
                            setState(() => _tabIndex = i),
                        marginH: _bottomNavMarginH,
                        marginBottom: _bottomNavMarginBottom,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NavItem {
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  const _NavItem({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });
}

/// 自定义的 M3 Expressive 底部导航栏。
///
/// Flutter 的 `NavigationBar` 在某些布局下会带来较大的内部留白（尤其顶部），
/// 且 icon/label 的位置不易精细控制。这里使用自定义 layout：
/// - 保留 label（提升可读性）
/// - 不下移 icon（保持稳定的视觉锚点）
/// - 通过轻微阴影与 `surfaceContainer` 强化“悬浮”层级
class _ExpressiveBottomNavBar extends StatelessWidget {
  const _ExpressiveBottomNavBar({
    required this.selectedIndex,
    required this.items,
    required this.onDestinationSelected,
    required this.marginH,
    required this.marginBottom,
  });

  final int selectedIndex;
  final List<_NavItem> items;
  final ValueChanged<int> onDestinationSelected;
  final double marginH;
  final double marginBottom;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final navBarHeight = NavigationBarTheme.of(context).height ?? 80.0;
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final navTheme = NavigationBarTheme.of(context);
    final indicatorColor = navTheme.indicatorColor ?? cs.secondaryContainer;
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: cs.onSurfaceVariant,
        );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        marginH,
        0,
        marginH,
        marginBottom + bottomInset,
      ),
      child: Material(
        elevation: 2,
        color: cs.surfaceContainer,
        surfaceTintColor: cs.surfaceTint,
        shadowColor: _withOpacityCompat(cs.shadow, 0.22),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(26),
          side: BorderSide(color: _withOpacityCompat(cs.outlineVariant, 0.55)),
        ),
        clipBehavior: Clip.antiAlias,
        // Custom layout to reduce only the top in-bar whitespace while keeping
        // icon positions stable and showing labels.
        child: SizedBox(
          height: navBarHeight,
          child: Padding(
            // Reduce only the top in-bar whitespace (circled by the user) while
            // keeping icon positions from shifting downward and still showing
            // labels.
            // Keep symmetric vertical padding (top == bottom).
            padding: const EdgeInsets.fromLTRB(10, 3, 10, 3),
            child: Row(
              children: [
                for (var i = 0; i < items.length; i++)
                  Expanded(
                    child: _NavItemButton(
                      selected: i == selectedIndex,
                      item: items[i],
                      indicatorColor: indicatorColor,
                      labelStyle: labelStyle,
                      onTap: () => onDestinationSelected(i),
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

class _NavItemButton extends StatelessWidget {
  const _NavItemButton({
    required this.selected,
    required this.item,
    required this.indicatorColor,
    required this.labelStyle,
    required this.onTap,
  });

  final bool selected;
  final _NavItem item;
  final Color indicatorColor;
  final TextStyle? labelStyle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final iconColor = selected ? cs.onSecondaryContainer : cs.onSurfaceVariant;
    final textColor = selected ? cs.onSurface : cs.onSurfaceVariant;
    final effectiveLabelStyle =
        (labelStyle ?? Theme.of(context).textTheme.labelMedium)?.copyWith(
      color: textColor,
    );

    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 5),
          decoration: BoxDecoration(
            color: selected ? indicatorColor : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                selected ? item.selectedIcon : item.icon,
                color: iconColor,
                size: 22,
              ),
              const SizedBox(height: 3),
              Text(item.label, style: effectiveLabelStyle),
            ],
          ),
        ),
      ),
    );
  }
}

/// 给 `CustomScrollView` 的底部留出空间，避免内容被：
/// - 底部导航栏
/// - 迷你播放器
/// 覆盖。
class _BottomOverlaySpacer extends StatelessWidget {
  const _BottomOverlaySpacer({required this.controller});

  final _AppController controller;
  static const double extraGap = 16;
  static const double _wideRailBreakpoint = 700;
  static const double _miniHeight = NowPlayingPanel.miniHeightPx;
  static const double _miniGap = NowPlayingPanel.miniGapPx;
  static const double _bottomNavMarginBottom =
      _AppShellState._bottomNavMarginBottom;

  @override
  Widget build(BuildContext context) {
    final navBarHeight = NavigationBarTheme.of(context).height ?? 80.0;
    final mediaQuery = MediaQuery.of(context);
    final bottomInset = mediaQuery.padding.bottom;
    final keyboardInset = mediaQuery.viewInsets.bottom;
    final keyboardVisible = keyboardInset > 0;

    return ValueListenableBuilder<_NowPlaying?>(
      valueListenable: controller.nowPlaying,
      builder: (context, np, _) {
        final useRail = mediaQuery.size.width >= _wideRailBreakpoint;
        final layout = _computeBottomOverlayLayout(
          useRail: useRail,
          keyboardVisible: keyboardVisible,
          hasNowPlaying: np != null,
          navBarHeight: navBarHeight,
          bottomInset: bottomInset,
          keyboardInset: keyboardInset,
          bottomNavMarginBottom: _bottomNavMarginBottom,
          miniHeight: _miniHeight,
          miniGap: _miniGap,
          extraGap: extraGap,
        );
        return SizedBox(height: layout.spacerHeight);
      },
    );
  }
}

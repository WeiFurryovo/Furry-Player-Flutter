part of '../main.dart';

/// Material 3 Expressive 主题构建器（全局风格入口）。
///
/// 该类集中定义：
/// - typography（更强调标题权重与紧凑字距）
/// - component themes（SearchBar、BottomSheet、Slider、SnackBar 等）
/// - Expressive 常用圆角与容器色
class _ExpressiveTheme {
  static TextTheme _fontFamilyWithFallback(
    TextTheme theme, {
    required String fontFamily,
    required List<String> fallback,
  }) {
    TextStyle? patch(TextStyle? style) => style?.copyWith(
          fontFamily: fontFamily,
          fontFamilyFallback: fallback,
        );

    return theme.copyWith(
      displayLarge: patch(theme.displayLarge),
      displayMedium: patch(theme.displayMedium),
      displaySmall: patch(theme.displaySmall),
      headlineLarge: patch(theme.headlineLarge),
      headlineMedium: patch(theme.headlineMedium),
      headlineSmall: patch(theme.headlineSmall),
      titleLarge: patch(theme.titleLarge),
      titleMedium: patch(theme.titleMedium),
      titleSmall: patch(theme.titleSmall),
      bodyLarge: patch(theme.bodyLarge),
      bodyMedium: patch(theme.bodyMedium),
      bodySmall: patch(theme.bodySmall),
      labelLarge: patch(theme.labelLarge),
      labelMedium: patch(theme.labelMedium),
      labelSmall: patch(theme.labelSmall),
    );
  }

  static ThemeData build(
    Brightness brightness, {
    ColorScheme? schemeOverride,
  }) {
    const seed = Color(0xFF8E7CFF);
    final scheme = schemeOverride ??
        ColorScheme.fromSeed(seedColor: seed, brightness: brightness);

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // Prefer system Google Sans when available; otherwise fall back to
      // a bundled Google Fonts alternative for consistent rendering.
      fontFamily: 'Google Sans',
    );

    final tt = _fontFamilyWithFallback(
      GoogleFonts.interTextTheme(base.textTheme),
      fontFamily: 'Google Sans',
      fallback: const <String>['Inter', 'Roboto'],
    );
    final textTheme = tt.copyWith(
      displaySmall: tt.displaySmall?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.6,
        height: 1.05,
      ),
      headlineSmall: tt.headlineSmall?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4,
        height: 1.10,
      ),
      titleLarge: tt.titleLarge?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.2,
      ),
      titleMedium: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      labelLarge: tt.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    );

    const r24 = BorderRadius.all(Radius.circular(24));
    const r20 = BorderRadius.all(Radius.circular(20));
    const r16 = BorderRadius.all(Radius.circular(16));

    return base.copyWith(
      textTheme: textTheme,
      primaryTextTheme: _fontFamilyWithFallback(
        GoogleFonts.interTextTheme(base.primaryTextTheme),
        fontFamily: 'Google Sans',
        fallback: const <String>['Inter', 'Roboto'],
      ),
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        scrolledUnderElevation: 1,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
      ),
      listTileTheme: ListTileThemeData(
        shape: const RoundedRectangleBorder(borderRadius: r20),
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 66,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.secondaryContainer,
        indicatorShape: const StadiumBorder(),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.secondaryContainer,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.all(8),
          minimumSize: const Size(40, 40),
          maximumSize: const Size(44, 44),
        ),
      ),
      searchBarTheme: SearchBarThemeData(
        shape: const WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: r24),
        ),
        elevation: const WidgetStatePropertyAll<double>(0),
        backgroundColor: WidgetStatePropertyAll<Color>(scheme.surfaceContainer),
        textStyle: WidgetStatePropertyAll<TextStyle?>(
          textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        hintStyle: WidgetStatePropertyAll<TextStyle?>(
          textTheme.titleMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
      sliderTheme: base.sliderTheme.copyWith(
        trackHeight: 4,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
        valueIndicatorShape: const PaddleSliderValueIndicatorShape(),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        showDragHandle: true,
        backgroundColor: scheme.surface,
        modalBackgroundColor: scheme.surface,
        shape: const RoundedRectangleBorder(borderRadius: r24),
        clipBehavior: Clip.antiAlias,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        shape: const RoundedRectangleBorder(borderRadius: r16),
      ),
    );
  }
}

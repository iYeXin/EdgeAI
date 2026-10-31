import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Edge AI visual baseline.
/// A warm, light canvas with a single maroon accent.
abstract final class AppColors {
  static const primary = Color(0xFF923326);
  static const primaryStrong = Color(0xFF7A2A1F);
  static const primaryDeep = Color(0xFF5D1F17);
  static const primaryWash = Color(0xFFF7EDEB);
  static const sky = Color(0xFFD8C0B9);
  static const skySoft = Color(0xFFF2E5E1);

  static const ink = Color(0xFF242021);
  static const inkSoft = Color(0xFF4B4344);
  static const muted = Color(0xFF7F7475);
  static const faint = Color(0xFFA39797);

  static const background = Color(0xFFF5F4F3);
  static const backgroundDeep = Color(0xFFEBE7E5);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceTint = Color(0xFFFAF8F7);
  static const line = Color(0xFFE8E2DF);
  static const lineStrong = Color(0xFFD9D0CC);

  static const green = Color(0xFF2D8A67);
  static const greenSoft = Color(0xFFE8F4EF);
  static const amber = Color(0xFFB9852F);
  static const amberSoft = Color(0xFFFBF3E6);
  static const red = Color(0xFFB23A3A);
  static const redSoft = Color(0xFFF9ECEC);
  static const violet = Color(0xFF6F7FB9);
  static const violetSoft = Color(0xFFEDF0F9);
}

abstract final class AppShadows {
  static const card = [
    BoxShadow(color: Color(0x0A2B1F1C), blurRadius: 14, offset: Offset(0, 3)),
  ];
  static const floating = [
    BoxShadow(color: Color(0x1A1C1210), blurRadius: 22, offset: Offset(0, 8)),
  ];
}

abstract final class AppRadius {
  static const xs = 6.0;
  static const sm = 8.0;
  static const md = 10.0;
  static const lg = 12.0;
  static const xl = 14.0;
  static const pill = 999.0;
}

const _fallback = <String>[
  'SF Pro Display',
  'PingFang SC',
  'Microsoft YaHei',
  'Noto Sans SC',
];

abstract final class AppText {
  static const display = TextStyle(
    color: AppColors.ink,
    fontSize: 24,
    height: 1.18,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    fontFamilyFallback: _fallback,
  );
  static const title = TextStyle(
    color: AppColors.ink,
    fontSize: 19,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
    fontFamilyFallback: _fallback,
  );
  static const section = TextStyle(
    color: AppColors.ink,
    fontSize: 15.5,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    fontFamilyFallback: _fallback,
  );
  static const body = TextStyle(
    color: AppColors.inkSoft,
    fontSize: 14,
    height: 1.45,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.05,
    fontFamilyFallback: _fallback,
  );
  static const bodyStrong = TextStyle(
    color: AppColors.ink,
    fontSize: 14,
    height: 1.4,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    fontFamilyFallback: _fallback,
  );
  static const small = TextStyle(
    color: AppColors.muted,
    fontSize: 12,
    height: 1.42,
    fontWeight: FontWeight.w400,
    fontFamilyFallback: _fallback,
  );
  static const smallStrong = TextStyle(
    color: AppColors.inkSoft,
    fontSize: 12,
    height: 1.4,
    fontWeight: FontWeight.w600,
    fontFamilyFallback: _fallback,
  );
  static const micro = TextStyle(
    color: AppColors.muted,
    fontSize: 10.5,
    height: 1.3,
    fontWeight: FontWeight.w500,
    fontFamilyFallback: _fallback,
  );
  static const overline = TextStyle(
    color: AppColors.faint,
    fontSize: 9.5,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.15,
    fontFamilyFallback: _fallback,
  );
  static const button = TextStyle(
    color: Colors.white,
    fontSize: 14,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.05,
    fontFamilyFallback: _fallback,
  );
  static const mono = TextStyle(
    color: AppColors.inkSoft,
    fontSize: 12,
    height: 1.55,
    fontWeight: FontWeight.w400,
    fontFamilyFallback: ['SF Mono', 'SFMono-Regular', 'Menlo', 'Consolas'],
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const monoSmall = TextStyle(
    color: AppColors.muted,
    fontSize: 10.5,
    height: 1.4,
    fontWeight: FontWeight.w500,
    fontFamilyFallback: ['SF Mono', 'SFMono-Regular', 'Menlo', 'Consolas'],
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

abstract final class AppTheme {
  static ThemeData material() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: AppColors.primary,
          brightness: Brightness.light,
        ).copyWith(
          primary: AppColors.primary,
          onPrimary: Colors.white,
          secondary: AppColors.primaryStrong,
          surface: AppColors.surface,
          onSurface: AppColors.ink,
          error: AppColors.red,
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.background,
      canvasColor: AppColors.background,
      dividerColor: AppColors.line,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      textTheme: const TextTheme(
        displaySmall: AppText.display,
        titleLarge: AppText.title,
        titleMedium: AppText.section,
        bodyLarge: AppText.body,
        bodyMedium: AppText.body,
        bodySmall: AppText.small,
        labelLarge: AppText.button,
        labelSmall: AppText.overline,
      ).apply(bodyColor: AppColors.ink, displayColor: AppColors.ink),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        foregroundColor: AppColors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: AppColors.surface,
        modalBarrierColor: Color(0x66241C1B),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        hintStyle: AppText.body.copyWith(color: AppColors.faint),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.3),
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: AppColors.primary,
        thumbColor: AppColors.primary,
        inactiveTrackColor: AppColors.lineStrong,
        overlayColor: AppColors.primary.withValues(alpha: 0.10),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : AppColors.faint,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.primary
              : AppColors.lineStrong,
        ),
      ),
    );
  }
}

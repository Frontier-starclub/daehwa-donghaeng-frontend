/// 고령자 UX 토큰.
///
/// 화면설계서 v2.1 "적용한 고령자 UX 원칙"의 수치를 코드로 고정한 것이다.
/// 화면마다 크기를 직접 적지 말고 반드시 이 값을 쓴다 — 39개 화면이 제각각
/// 커지고 작아지는 것을 막는 유일한 장치다.
library;

import 'package:flutter/material.dart';

abstract final class AppSpacing {
  /// 요소 간 최소 간격. 터치 영역이 겹치지 않게 하는 하한이다.
  static const double min = 14;
  static const double sm = 14;
  static const double md = 20;
  static const double lg = 28;
  static const double xl = 40;

  /// 화면 좌우 여백.
  static const double screenH = 20;
}

abstract final class AppTypography {
  /// 본문 20px.
  static const double body = 20;

  /// 핵심 안내 22~27px.
  static const double headline = 27;
  static const double title = 22;

  /// 버튼 라벨 22px.
  static const double button = 22;

  /// 보조 설명. 본문보다 작지만 16px 아래로 내리지 않는다.
  static const double caption = 17;
}

abstract final class AppSizing {
  /// 주요 버튼 높이 72px 이상, 가로폭 전체.
  static const double primaryButtonHeight = 72;

  /// 최소 터치 타깃. 아이콘 버튼도 이 아래로 두지 않는다.
  static const double minTouchTarget = 56;

  static const double radius = 12;
  static const double borderWidth = 2;
  static const double illustrationSize = 96;
  static const double photoPreviewHeight = 320;
}

abstract final class AppColors {
  static const Color primary = Color(0xFF1B5E9C);
  static const Color onPrimary = Color(0xFFFFFFFF);

  static const Color surface = Color(0xFFFFFFFF);
  static const Color background = Color(0xFFF7F7F5);
  static const Color onSurface = Color(0xFF1A1A1A);
  static const Color onSurfaceMuted = Color(0xFF5A5A5A);

  /// 주의 정보용. 색상에만 의존하지 않는다 — 반드시 아이콘·테두리·문구를 함께 쓴다.
  /// (화면설계서 "주의 정보 인지" 원칙)
  static const Color warning = Color(0xFF9C4A00);
  static const Color warningSurface = Color(0xFFFDF0E4);
  static const Color safe = Color(0xFF1F6B36);
  static const Color safeSurface = Color(0xFFE9F4EC);

  static const Color border = Color(0xFFCFCFC9);
}

/// 앱 전역 테마.
///
/// `textScaler`를 앱에서 고정하지 않는다 — 사용자가 OS에서 글자를 더 키웠다면
/// 그 설정을 존중해야 한다. 대신 레이아웃이 확대에 견디도록 만든다.
ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      primary: AppColors.primary,
      surface: AppColors.surface,
    ),
    scaffoldBackgroundColor: AppColors.background,
  );

  return base.copyWith(
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize:
            const Size(AppSizing.minTouchTarget, AppSizing.minTouchTarget),
        textStyle: const TextStyle(
          fontSize: AppTypography.body,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      labelStyle: TextStyle(fontSize: AppTypography.body),
      helperStyle: TextStyle(fontSize: AppTypography.caption),
      errorStyle: TextStyle(fontSize: AppTypography.caption),
      helperMaxLines: 3,
      errorMaxLines: 3,
    ),
    textTheme: base.textTheme.copyWith(
      headlineLarge: const TextStyle(
        fontSize: AppTypography.headline,
        fontWeight: FontWeight.w700,
        height: 1.35,
        color: AppColors.onSurface,
      ),
      titleLarge: const TextStyle(
        fontSize: AppTypography.title,
        fontWeight: FontWeight.w700,
        height: 1.4,
        color: AppColors.onSurface,
      ),
      bodyLarge: const TextStyle(
        fontSize: AppTypography.body,
        height: 1.5,
        color: AppColors.onSurface,
      ),
      bodyMedium: const TextStyle(
        fontSize: AppTypography.caption,
        height: 1.5,
        color: AppColors.onSurfaceMuted,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(AppSizing.primaryButtonHeight),
        textStyle: const TextStyle(
          fontSize: AppTypography.button,
          fontWeight: FontWeight.w700,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSizing.radius),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(AppSizing.primaryButtonHeight),
        textStyle: const TextStyle(
          fontSize: AppTypography.button,
          fontWeight: FontWeight.w700,
        ),
        side: const BorderSide(
          color: AppColors.primary,
          width: AppSizing.borderWidth,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSizing.radius),
        ),
      ),
    ),
  );
}

import 'package:flutter/material.dart';

class AppTheme {
  static const Color primary = Color(0xFF6E8EFB);
  static const Color secondary = Color(0xFFA777E3);
  static const Color background = Color(0xFFF5F7FA);
  static const Color inputBackground = Color(0xFFF9FAFC);
  static const Color line = Color(0xFFE1E5EB);
  static const Color softLine = Color(0xFFF0F2F5);
  static const Color textDark = Color(0xFF333333);
  static const Color textMedium = Color(0xFF666666);
  static const Color textLight = Color(0xFF8A94A6);
  static const Color danger = Color(0xFFE74C3C);
  static const Color success = Color(0xFF52C41A);

  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primary, secondary],
  );

  static ThemeData light() {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: background,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primary,
        brightness: Brightness.light,
        primary: primary,
        secondary: secondary,
        surface: background,
      ),
      fontFamilyFallback: const [
        'PingFang SC',
        'Microsoft YaHei',
        'Helvetica Neue',
        'Arial',
      ],
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
          color: textDark,
          fontSize: 24,
          fontWeight: FontWeight.w600,
        ),
        titleLarge: TextStyle(
          color: textDark,
          fontSize: 22,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: TextStyle(
          color: textDark,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: TextStyle(color: textMedium, fontSize: 16),
        bodyMedium: TextStyle(color: textMedium, fontSize: 14),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inputBackground,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: secondary),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFFF4D4F)),
        ),
      ),
    );
  }
}

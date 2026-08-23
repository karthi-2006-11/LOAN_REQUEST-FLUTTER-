import 'package:flutter/material.dart';

/// Centralized color palette for the Loan Request App.
/// Designed for a premium, professional fintech aesthetic.
class AppColors {
  AppColors._();

  // Brand Colors
  static const Color primary = Color(0xFF2563EB); // Vibrant Royal Blue
  static const Color primaryDark = Color(0xFF1E3A8A); // Deep Navy
  static const Color primaryLight = Color(0xFF60A5FA); // Light Blue

  static const Color accent = Color(0xFF10B981); // Emerald Green
  static const Color accentLight = Color(0xFFD1FAE5); // Mint Tint
  static const Color accentDark = Color(0xFF047857); // Deep Emerald

  static const Color secondary = Color(0xFF4F46E5); // Indigo
  static const Color warning = Color(0xFFF59E0B); // Amber/Gold
  static const Color error = Color(0xFFEF4444); // Crimson Red
  static const Color success = Color(0xFF10B981); // Emerald

  // Dark Theme Surfaces
  static const Color darkBackground = Color(0xFF0F172A); // Slate 900
  static const Color darkSurface = Color(0xFF1E293B); // Slate 800
  static const Color darkCard = Color(0xFF1E293B);
  static const Color darkBorder = Color(0xFF334155);

  // Light Theme Surfaces
  static const Color lightBackground = Color(0xFFF8FAFC); // Slate 50
  static const Color lightSurface = Color(0xFFFFFFFF); // Pure White
  static const Color lightCard = Color(0xFFFFFFFF);
  static const Color lightBorder = Color(0xFFE2E8F0); // Slate 200

  // Text Colors
  static const Color textDarkPrimary = Color(0xFFF8FAFC);
  static const Color textDarkSecondary = Color(0xFF94A3B8);
  static const Color textLightPrimary = Color(0xFF0F172A);
  static const Color textLightSecondary = Color(0xFF64748B);

  // Gradients
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [Color(0xFF1E3A8A), Color(0xFF2563EB)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient accentGradient = LinearGradient(
    colors: [Color(0xFF059669), Color(0xFF10B981)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient heroGradient = LinearGradient(
    colors: [Color(0xFF0F172A), Color(0xFF1E3A8A)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
}

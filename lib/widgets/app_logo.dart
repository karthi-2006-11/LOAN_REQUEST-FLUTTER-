import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';

/// Professional Fintech BlackVault App Logo Widget.
class AppLogo extends StatelessWidget {
  final double size;
  final bool showText;
  final Color? textColor;

  const AppLogo({
    super.key,
    this.size = 72,
    this.showText = true,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: AppColors.primaryGradient,
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.35),
                blurRadius: 18,
                spreadRadius: 2,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Center(
            child: Icon(
              Icons.shield_rounded,
              size: size * 0.52,
              color: Colors.white,
            ),
          ),
        ),
        if (showText) ...[
          const SizedBox(height: 14),
          Text(
            'BLACKVAULT',
            style: TextStyle(
              fontSize: size * 0.34,
              fontWeight: FontWeight.w800,
              letterSpacing: 2.0,
              color: textColor ??
                  (isDark ? AppColors.textDarkPrimary : AppColors.primaryDark),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'SECURE LOANS. SMARTER DECISIONS.',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
              color: isDark
                  ? AppColors.textDarkSecondary
                  : AppColors.textLightSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

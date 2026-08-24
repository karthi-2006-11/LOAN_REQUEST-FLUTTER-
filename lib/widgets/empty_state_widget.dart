import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';
import 'custom_button.dart';

/// Reusable empty state widget displayed when no loans are present.
class EmptyStateWidget extends StatelessWidget {
  final String title;
  final String description;
  final String buttonText;
  final VoidCallback onActionPressed;

  const EmptyStateWidget({
    super.key,
    this.title = 'No Loan Requests Found',
    this.description =
        'You currently have no active or historical loan applications. Apply now for fast financial solutions.',
    this.buttonText = 'Apply for your first loan',
    required this.onActionPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primary.withValues(alpha: 0.1),
              ),
              child: const Icon(
                Icons.account_balance_wallet_outlined,
                size: 54,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: isDark
                    ? AppColors.textDarkPrimary
                    : AppColors.textLightPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: isDark
                    ? AppColors.textDarkSecondary
                    : AppColors.textLightSecondary,
              ),
            ),
            const SizedBox(height: 24),
            CustomButton(
              text: buttonText,
              icon: Icons.add_circle_outline_rounded,
              width: 240,
              onPressed: onActionPressed,
            ),
          ],
        ),
      ),
    );
  }
}

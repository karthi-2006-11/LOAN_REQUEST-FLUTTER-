import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';
import '../models/user_role.dart';

class RoleBadge extends StatelessWidget {
  final UserRole role;
  final bool isCompact;

  const RoleBadge({
    super.key,
    required this.role,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    final isAdmin = role.isAdmin;

    final bgColor = isAdmin
        ? const Color(0xFF8B5CF6).withValues(alpha: 0.15)
        : AppColors.primary.withValues(alpha: 0.15);

    final textColor = isAdmin
        ? const Color(0xFFA78BFA)
        : AppColors.primary;

    final icon = isAdmin ? Icons.admin_panel_settings_rounded : Icons.person_rounded;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? 8 : 12,
        vertical: isCompact ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: textColor.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: isCompact ? 12 : 14,
            color: textColor,
          ),
          const SizedBox(width: 4),
          Text(
            role.nameString.toUpperCase(),
            style: TextStyle(
              color: textColor,
              fontSize: isCompact ? 10 : 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';

/// Supported priority levels for a loan application request.
enum LoanPriority {
  low,
  medium,
  high,
}

extension LoanPriorityExtension on LoanPriority {
  String get label {
    switch (this) {
      case LoanPriority.low:
        return 'Low';
      case LoanPriority.medium:
        return 'Medium';
      case LoanPriority.high:
        return 'High';
    }
  }

  String get description {
    switch (this) {
      case LoanPriority.low:
        return 'Standard processing (5-7 business days)';
      case LoanPriority.medium:
        return 'Priority processing (2-3 business days)';
      case LoanPriority.high:
        return 'Urgent processing (24-48 hours)';
    }
  }

  Color get color {
    switch (this) {
      case LoanPriority.low:
        return AppColors.textLightSecondary;
      case LoanPriority.medium:
        return AppColors.primary;
      case LoanPriority.high:
        return const Color(0xFFE11D48); // Deep Rose/Red
    }
  }

  Color get backgroundColor {
    switch (this) {
      case LoanPriority.low:
        return Colors.grey.withValues(alpha: 0.15);
      case LoanPriority.medium:
        return AppColors.primary.withValues(alpha: 0.15);
      case LoanPriority.high:
        return const Color(0xFFE11D48).withValues(alpha: 0.15);
    }
  }

  IconData get icon {
    switch (this) {
      case LoanPriority.low:
        return Icons.arrow_downward_rounded;
      case LoanPriority.medium:
        return Icons.remove_rounded;
      case LoanPriority.high:
        return Icons.arrow_upward_rounded;
    }
  }

  static LoanPriority fromString(String priority) {
    switch (priority.toLowerCase()) {
      case 'high':
        return LoanPriority.high;
      case 'medium':
        return LoanPriority.medium;
      case 'low':
      default:
        return LoanPriority.low;
    }
  }

  String toJson() => name;
}

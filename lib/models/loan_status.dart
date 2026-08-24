import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';

/// Supported status states for a loan application.
enum LoanStatus {
  pending,
  approved,
  rejected,
}

extension LoanStatusExtension on LoanStatus {
  String get label {
    switch (this) {
      case LoanStatus.pending:
        return 'Pending';
      case LoanStatus.approved:
        return 'Approved';
      case LoanStatus.rejected:
        return 'Rejected';
    }
  }

  Color get color {
    switch (this) {
      case LoanStatus.pending:
        return AppColors.warning;
      case LoanStatus.approved:
        return AppColors.success;
      case LoanStatus.rejected:
        return AppColors.error;
    }
  }

  Color get backgroundColor {
    switch (this) {
      case LoanStatus.pending:
        return AppColors.warning.withValues(alpha: 0.15);
      case LoanStatus.approved:
        return AppColors.success.withValues(alpha: 0.15);
      case LoanStatus.rejected:
        return AppColors.error.withValues(alpha: 0.15);
    }
  }

  IconData get icon {
    switch (this) {
      case LoanStatus.pending:
        return Icons.hourglass_empty_rounded;
      case LoanStatus.approved:
        return Icons.check_circle_outline_rounded;
      case LoanStatus.rejected:
        return Icons.cancel_outlined;
    }
  }

  static LoanStatus fromString(String status) {
    switch (status.toLowerCase()) {
      case 'approved':
        return LoanStatus.approved;
      case 'rejected':
        return LoanStatus.rejected;
      case 'pending':
      default:
        return LoanStatus.pending;
    }
  }

  String toJson() => name;
}

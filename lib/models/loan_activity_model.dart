import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';

enum ActivityType {
  submitted,
  underReview,
  approved,
  rejected,
  cancelled,
}

extension ActivityTypeExtension on ActivityType {
  String get label {
    switch (this) {
      case ActivityType.submitted:
        return 'Submitted';
      case ActivityType.underReview:
        return 'Under Review';
      case ActivityType.approved:
        return 'Approved';
      case ActivityType.rejected:
        return 'Rejected';
      case ActivityType.cancelled:
        return 'Cancelled';
    }
  }

  Color get color {
    switch (this) {
      case ActivityType.submitted:
        return AppColors.primary;
      case ActivityType.underReview:
        return AppColors.warning;
      case ActivityType.approved:
        return AppColors.success;
      case ActivityType.rejected:
        return AppColors.error;
      case ActivityType.cancelled:
        return const Color(0xFF64748B);
    }
  }

  IconData get icon {
    switch (this) {
      case ActivityType.submitted:
        return Icons.send_rounded;
      case ActivityType.underReview:
        return Icons.hourglass_top_rounded;
      case ActivityType.approved:
        return Icons.check_circle_rounded;
      case ActivityType.rejected:
        return Icons.cancel_rounded;
      case ActivityType.cancelled:
        return Icons.block_rounded;
    }
  }

  static ActivityType fromString(String type) {
    switch (type) {
      case 'submitted':
        return ActivityType.submitted;
      case 'underReview':
        return ActivityType.underReview;
      case 'approved':
        return ActivityType.approved;
      case 'rejected':
        return ActivityType.rejected;
      case 'cancelled':
        return ActivityType.cancelled;
      default:
        return ActivityType.submitted;
    }
  }

  String toJson() => name;
}

class LoanActivityModel {
  final String id;
  final String loanId;
  final String userId;
  final String userName;
  final ActivityType type;
  final String message;
  final DateTime createdAt;

  const LoanActivityModel({
    required this.id,
    required this.loanId,
    required this.userId,
    required this.userName,
    required this.type,
    required this.message,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'loanId': loanId,
      'userId': userId,
      'userName': userName,
      'type': type.toJson(),
      'message': message,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory LoanActivityModel.fromJson(Map<String, dynamic> json) {
    return LoanActivityModel(
      id: json['id'] as String,
      loanId: json['loanId'] as String,
      userId: json['userId'] as String,
      userName: json['userName'] as String? ?? 'Valued Customer',
      type: ActivityTypeExtension.fromString(json['type'] as String? ?? 'submitted'),
      message: json['message'] as String,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
    );
  }
}

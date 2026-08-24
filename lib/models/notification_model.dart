import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';

enum NotificationType {
  loanSubmitted,
  loanApproved,
  loanRejected,
  loanCancelled,
  system,
}

extension NotificationTypeExtension on NotificationType {
  String get label {
    switch (this) {
      case NotificationType.loanSubmitted:
        return 'Application Submitted';
      case NotificationType.loanApproved:
        return 'Loan Approved';
      case NotificationType.loanRejected:
        return 'Loan Rejected';
      case NotificationType.loanCancelled:
        return 'Loan Cancelled';
      case NotificationType.system:
        return 'System Notification';
    }
  }

  Color get color {
    switch (this) {
      case NotificationType.loanSubmitted:
        return AppColors.primary;
      case NotificationType.loanApproved:
        return AppColors.success;
      case NotificationType.loanRejected:
        return AppColors.error;
      case NotificationType.loanCancelled:
        return const Color(0xFF64748B);
      case NotificationType.system:
        return const Color(0xFF7C3AED);
    }
  }

  IconData get icon {
    switch (this) {
      case NotificationType.loanSubmitted:
        return Icons.send_rounded;
      case NotificationType.loanApproved:
        return Icons.check_circle_rounded;
      case NotificationType.loanRejected:
        return Icons.cancel_rounded;
      case NotificationType.loanCancelled:
        return Icons.block_rounded;
      case NotificationType.system:
        return Icons.notifications_active_rounded;
    }
  }

  static NotificationType fromString(String type) {
    switch (type) {
      case 'loanSubmitted':
        return NotificationType.loanSubmitted;
      case 'loanApproved':
        return NotificationType.loanApproved;
      case 'loanRejected':
        return NotificationType.loanRejected;
      case 'loanCancelled':
        return NotificationType.loanCancelled;
      case 'system':
      default:
        return NotificationType.system;
    }
  }

  String toJson() => name;
}

class NotificationModel {
  final String id;
  final String userId;
  final String title;
  final String message;
  final NotificationType type;
  final String? loanId;
  final DateTime createdAt;
  final bool isRead;

  const NotificationModel({
    required this.id,
    required this.userId,
    required this.title,
    required this.message,
    required this.type,
    this.loanId,
    required this.createdAt,
    this.isRead = false,
  });

  NotificationModel copyWith({
    String? id,
    String? userId,
    String? title,
    String? message,
    NotificationType? type,
    String? loanId,
    DateTime? createdAt,
    bool? isRead,
  }) {
    return NotificationModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      title: title ?? this.title,
      message: message ?? this.message,
      type: type ?? this.type,
      loanId: loanId ?? this.loanId,
      createdAt: createdAt ?? this.createdAt,
      isRead: isRead ?? this.isRead,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'userId': userId,
      'title': title,
      'message': message,
      'type': type.toJson(),
      'loanId': loanId,
      'createdAt': createdAt.toIso8601String(),
      'isRead': isRead,
    };
  }

  factory NotificationModel.fromJson(Map<String, dynamic> json) {
    return NotificationModel(
      id: json['id'] as String,
      userId: json['userId'] as String,
      title: json['title'] as String,
      message: json['message'] as String,
      type: NotificationTypeExtension.fromString(json['type'] as String? ?? 'system'),
      loanId: json['loanId'] as String?,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
      isRead: json['isRead'] as bool? ?? false,
    );
  }
}

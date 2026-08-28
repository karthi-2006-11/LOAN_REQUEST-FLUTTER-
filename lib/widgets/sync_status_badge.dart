import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';
import '../models/loan_sync_status.dart';

/// Compact visual badge widget indicating the customer-facing sync status of a loan.
class SyncStatusBadge extends StatelessWidget {
  final LoanSyncStatus status;
  final bool isCompact;

  const SyncStatusBadge({
    super.key,
    required this.status,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    Color bgColor;
    Color textColor;
    IconData iconData;

    switch (status) {
      case LoanSyncStatus.pendingSync:
        bgColor = const Color(0xFFFFF3E0); // Warm Amber/Orange
        textColor = const Color(0xFFE65100);
        iconData = Icons.cloud_upload_outlined;
        break;

      case LoanSyncStatus.synced:
        bgColor = const Color(0xFFE8F5E9); // Soft Green
        textColor = const Color(0xFF2E7D32);
        iconData = Icons.cloud_done_rounded;
        break;

      case LoanSyncStatus.syncFailed:
        bgColor = const Color(0xFFFFEBEE); // Soft Red
        textColor = AppColors.error;
        iconData = Icons.cloud_off_rounded;
        break;
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? 6 : 10,
        vertical: isCompact ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: textColor.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            iconData,
            size: isCompact ? 12 : 14,
            color: textColor,
          ),
          SizedBox(width: isCompact ? 3 : 5),
          Text(
            status.label,
            style: TextStyle(
              fontSize: isCompact ? 10 : 11,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }
}

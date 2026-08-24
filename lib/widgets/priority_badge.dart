import 'package:flutter/material.dart';
import '../models/loan_priority.dart';

/// Reusable badge widget for Low, Medium, High loan priority.
class PriorityBadge extends StatelessWidget {
  final LoanPriority priority;
  final bool isCompact;

  const PriorityBadge({
    super.key,
    required this.priority,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? 8 : 10,
        vertical: isCompact ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: priority.backgroundColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: priority.color.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            priority.icon,
            size: isCompact ? 11 : 13,
            color: priority.color,
          ),
          const SizedBox(width: 4),
          Text(
            '${priority.label} Priority',
            style: TextStyle(
              color: priority.color,
              fontSize: isCompact ? 10 : 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

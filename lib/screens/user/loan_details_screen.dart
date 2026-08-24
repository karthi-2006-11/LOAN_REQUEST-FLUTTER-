import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../models/loan_model.dart';
import '../../models/loan_priority.dart';
import '../../models/loan_status.dart';
import '../../providers/loan_provider.dart';
import '../../widgets/priority_badge.dart';
import '../../widgets/status_chip.dart';

class LoanDetailsScreen extends StatelessWidget {
  final String loanId;

  const LoanDetailsScreen({
    super.key,
    required this.loanId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final currencyFormatter = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);
    final dateFormatter = DateFormat('MMMM dd, yyyy  •  hh:mm a');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Loan Details'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: FutureBuilder<LoanModel?>(
        future: Provider.of<LoanProvider>(context, listen: false).getLoanById(loanId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final loan = snapshot.data;
          if (loan == null) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.search_off_rounded, size: 48, color: Colors.grey),
                  const SizedBox(height: 12),
                  const Text('Loan application not found.'),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Go Back'),
                  ),
                ],
              ),
            );
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top Status Header Card
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.darkCard : AppColors.lightCard,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'ID: ${loan.id}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primary,
                            ),
                          ),
                          StatusChip(status: loan.status),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        currencyFormatter.format(loan.amount),
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w800,
                          color: isDark
                              ? AppColors.textDarkPrimary
                              : AppColors.textLightPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Requested Purpose: ${loan.purpose}',
                        style: TextStyle(
                          fontSize: 14,
                          color: isDark
                              ? AppColors.textDarkSecondary
                              : AppColors.textLightSecondary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      PriorityBadge(priority: loan.priority),
                    ],
                  ),
                ),

                const SizedBox(height: 28),

                // Application Status Timeline
                Text(
                  'Application Progress Timeline',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: isDark
                        ? AppColors.textDarkPrimary
                        : AppColors.textLightPrimary,
                  ),
                ),
                const SizedBox(height: 16),

                _buildStatusTimeline(context, loan.status),

                const SizedBox(height: 28),

                // Full Loan Information Grid / Cards
                Text(
                  'Application Summary',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: isDark
                        ? AppColors.textDarkPrimary
                        : AppColors.textLightPrimary,
                  ),
                ),
                const SizedBox(height: 14),

                Container(
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.darkCard : AppColors.lightCard,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                    ),
                  ),
                  child: Column(
                    children: [
                      _buildInfoRow(
                        context: context,
                        label: 'Applicant Name',
                        value: loan.userName,
                        icon: Icons.person_outline_rounded,
                      ),
                      const Divider(height: 1),
                      _buildInfoRow(
                        context: context,
                        label: 'Loan Amount',
                        value: currencyFormatter.format(loan.amount),
                        icon: Icons.attach_money_rounded,
                      ),
                      const Divider(height: 1),
                      _buildInfoRow(
                        context: context,
                        label: 'Tenure Duration',
                        value: '${loan.tenureMonths} Months',
                        icon: Icons.calendar_month_outlined,
                      ),
                      const Divider(height: 1),
                      _buildInfoRow(
                        context: context,
                        label: 'Est. Monthly Payment',
                        value:
                            '${currencyFormatter.format(loan.estimatedMonthlyPayment)}/mo',
                        icon: Icons.calculate_outlined,
                      ),
                      const Divider(height: 1),
                      _buildInfoRow(
                        context: context,
                        label: 'Loan Purpose',
                        value: loan.purpose,
                        icon: Icons.label_outline_rounded,
                      ),
                      const Divider(height: 1),
                      _buildInfoRow(
                        context: context,
                        label: 'Processing Priority',
                        value: '${loan.priority.label} Priority',
                        icon: Icons.speed_rounded,
                      ),
                      const Divider(height: 1),
                      _buildInfoRow(
                        context: context,
                        label: 'Date Submitted',
                        value: dateFormatter.format(loan.createdAt),
                        icon: Icons.access_time_rounded,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildStatusTimeline(BuildContext context, LoanStatus currentStatus) {
    final isPending = currentStatus == LoanStatus.pending;
    final isApproved = currentStatus == LoanStatus.approved;
    final isRejected = currentStatus == LoanStatus.rejected;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? AppColors.darkSurface
            : AppColors.lightSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).brightness == Brightness.dark
              ? AppColors.darkBorder
              : AppColors.lightBorder,
        ),
      ),
      child: Row(
        children: [
          // Step 1: Applied
          _buildTimelineStep(
            context: context,
            title: 'Submitted',
            isCompleted: true,
            isCurrent: false,
            color: AppColors.primary,
            icon: Icons.check_circle_rounded,
          ),
          _buildTimelineConnector(isCompleted: true),

          // Step 2: Pending Under Review
          _buildTimelineStep(
            context: context,
            title: 'Under Review',
            isCompleted: isApproved || isRejected,
            isCurrent: isPending,
            color: AppColors.warning,
            icon: isPending
                ? Icons.hourglass_top_rounded
                : Icons.check_circle_rounded,
          ),
          _buildTimelineConnector(isCompleted: isApproved || isRejected),

          // Step 3: Final Decision (Approved / Rejected)
          _buildTimelineStep(
            context: context,
            title: isRejected ? 'Rejected' : 'Approved',
            isCompleted: isApproved || isRejected,
            isCurrent: isApproved || isRejected,
            color: isRejected
                ? AppColors.error
                : (isApproved ? AppColors.success : Colors.grey),
            icon: isRejected
                ? Icons.cancel_rounded
                : (isApproved
                    ? Icons.verified_rounded
                    : Icons.radio_button_unchecked_rounded),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineStep({
    required BuildContext context,
    required String title,
    required bool isCompleted,
    required bool isCurrent,
    required Color color,
    required IconData icon,
  }) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isCompleted || isCurrent
                ? color.withValues(alpha: 0.15)
                : Colors.grey.withValues(alpha: 0.1),
            border: Border.all(
              color: isCompleted || isCurrent ? color : Colors.grey,
              width: isCurrent ? 2 : 1,
            ),
          ),
          child: Icon(
            icon,
            size: 20,
            color: isCompleted || isCurrent ? color : Colors.grey,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          title,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
            color: isCompleted || isCurrent ? color : Colors.grey,
          ),
        ),
      ],
    );
  }

  Widget _buildTimelineConnector({required bool isCompleted}) {
    return Expanded(
      child: Container(
        height: 2,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        color: isCompleted ? AppColors.primary : Colors.grey.withValues(alpha: 0.3),
      ),
    );
  }

  Widget _buildInfoRow({
    required BuildContext context,
    required String label,
    required String value,
    required IconData icon,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.primary),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: isDark
                  ? AppColors.textDarkSecondary
                  : AppColors.textLightSecondary,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: isDark
                  ? AppColors.textDarkPrimary
                  : AppColors.textLightPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

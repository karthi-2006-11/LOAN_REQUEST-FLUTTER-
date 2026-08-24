import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../models/loan_activity_model.dart';
import '../../models/loan_model.dart';
import '../../models/loan_priority.dart';
import '../../models/loan_status.dart';
import '../../providers/loan_provider.dart';
import '../../widgets/custom_button.dart';
import '../../widgets/priority_badge.dart';
import '../../widgets/status_chip.dart';

class AdminLoanDetailsScreen extends StatefulWidget {
  final String loanId;

  const AdminLoanDetailsScreen({
    super.key,
    required this.loanId,
  });

  @override
  State<AdminLoanDetailsScreen> createState() => _AdminLoanDetailsScreenState();
}

class _AdminLoanDetailsScreenState extends State<AdminLoanDetailsScreen> {
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<LoanProvider>(context, listen: false).fetchLoanActivities(widget.loanId);
    });
  }

  Future<void> _handleDecision(LoanStatus targetStatus) async {
    final loanProvider = Provider.of<LoanProvider>(context, listen: false);

    setState(() {
      _isProcessing = true;
    });

    final success = await loanProvider.updateLoanStatus(widget.loanId, targetStatus);

    if (!mounted) return;

    setState(() {
      _isProcessing = false;
    });

    if (success) {
      final actionText = targetStatus == LoanStatus.approved ? 'Approved' : 'Rejected';
      final actionColor = targetStatus == LoanStatus.approved ? AppColors.success : AppColors.error;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Loan application has been successfully $actionText.'),
          backgroundColor: actionColor,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            loanProvider.errorMessage ?? 'Failed to update loan status.',
          ),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final currencyFormatter = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);
    final dateFormatter = DateFormat('MMMM dd, yyyy  •  hh:mm a');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Review Loan Request'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: FutureBuilder<LoanModel?>(
        future: Provider.of<LoanProvider>(context, listen: false).getLoanById(widget.loanId),
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
                  const Text('Loan application record not found.'),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Go Back'),
                  ),
                ],
              ),
            );
          }

          final isPending = loan.status == LoanStatus.pending;

          return SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top Status Banner Card
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
                      const SizedBox(height: 14),
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
                        'Applicant: ${loan.userName}',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? AppColors.textDarkPrimary
                              : AppColors.textLightPrimary,
                        ),
                      ),
                      const SizedBox(height: 14),
                      PriorityBadge(priority: loan.priority),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // Decision Action Card for Admin (Only shown if Pending)
                if (isPending) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: const Color(0xFF7C3AED).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFF7C3AED).withValues(alpha: 0.25),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.admin_panel_settings_rounded,
                                color: Color(0xFF7C3AED), size: 20),
                            SizedBox(width: 8),
                            Text(
                              'Admin Decision Action Required',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF7C3AED),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Review application parameters and render final approval or rejection.',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? AppColors.textDarkSecondary
                                : AppColors.textLightSecondary,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: CustomButton(
                                text: 'Approve',
                                icon: Icons.check_circle_rounded,
                                variant: ButtonVariant.secondary,
                                isLoading: _isProcessing,
                                onPressed: () => _handleDecision(LoanStatus.approved),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(double.infinity, 54),
                                  foregroundColor: AppColors.error,
                                  side: const BorderSide(color: AppColors.error, width: 1.5),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                icon: const Icon(Icons.cancel_rounded, size: 20),
                                label: const Text(
                                  'Reject',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                onPressed: _isProcessing
                                    ? null
                                    : () => _handleDecision(LoanStatus.rejected),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ] else ...[
                  // Decision / Status Notice Banner for Finalized Requests
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: loan.status.backgroundColor,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: loan.status.color.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(loan.status.icon, color: loan.status.color, size: 24),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                loan.status == LoanStatus.cancelled
                                    ? 'Application Cancelled by Customer'
                                    : 'Decision Finalized: ${loan.status.label}',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: loan.status.color,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                loan.status == LoanStatus.cancelled
                                    ? 'The applicant withdrew this request before review.'
                                    : 'This application has been processed and locked.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isDark
                                      ? AppColors.textDarkSecondary
                                      : AppColors.textLightSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ],

                // Application Timeline
                Text(
                  'Application Timeline',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: isDark
                        ? AppColors.textDarkPrimary
                        : AppColors.textLightPrimary,
                  ),
                ),
                const SizedBox(height: 14),

                _buildStatusTimeline(context, loan.status),

                const SizedBox(height: 24),

                // Loan Activity History Log Section
                Text(
                  'System Activity History Log',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: isDark
                        ? AppColors.textDarkPrimary
                        : AppColors.textLightPrimary,
                  ),
                ),
                const SizedBox(height: 14),

                Consumer<LoanProvider>(
                  builder: (context, loanProvider, child) {
                    final activities = loanProvider.currentLoanActivities;

                    if (activities.isEmpty) {
                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isDark ? AppColors.darkCard : AppColors.lightCard,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.history_rounded, color: Color(0xFF7C3AED)),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Loan submitted on ${dateFormatter.format(loan.createdAt)}',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: isDark
                                      ? AppColors.textDarkSecondary
                                      : AppColors.textLightSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isDark ? AppColors.darkCard : AppColors.lightCard,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                        ),
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: activities.length,
                        separatorBuilder: (context, index) =>
                            const Divider(height: 20, thickness: 0.8),
                        itemBuilder: (context, index) {
                          final activity = activities[index];
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: activity.type.color.withValues(alpha: 0.15),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  activity.type.icon,
                                  color: activity.type.color,
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      activity.message,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: isDark
                                            ? AppColors.textDarkPrimary
                                            : AppColors.textLightPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      dateFormatter.format(activity.createdAt),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: isDark
                                            ? AppColors.textDarkSecondary
                                            : AppColors.textLightSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    );
                  },
                ),

                const SizedBox(height: 24),

                // Comprehensive Loan Data Table
                Text(
                  'Application Summary Breakdown',
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
                        label: 'User ID',
                        value: loan.userId,
                        icon: Icons.badge_outlined,
                      ),
                      const Divider(height: 1),
                      _buildInfoRow(
                        context: context,
                        label: 'Loan Amount',
                        value: currencyFormatter.format(loan.amount),
                        icon: Icons.currency_rupee_rounded,
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
                        label: 'Est. Monthly Repayment',
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
    final isCancelled = currentStatus == LoanStatus.cancelled;

    final isFinalStepReached = isApproved || isRejected || isCancelled;

    String finalStepTitle = 'Approved';
    Color finalStepColor = Colors.grey;
    IconData finalStepIcon = Icons.radio_button_unchecked_rounded;

    if (isApproved) {
      finalStepTitle = 'Approved';
      finalStepColor = AppColors.success;
      finalStepIcon = Icons.verified_rounded;
    } else if (isRejected) {
      finalStepTitle = 'Rejected';
      finalStepColor = AppColors.error;
      finalStepIcon = Icons.cancel_rounded;
    } else if (isCancelled) {
      finalStepTitle = 'Cancelled';
      finalStepColor = const Color(0xFF64748B);
      finalStepIcon = Icons.block_rounded;
    }

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
          _buildTimelineStep(
            context: context,
            title: 'Submitted',
            isCompleted: true,
            isCurrent: false,
            color: AppColors.primary,
            icon: Icons.check_circle_rounded,
          ),
          _buildTimelineConnector(isCompleted: true),
          _buildTimelineStep(
            context: context,
            title: 'Under Review',
            isCompleted: isFinalStepReached,
            isCurrent: isPending,
            color: AppColors.warning,
            icon: isPending
                ? Icons.hourglass_top_rounded
                : Icons.check_circle_rounded,
          ),
          _buildTimelineConnector(isCompleted: isFinalStepReached),
          _buildTimelineStep(
            context: context,
            title: finalStepTitle,
            isCompleted: isFinalStepReached,
            isCurrent: isFinalStepReached,
            color: finalStepColor,
            icon: finalStepIcon,
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
          Icon(icon, size: 18, color: const Color(0xFF7C3AED)),
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

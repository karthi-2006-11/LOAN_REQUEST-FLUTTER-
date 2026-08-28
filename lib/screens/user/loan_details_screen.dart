import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../models/loan_activity_model.dart';
import '../../models/loan_model.dart';
import '../../models/loan_priority.dart';
import '../../models/loan_status.dart';
import '../../models/user_role.dart';
import '../../providers/auth_provider.dart';
import '../../providers/loan_provider.dart';
import '../../widgets/priority_badge.dart';
import '../../widgets/status_chip.dart';
import '../../widgets/sync_status_badge.dart';

class LoanDetailsScreen extends StatefulWidget {
  final String loanId;

  const LoanDetailsScreen({
    super.key,
    required this.loanId,
  });

  @override
  State<LoanDetailsScreen> createState() => _LoanDetailsScreenState();
}

class _LoanDetailsScreenState extends State<LoanDetailsScreen> {
  bool _isCancelling = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<LoanProvider>(context, listen: false).fetchLoanActivities(widget.loanId);
    });
  }

  Future<void> _handleCancelLoan(BuildContext context, LoanModel loan) async {
    final loanProvider = Provider.of<LoanProvider>(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel Loan Application'),
        content: const Text(
          'Are you sure you want to cancel this pending loan request? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep Active'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Cancel Loan'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    if (!mounted) return;

    setState(() {
      _isCancelling = true;
    });

    final success = await loanProvider.cancelLoan(loan.id);

    if (!mounted) return;

    setState(() {
      _isCancelling = false;
    });

    if (success) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Your loan request has been cancelled.'),
          backgroundColor: AppColors.textLightSecondary,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            loanProvider.errorMessage ?? 'Failed to cancel loan request.',
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
        title: const Text('Loan Details'),
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

          final authUser = Provider.of<AuthProvider>(context, listen: false).currentUser;
          if (authUser != null && authUser.role == UserRole.user && loan.userId != authUser.id) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.security_rounded, size: 54, color: AppColors.error),
                    const SizedBox(height: 14),
                    const Text(
                      'Access Denied',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.error),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'You are not authorized to view another user\'s loan application.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 18),
                    ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Go Back'),
                    ),
                  ],
                ),
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
                          Row(
                            children: [
                              SyncStatusBadge(
                                status: Provider.of<LoanProvider>(context).getSyncStatus(loan.id),
                                isCompact: true,
                              ),
                              const SizedBox(width: 6),
                              StatusChip(status: loan.status),
                            ],
                          ),
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

                const SizedBox(height: 24),

                // Customer Cancel Action Banner (If Pending)
                if (loan.status == LoanStatus.pending) ...[
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 50),
                      foregroundColor: AppColors.error,
                      side: BorderSide(
                        color: AppColors.error.withValues(alpha: 0.6),
                        width: 1.5,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: _isCancelling
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(AppColors.error),
                            ),
                          )
                        : const Icon(Icons.cancel_outlined, size: 20),
                    label: const Text(
                      'Cancel Application',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    onPressed: _isCancelling ? null : () => _handleCancelLoan(context, loan),
                  ),
                  const SizedBox(height: 24),
                ] else if (loan.status == LoanStatus.cancelled) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: LoanStatus.cancelled.backgroundColor,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: LoanStatus.cancelled.color.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(LoanStatus.cancelled.icon,
                            color: LoanStatus.cancelled.color, size: 22),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Loan Application Cancelled',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: LoanStatus.cancelled.color,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'You cancelled this request before processing.',
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

                // Loan Activity History Log
                Text(
                  'Detailed Activity History',
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
                            Icon(Icons.history_rounded,
                                color: isDark
                                    ? AppColors.textDarkSecondary
                                    : AppColors.textLightSecondary),
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
          // Step 1: Submitted
          _buildTimelineStep(
            context: context,
            title: 'Submitted',
            isCompleted: true,
            isCurrent: false,
            color: AppColors.primary,
            icon: Icons.check_circle_rounded,
          ),
          _buildTimelineConnector(isCompleted: true),

          // Step 2: Under Review
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

          // Step 3: Final Outcome
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

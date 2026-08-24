import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../models/loan_priority.dart';
import '../../models/loan_status.dart';
import '../../models/user_role.dart';
import '../../navigation/app_router.dart';
import '../../providers/auth_provider.dart';
import '../../providers/loan_provider.dart';
import '../../providers/notification_provider.dart';
import '../../widgets/empty_state_widget.dart';
import '../../widgets/loan_card.dart';
import '../../widgets/role_badge.dart';

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _loadData() {
    Provider.of<LoanProvider>(context, listen: false).fetchAllLoans();
    Provider.of<NotificationProvider>(context, listen: false).fetchAdminNotifications();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Consumer<AuthProvider>(
      builder: (context, auth, child) {
        final user = auth.currentUser;

        return Scaffold(
          appBar: AppBar(
            title: const Text('Admin Management Console'),
            elevation: 0,
            actions: [
              Consumer<NotificationProvider>(
                builder: (context, notifProvider, child) {
                  final unread = notifProvider.unreadCount;
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.notifications_outlined),
                        tooltip: 'System Notifications',
                        onPressed: () {
                          Navigator.of(context).pushNamed(AppRouter.adminNotifications);
                        },
                      ),
                      if (unread > 0)
                        Positioned(
                          right: 8,
                          top: 8,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: AppColors.error,
                              shape: BoxShape.circle,
                            ),
                            constraints: const BoxConstraints(
                              minWidth: 16,
                              minHeight: 16,
                            ),
                            child: Text(
                              unread > 9 ? '9+' : '$unread',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.refresh_rounded),
                tooltip: 'Refresh System Data',
                onPressed: _loadData,
              ),
              IconButton(
                icon: const Icon(Icons.logout_rounded),
                tooltip: 'Logout',
                onPressed: () async {
                  await auth.logout();
                  if (context.mounted) {
                    Navigator.of(context).pushReplacementNamed(AppRouter.login);
                  }
                },
              ),
            ],
          ),
          body: Consumer<LoanProvider>(
            builder: (context, loanProvider, child) {
              final loans = loanProvider.filteredAdminLoans;
              final selectedStatusFilter = loanProvider.selectedStatusFilter;
              final selectedPriorityFilter = loanProvider.selectedPriorityFilter;
              final selectedSort = loanProvider.selectedSortOption;

              return RefreshIndicator(
                onRefresh: () async {
                  _loadData();
                },
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 1. Admin Header Banner Card
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF4C1D95), Color(0xFF7C3AED)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF7C3AED).withValues(alpha: 0.3),
                              blurRadius: 14,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'ADMINISTRATOR CONSOLE',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                                RoleBadge(role: user?.role ?? UserRole.admin),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              user?.fullName ?? 'System Administrator',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              user?.email ?? '',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      // 2. Summary Cards Row (5 Metrics)
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _buildSummaryCard(
                              context: context,
                              title: 'Total',
                              value: '${loanProvider.totalLoansCount}',
                              icon: Icons.list_alt_rounded,
                              color: AppColors.primary,
                            ),
                            const SizedBox(width: 8),
                            _buildSummaryCard(
                              context: context,
                              title: 'Pending',
                              value: '${loanProvider.adminPendingCount}',
                              icon: Icons.hourglass_top_rounded,
                              color: AppColors.warning,
                            ),
                            const SizedBox(width: 8),
                            _buildSummaryCard(
                              context: context,
                              title: 'Approved',
                              value: '${loanProvider.approvedLoansCount}',
                              icon: Icons.check_circle_outline_rounded,
                              color: AppColors.success,
                            ),
                            const SizedBox(width: 8),
                            _buildSummaryCard(
                              context: context,
                              title: 'Rejected',
                              value: '${loanProvider.rejectedLoansCount}',
                              icon: Icons.cancel_outlined,
                              color: AppColors.error,
                            ),
                            const SizedBox(width: 8),
                            _buildSummaryCard(
                              context: context,
                              title: 'Cancelled',
                              value: '${loanProvider.cancelledLoansCount}',
                              icon: Icons.block_rounded,
                              color: const Color(0xFF64748B),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 24),

                      // 3. Search Bar
                      TextField(
                        controller: _searchController,
                        onChanged: (val) => loanProvider.setSearchQuery(val),
                        decoration: InputDecoration(
                          hintText: 'Search by Applicant Name, ID, or Purpose...',
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear_rounded),
                                  onPressed: () {
                                    _searchController.clear();
                                    loanProvider.setSearchQuery('');
                                  },
                                )
                              : null,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        ),
                      ),

                      const SizedBox(height: 16),

                      // 4. Status Filter Chips Row
                      const Text(
                        'Status Filter',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textLightSecondary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _buildFilterChip(
                              context: context,
                              label: 'All (${loanProvider.allLoans.length})',
                              isSelected: selectedStatusFilter == null,
                              onTap: () => loanProvider.setFilter(null),
                            ),
                            const SizedBox(width: 8),
                            _buildFilterChip(
                              context: context,
                              label: 'Pending (${loanProvider.adminPendingCount})',
                              isSelected: selectedStatusFilter == LoanStatus.pending,
                              onTap: () =>
                                  loanProvider.setFilter(LoanStatus.pending),
                            ),
                            const SizedBox(width: 8),
                            _buildFilterChip(
                              context: context,
                              label: 'Approved (${loanProvider.approvedLoansCount})',
                              isSelected: selectedStatusFilter == LoanStatus.approved,
                              onTap: () =>
                                  loanProvider.setFilter(LoanStatus.approved),
                            ),
                            const SizedBox(width: 8),
                            _buildFilterChip(
                              context: context,
                              label: 'Rejected (${loanProvider.rejectedLoansCount})',
                              isSelected: selectedStatusFilter == LoanStatus.rejected,
                              onTap: () =>
                                  loanProvider.setFilter(LoanStatus.rejected),
                            ),
                            const SizedBox(width: 8),
                            _buildFilterChip(
                              context: context,
                              label: 'Cancelled (${loanProvider.cancelledLoansCount})',
                              isSelected: selectedStatusFilter == LoanStatus.cancelled,
                              onTap: () =>
                                  loanProvider.setFilter(LoanStatus.cancelled),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),

                      // 5. Priority Filter & Sorting Row
                      Row(
                        children: [
                          // Priority Choice Chips
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  const Text(
                                    'Priority: ',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.textLightSecondary,
                                    ),
                                  ),
                                  _buildPriorityChip(
                                    context: context,
                                    label: 'All',
                                    isSelected: selectedPriorityFilter == null,
                                    onTap: () => loanProvider.setPriorityFilter(null),
                                  ),
                                  const SizedBox(width: 6),
                                  _buildPriorityChip(
                                    context: context,
                                    label: 'Low',
                                    isSelected: selectedPriorityFilter == LoanPriority.low,
                                    onTap: () =>
                                        loanProvider.setPriorityFilter(LoanPriority.low),
                                  ),
                                  const SizedBox(width: 6),
                                  _buildPriorityChip(
                                    context: context,
                                    label: 'Med',
                                    isSelected: selectedPriorityFilter == LoanPriority.medium,
                                    onTap: () =>
                                        loanProvider.setPriorityFilter(LoanPriority.medium),
                                  ),
                                  const SizedBox(width: 6),
                                  _buildPriorityChip(
                                    context: context,
                                    label: 'High',
                                    isSelected: selectedPriorityFilter == LoanPriority.high,
                                    onTap: () =>
                                        loanProvider.setPriorityFilter(LoanPriority.high),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          const SizedBox(width: 8),

                          // Sort Option Dropdown Button
                          PopupMenuButton<AdminSortOption>(
                            initialValue: selectedSort,
                            onSelected: (option) => loanProvider.setSortOption(option),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: isDark ? AppColors.darkSurface : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.sort_rounded, size: 16),
                                  const SizedBox(width: 4),
                                  Text(
                                    selectedSort.label,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const Icon(Icons.arrow_drop_down, size: 18),
                                ],
                              ),
                            ),
                            itemBuilder: (context) => AdminSortOption.values.map((option) {
                              return PopupMenuItem<AdminSortOption>(
                                value: option,
                                child: Text(
                                  option.label,
                                  style: TextStyle(
                                    fontWeight: selectedSort == option
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      // Error Banner
                      if (loanProvider.errorMessage != null)
                        Container(
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 14),
                          decoration: BoxDecoration(
                            color: AppColors.error.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: AppColors.error.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline,
                                  color: AppColors.error),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  loanProvider.errorMessage!,
                                  style: const TextStyle(
                                      color: AppColors.error, fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),

                      // 6. Application List / Empty View
                      if (loanProvider.isLoading)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 40),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (loans.isEmpty)
                        EmptyStateWidget(
                          title: 'No Matching Loans Found',
                          description:
                              'No applications match your current search query, status, or priority filters.',
                          buttonText: 'Reset Filters',
                          onActionPressed: () {
                            _searchController.clear();
                            loanProvider.clearAdminFilters();
                          },
                        )
                      else
                        ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: loans.length,
                          itemBuilder: (context, index) {
                            final loan = loans[index];
                            return LoanCard(
                              loan: loan,
                              showApplicantName: true,
                              onTap: () {
                                Navigator.of(context).pushNamed(
                                  AppRouter.adminLoanDetails,
                                  arguments: loan.id,
                                );
                              },
                            );
                          },
                        ),

                      const SizedBox(height: 30),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildSummaryCard({
    required BuildContext context,
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      width: 84,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.lightCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: isDark
                  ? AppColors.textDarkPrimary
                  : AppColors.textLightPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              color: isDark
                  ? AppColors.textDarkSecondary
                  : AppColors.textLightSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip({
    required BuildContext context,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF7C3AED)
              : (isDark ? AppColors.darkSurface : const Color(0xFFF1F5F9)),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF7C3AED)
                : (isDark ? AppColors.darkBorder : AppColors.lightBorder),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected
                ? Colors.white
                : (isDark
                    ? AppColors.textDarkSecondary
                    : AppColors.textLightPrimary),
          ),
        ),
      ),
    );
  }

  Widget _buildPriorityChip({
    required BuildContext context,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primary.withValues(alpha: 0.15)
              : (isDark ? AppColors.darkSurface : const Color(0xFFF1F5F9)),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected
                ? AppColors.primary
                : (isDark ? AppColors.darkBorder : AppColors.lightBorder),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected
                ? AppColors.primary
                : (isDark ? AppColors.textDarkSecondary : AppColors.textLightSecondary),
          ),
        ),
      ),
    );
  }
}

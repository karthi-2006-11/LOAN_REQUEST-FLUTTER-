import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../models/loan_status.dart';
import '../../models/user_role.dart';
import '../../navigation/app_router.dart';
import '../../providers/auth_provider.dart';
import '../../providers/loan_provider.dart';
import '../../widgets/empty_state_widget.dart';
import '../../widgets/loan_card.dart';
import '../../widgets/role_badge.dart';

class UserDashboardScreen extends StatefulWidget {
  const UserDashboardScreen({super.key});

  @override
  State<UserDashboardScreen> createState() => _UserDashboardScreenState();
}

class _UserDashboardScreenState extends State<UserDashboardScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
    });
  }

  void _loadData() {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final user = authProvider.currentUser;
    if (user != null) {
      Provider.of<LoanProvider>(context, listen: false).fetchUserLoans(user.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final currencyFormatter = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);

    return Consumer<AuthProvider>(
      builder: (context, auth, child) {
        final user = auth.currentUser;

        return Scaffold(
          appBar: AppBar(
            title: const Text('User Portal'),
            elevation: 0,
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh_rounded),
                tooltip: 'Refresh Data',
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
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () {
              Navigator.of(context).pushNamed(AppRouter.createLoan);
            },
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.add_rounded),
            label: const Text(
              'Apply New Loan',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          body: Consumer<LoanProvider>(
            builder: (context, loanProvider, child) {
              final loans = loanProvider.filteredLoans;
              final selectedFilter = loanProvider.selectedStatusFilter;

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
                      // 1. Welcome / Header Card
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          gradient: AppColors.primaryGradient,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.primary.withValues(alpha: 0.25),
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
                                  'WELCOME BACK',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                                RoleBadge(role: user?.role ?? UserRole.user),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              user?.fullName ?? 'Valued Customer',
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

                      // 2. Financial Summary Widgets
                      Row(
                        children: [
                          Expanded(
                            child: _buildSummaryCard(
                              context: context,
                              title: 'Active Loans',
                              value: '${loanProvider.activeLoansCount}',
                              icon: Icons.account_balance_outlined,
                              color: AppColors.primary,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _buildSummaryCard(
                              context: context,
                              title: 'Total Borrowed',
                              value: currencyFormatter
                                  .format(loanProvider.totalAmountBorrowed),
                              icon: Icons.attach_money_rounded,
                              color: AppColors.accent,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _buildSummaryCard(
                              context: context,
                              title: 'Pending',
                              value: '${loanProvider.pendingLoansCount}',
                              icon: Icons.hourglass_top_rounded,
                              color: AppColors.warning,
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 24),

                      // 3. Quick Actions & Status Filters
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'My Loan Requests',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: isDark
                                  ? AppColors.textDarkPrimary
                                  : AppColors.textLightPrimary,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () {
                              Navigator.of(context).pushNamed(AppRouter.createLoan);
                            },
                            icon: const Icon(Icons.add_circle_outline, size: 18),
                            label: const Text('New Loan'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // Filter Chips Row
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _buildFilterChip(
                              context: context,
                              label: 'All (${loanProvider.userLoans.length})',
                              isSelected: selectedFilter == null,
                              onTap: () => loanProvider.setFilter(null),
                            ),
                            const SizedBox(width: 8),
                            _buildFilterChip(
                              context: context,
                              label: 'Pending',
                              isSelected: selectedFilter == LoanStatus.pending,
                              onTap: () =>
                                  loanProvider.setFilter(LoanStatus.pending),
                            ),
                            const SizedBox(width: 8),
                            _buildFilterChip(
                              context: context,
                              label: 'Approved',
                              isSelected: selectedFilter == LoanStatus.approved,
                              onTap: () =>
                                  loanProvider.setFilter(LoanStatus.approved),
                            ),
                            const SizedBox(width: 8),
                            _buildFilterChip(
                              context: context,
                              label: 'Rejected',
                              isSelected: selectedFilter == LoanStatus.rejected,
                              onTap: () =>
                                  loanProvider.setFilter(LoanStatus.rejected),
                            ),
                          ],
                        ),
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

                      // 4 & 5 & 6. Loading state, Loan Cards list or Empty state
                      if (loanProvider.isLoading)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 40),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (loans.isEmpty)
                        EmptyStateWidget(
                          title: selectedFilter == null
                              ? 'No Loan Requests Yet'
                              : 'No ${selectedFilter.label} Loans',
                          description: selectedFilter == null
                              ? 'Start your financial journey by applying for your first loan with quick approval.'
                              : 'You have no loan applications matching the "${selectedFilter.label}" status filter.',
                          onActionPressed: () {
                            Navigator.of(context).pushNamed(AppRouter.createLoan);
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
                              onTap: () {
                                Navigator.of(context).pushNamed(
                                  AppRouter.loanDetails,
                                  arguments: loan.id,
                                );
                              },
                            );
                          },
                        ),

                      const SizedBox(height: 60), // Extra space for FAB
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.lightCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(height: 10),
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
              ? AppColors.primary
              : (isDark ? AppColors.darkSurface : const Color(0xFFF1F5F9)),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? AppColors.primary
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
}

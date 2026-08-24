import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../models/notification_model.dart';
import '../../navigation/app_router.dart';
import '../../providers/notification_provider.dart';
import '../../widgets/empty_state_widget.dart';

class AdminNotificationsScreen extends StatefulWidget {
  const AdminNotificationsScreen({super.key});

  @override
  State<AdminNotificationsScreen> createState() => _AdminNotificationsScreenState();
}

class _AdminNotificationsScreenState extends State<AdminNotificationsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadNotifications();
    });
  }

  void _loadNotifications() {
    Provider.of<NotificationProvider>(context, listen: false).fetchAdminNotifications();
  }

  String _formatTimestamp(DateTime dateTime) {
    final diff = DateTime.now().difference(dateTime);
    if (diff.inSeconds < 60) {
      return 'Just now';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    } else {
      return DateFormat('MMM dd, yyyy').format(dateTime);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin System Notifications'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          Consumer<NotificationProvider>(
            builder: (context, notifProvider, child) {
              if (notifProvider.unreadCount == 0) return const SizedBox.shrink();
              return TextButton.icon(
                icon: const Icon(Icons.done_all_rounded, size: 18),
                label: const Text('Mark All Read', style: TextStyle(fontSize: 12)),
                onPressed: () async {
                  await notifProvider.markAllAsRead('admin');
                },
              );
            },
          ),
        ],
      ),
      body: Consumer<NotificationProvider>(
        builder: (context, notifProvider, child) {
          final notifications = notifProvider.adminNotifications;

          return RefreshIndicator(
            onRefresh: () async {
              _loadNotifications();
            },
            child: notifProvider.isLoading
                ? const Center(child: CircularProgressIndicator())
                : notifications.isEmpty
                    ? EmptyStateWidget(
                        title: 'No System Notifications',
                        description:
                            'System notifications will appear here when users submit new loan requests or cancel pending applications.',
                        buttonText: 'Refresh',
                        onActionPressed: _loadNotifications,
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: notifications.length,
                        itemBuilder: (context, index) {
                          final notification = notifications[index];

                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            elevation: notification.isRead ? 0 : 2,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                              side: BorderSide(
                                color: notification.isRead
                                    ? (isDark ? AppColors.darkBorder : AppColors.lightBorder)
                                    : const Color(0xFF7C3AED).withValues(alpha: 0.5),
                                width: notification.isRead ? 1 : 1.5,
                              ),
                            ),
                            color: notification.isRead
                                ? (isDark ? AppColors.darkCard : AppColors.lightCard)
                                : (isDark
                                    ? AppColors.darkSurface
                                    : const Color(0xFF7C3AED).withValues(alpha: 0.05)),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () async {
                                if (!notification.isRead) {
                                  await notifProvider.markAsRead(notification.id);
                                }

                                if (!context.mounted) return;

                                if (notification.loanId != null &&
                                    notification.loanId!.isNotEmpty) {
                                  Navigator.of(context).pushNamed(
                                    AppRouter.adminLoanDetails,
                                    arguments: notification.loanId,
                                  );
                                }
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(16.0),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF7C3AED).withValues(alpha: 0.15),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                        notification.type.icon,
                                        color: const Color(0xFF7C3AED),
                                        size: 22,
                                      ),
                                    ),
                                    const SizedBox(width: 14),

                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  notification.title,
                                                  style: TextStyle(
                                                    fontSize: 15,
                                                    fontWeight: notification.isRead
                                                        ? FontWeight.w600
                                                        : FontWeight.bold,
                                                    color: isDark
                                                        ? AppColors.textDarkPrimary
                                                        : AppColors.textLightPrimary,
                                                  ),
                                                ),
                                              ),
                                              if (!notification.isRead)
                                                Container(
                                                  width: 8,
                                                  height: 8,
                                                  decoration: const BoxDecoration(
                                                    color: Color(0xFF7C3AED),
                                                    shape: BoxShape.circle,
                                                  ),
                                                ),
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            notification.message,
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: isDark
                                                  ? AppColors.textDarkSecondary
                                                  : AppColors.textLightSecondary,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                _formatTimestamp(notification.createdAt),
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: isDark
                                                      ? AppColors.textDarkSecondary
                                                      : AppColors.textLightSecondary,
                                                ),
                                              ),
                                              if (notification.loanId != null)
                                                const Row(
                                                  children: [
                                                    Text(
                                                      'Inspect Request',
                                                      style: TextStyle(
                                                        fontSize: 11,
                                                        fontWeight: FontWeight.bold,
                                                        color: Color(0xFF7C3AED),
                                                      ),
                                                    ),
                                                    Icon(
                                                      Icons.chevron_right_rounded,
                                                      size: 14,
                                                      color: Color(0xFF7C3AED),
                                                    ),
                                                  ],
                                                ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
          );
        },
      ),
    );
  }
}

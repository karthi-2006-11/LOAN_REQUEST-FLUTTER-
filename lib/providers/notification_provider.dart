import 'package:flutter/foundation.dart';
import '../models/notification_model.dart';
import '../repositories/notification_repository.dart';

class NotificationProvider extends ChangeNotifier {
  final NotificationRepository _notificationRepository;

  bool _isLoading = false;
  String? _errorMessage;
  List<NotificationModel> _userNotifications = [];
  List<NotificationModel> _adminNotifications = [];
  int _unreadCount = 0;

  NotificationProvider({NotificationRepository? notificationRepository})
      : _notificationRepository = notificationRepository ?? LocalNotificationRepository();

  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  List<NotificationModel> get userNotifications => List.unmodifiable(_userNotifications);
  List<NotificationModel> get adminNotifications => List.unmodifiable(_adminNotifications);
  int get unreadCount => _unreadCount;

  /// Fetch notifications for regular user
  Future<void> fetchUserNotifications(String userId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _userNotifications = await _notificationRepository.getUserNotifications(userId);
      _unreadCount = _userNotifications.where((n) => !n.isRead).length;
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Fetch notifications for admin
  Future<void> fetchAdminNotifications() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _adminNotifications = await _notificationRepository.getAdminNotifications();
      _unreadCount = _adminNotifications.where((n) => !n.isRead).length;
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Create a notification
  Future<NotificationModel?> createNotification({
    required String userId,
    required String title,
    required String message,
    required NotificationType type,
    String? loanId,
  }) async {
    try {
      final notifId = 'NOTIF-${DateTime.now().millisecondsSinceEpoch}-${(100 + (DateTime.now().microsecondsSinceEpoch % 899))}';
      final notification = NotificationModel(
        id: notifId,
        userId: userId,
        title: title,
        message: message,
        type: type,
        loanId: loanId,
        createdAt: DateTime.now(),
        isRead: false,
      );

      final created = await _notificationRepository.createNotification(notification);

      if (userId == 'admin' || userId == 'system') {
        _adminNotifications.insert(0, created);
      } else {
        _userNotifications.insert(0, created);
      }

      _unreadCount++;
      notifyListeners();
      return created;
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      notifyListeners();
      return null;
    }
  }

  /// Mark single notification as read
  Future<bool> markAsRead(String notificationId) async {
    try {
      final success = await _notificationRepository.markAsRead(notificationId);
      if (success) {
        // Update local list
        final userIdx = _userNotifications.indexWhere((n) => n.id == notificationId);
        if (userIdx != -1) {
          _userNotifications[userIdx] = _userNotifications[userIdx].copyWith(isRead: true);
        }

        final adminIdx = _adminNotifications.indexWhere((n) => n.id == notificationId);
        if (adminIdx != -1) {
          _adminNotifications[adminIdx] = _adminNotifications[adminIdx].copyWith(isRead: true);
        }

        _unreadCount = (_unreadCount > 0) ? _unreadCount - 1 : 0;
        notifyListeners();
      }
      return success;
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      return false;
    }
  }

  /// Mark all notifications as read for current user / admin
  Future<bool> markAllAsRead(String userId) async {
    try {
      final success = await _notificationRepository.markAllAsRead(userId);
      if (success) {
        if (userId == 'admin') {
          _adminNotifications = _adminNotifications.map((n) => n.copyWith(isRead: true)).toList();
        } else {
          _userNotifications = _userNotifications.map((n) => n.copyWith(isRead: true)).toList();
        }
        _unreadCount = 0;
        notifyListeners();
      }
      return success;
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      return false;
    }
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }
}

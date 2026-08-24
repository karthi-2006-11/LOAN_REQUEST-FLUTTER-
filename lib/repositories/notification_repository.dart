import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/notification_model.dart';

abstract class NotificationRepository {
  Future<NotificationModel> createNotification(NotificationModel notification);
  Future<List<NotificationModel>> getUserNotifications(String userId);
  Future<List<NotificationModel>> getAdminNotifications();
  Future<bool> markAsRead(String notificationId);
  Future<bool> markAllAsRead(String userId);
  Future<int> getUnreadCount(String userId);
  Future<bool> deleteNotification(String notificationId);
}

class LocalNotificationRepository implements NotificationRepository {
  static const String _notificationsKey = 'key_notifications_data_v1';

  Future<List<NotificationModel>> _getAllNotificationsFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_notificationsKey);
    if (jsonString == null || jsonString.isEmpty) {
      return [];
    }

    try {
      final List<dynamic> jsonList = jsonDecode(jsonString);
      return jsonList
          .map((item) => NotificationModel.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<bool> _saveNotificationsToStorage(List<NotificationModel> notifications) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = notifications.map((n) => n.toJson()).toList();
    return await prefs.setString(_notificationsKey, jsonEncode(jsonList));
  }

  @override
  Future<NotificationModel> createNotification(NotificationModel notification) async {
    final notifications = await _getAllNotificationsFromStorage();
    
    // Protection against duplicate IDs or exact duplicate entries
    final exists = notifications.any((n) => n.id == notification.id);
    if (exists) {
      return notification;
    }

    notifications.insert(0, notification);
    await _saveNotificationsToStorage(notifications);
    return notification;
  }

  @override
  Future<List<NotificationModel>> getUserNotifications(String userId) async {
    final notifications = await _getAllNotificationsFromStorage();
    return notifications.where((n) => n.userId == userId).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<List<NotificationModel>> getAdminNotifications() async {
    final notifications = await _getAllNotificationsFromStorage();
    return notifications.where((n) => n.userId == 'admin' || n.userId == 'system').toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<bool> markAsRead(String notificationId) async {
    final notifications = await _getAllNotificationsFromStorage();
    final index = notifications.indexWhere((n) => n.id == notificationId);
    if (index != -1) {
      notifications[index] = notifications[index].copyWith(isRead: true);
      return await _saveNotificationsToStorage(notifications);
    }
    return false;
  }

  @override
  Future<bool> markAllAsRead(String userId) async {
    final notifications = await _getAllNotificationsFromStorage();
    bool updated = false;
    for (int i = 0; i < notifications.length; i++) {
      if ((notifications[i].userId == userId || (userId == 'admin' && notifications[i].userId == 'system')) && !notifications[i].isRead) {
        notifications[i] = notifications[i].copyWith(isRead: true);
        updated = true;
      }
    }
    if (updated) {
      return await _saveNotificationsToStorage(notifications);
    }
    return true;
  }

  @override
  Future<int> getUnreadCount(String userId) async {
    final userNotifications = userId == 'admin'
        ? await getAdminNotifications()
        : await getUserNotifications(userId);
    return userNotifications.where((n) => !n.isRead).length;
  }

  @override
  Future<bool> deleteNotification(String notificationId) async {
    final notifications = await _getAllNotificationsFromStorage();
    notifications.removeWhere((n) => n.id == notificationId);
    return await _saveNotificationsToStorage(notifications);
  }
}

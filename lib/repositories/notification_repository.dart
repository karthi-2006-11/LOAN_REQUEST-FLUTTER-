import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/notification_model.dart';
import '../services/database_service.dart';

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
  final DatabaseService _databaseService;

  LocalNotificationRepository({DatabaseService? databaseService})
      : _databaseService = databaseService ?? DatabaseService.instance;

  Map<String, dynamic> _toSqlMap(NotificationModel n) {
    return {
      'id': n.id,
      'userId': n.userId,
      'title': n.title,
      'message': n.message,
      'type': n.type.toJson(),
      'loanId': n.loanId,
      'createdAt': n.createdAt.toIso8601String(),
      'isRead': n.isRead ? 1 : 0,
    };
  }

  NotificationModel _fromSqlMap(Map<String, dynamic> map) {
    return NotificationModel(
      id: map['id'] as String,
      userId: map['userId'] as String,
      title: map['title'] as String,
      message: map['message'] as String,
      type: NotificationTypeExtension.fromString(map['type'] as String? ?? 'system'),
      loanId: map['loanId'] as String?,
      createdAt: map['createdAt'] != null
          ? DateTime.parse(map['createdAt'] as String)
          : DateTime.now(),
      isRead: (map['isRead'] as int? ?? 0) == 1,
    );
  }

  @override
  Future<NotificationModel> createNotification(NotificationModel notification) async {
    final db = await _databaseService.database;

    final existing = await db.query(
      'notifications',
      where: 'id = ?',
      whereArgs: [notification.id],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      return notification;
    }

    await db.insert(
      'notifications',
      _toSqlMap(notification),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return notification;
  }

  @override
  Future<List<NotificationModel>> getUserNotifications(String userId) async {
    final db = await _databaseService.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'notifications',
      where: 'userId = ?',
      whereArgs: [userId],
      orderBy: 'createdAt DESC',
    );
    return maps.map(_fromSqlMap).toList();
  }

  @override
  Future<List<NotificationModel>> getAdminNotifications() async {
    final db = await _databaseService.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'notifications',
      where: "userId IN ('admin', 'system')",
      orderBy: 'createdAt DESC',
    );
    return maps.map(_fromSqlMap).toList();
  }

  @override
  Future<bool> markAsRead(String notificationId) async {
    final db = await _databaseService.database;
    final count = await db.update(
      'notifications',
      {'isRead': 1},
      where: 'id = ?',
      whereArgs: [notificationId],
    );
    return count > 0;
  }

  @override
  Future<bool> markAllAsRead(String userId) async {
    final db = await _databaseService.database;
    if (userId == 'admin') {
      await db.update(
        'notifications',
        {'isRead': 1},
        where: "userId IN ('admin', 'system') AND isRead = 0",
      );
    } else {
      await db.update(
        'notifications',
        {'isRead': 1},
        where: 'userId = ? AND isRead = 0',
        whereArgs: [userId],
      );
    }
    return true;
  }

  @override
  Future<int> getUnreadCount(String userId) async {
    final db = await _databaseService.database;
    final List<Map<String, dynamic>> result;
    if (userId == 'admin') {
      result = await db.rawQuery(
        "SELECT COUNT(*) as count FROM notifications WHERE userId IN ('admin', 'system') AND isRead = 0",
      );
    } else {
      result = await db.rawQuery(
        "SELECT COUNT(*) as count FROM notifications WHERE userId = ? AND isRead = 0",
        [userId],
      );
    }
    return (result.first['count'] as int?) ?? 0;
  }

  @override
  Future<bool> deleteNotification(String notificationId) async {
    final db = await _databaseService.database;
    final count = await db.delete(
      'notifications',
      where: 'id = ?',
      whereArgs: [notificationId],
    );
    return count > 0;
  }
}

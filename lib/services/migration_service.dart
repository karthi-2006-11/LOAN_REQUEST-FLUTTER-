import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/loan_activity_model.dart';
import '../models/loan_model.dart';
import '../models/notification_model.dart';
import 'database_service.dart';

/// Service performing safe, idempotent, one-time migration of legacy SharedPreferences
/// JSON records into SQLite database tables.
class MigrationService {
  static final MigrationService instance = MigrationService._internal();
  factory MigrationService({DatabaseService? databaseService}) {
    if (databaseService != null) {
      return MigrationService._internal(databaseService: databaseService);
    }
    return instance;
  }

  MigrationService._internal({DatabaseService? databaseService})
      : _databaseService = databaseService ?? DatabaseService.instance;

  final DatabaseService _databaseService;

  static const String keyMigrationCompleted = 'key_sqlite_migration_completed_v1';
  static const String keyLegacyLoans = 'key_loans_data_v1';
  static const String keyLegacyActivities = 'key_loan_activity_data_v1';
  static const String keyLegacyNotifications = 'key_notifications_data_v1';

  /// Execute safe, one-time migration from SharedPreferences to SQLite
  Future<bool> runMigration({SharedPreferences? prefsOverride}) async {
    try {
      final prefs = prefsOverride ?? await SharedPreferences.getInstance();
      final isCompleted = prefs.getBool(keyMigrationCompleted) ?? false;
      if (isCompleted) {
        return true; // Migration already performed, return immediately
      }

      final db = await _databaseService.database;

      // 1. Read legacy data strings safely
      final loansJson = prefs.getString(keyLegacyLoans);
      final activitiesJson = prefs.getString(keyLegacyActivities);
      final notificationsJson = prefs.getString(keyLegacyNotifications);

      // 2. Parse legacy JSON strings before starting database transaction
      final List<LoanModel> legacyLoans = _parseLoans(loansJson);
      final List<LoanActivityModel> legacyActivities = _parseActivities(activitiesJson);
      final List<NotificationModel> legacyNotifications = _parseNotifications(notificationsJson);

      // 3. Execute atomic SQLite transaction
      await db.transaction((txn) async {
        // A. Migrate Loans (ConflictAlgorithm.ignore skips records if ID already exists)
        for (final loan in legacyLoans) {
          await txn.insert(
            'loans',
            loan.toJson(),
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }

        // B. Migrate Activities
        for (final activity in legacyActivities) {
          await txn.insert(
            'loan_activities',
            activity.toJson(),
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }

        // C. Migrate Notifications
        for (final notification in legacyNotifications) {
          await txn.insert(
            'notifications',
            {
              'id': notification.id,
              'userId': notification.userId,
              'title': notification.title,
              'message': notification.message,
              'type': notification.type.toJson(),
              'loanId': notification.loanId,
              'createdAt': notification.createdAt.toIso8601String(),
              'isRead': notification.isRead ? 1 : 0,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      });

      // 4. Mark migration as completed ONLY after transaction succeeds
      await prefs.setBool(keyMigrationCompleted, true);
      return true;
    } catch (_) {
      // Transaction failed or JSON corrupt: transaction rolled back safely, flag remains unset
      return false;
    }
  }

  List<LoanModel> _parseLoans(String? jsonString) {
    if (jsonString == null || jsonString.trim().isEmpty) return [];
    final List<dynamic> decoded = jsonDecode(jsonString) as List<dynamic>;
    return decoded
        .map((item) => LoanModel.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  List<LoanActivityModel> _parseActivities(String? jsonString) {
    if (jsonString == null || jsonString.trim().isEmpty) return [];
    final List<dynamic> decoded = jsonDecode(jsonString) as List<dynamic>;
    return decoded
        .map((item) => LoanActivityModel.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  List<NotificationModel> _parseNotifications(String? jsonString) {
    if (jsonString == null || jsonString.trim().isEmpty) return [];
    final List<dynamic> decoded = jsonDecode(jsonString) as List<dynamic>;
    return decoded
        .map((item) => NotificationModel.fromJson(item as Map<String, dynamic>))
        .toList();
  }
}

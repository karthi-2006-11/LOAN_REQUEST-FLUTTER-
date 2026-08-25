import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:loan_request_app/core/constants/app_constants.dart';
import 'package:loan_request_app/models/loan_activity_model.dart';
import 'package:loan_request_app/models/loan_model.dart';
import 'package:loan_request_app/models/loan_priority.dart';
import 'package:loan_request_app/models/loan_status.dart';
import 'package:loan_request_app/models/notification_model.dart';
import 'package:loan_request_app/services/database_service.dart';
import 'package:loan_request_app/services/migration_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Isolated test DatabaseService for MigrationService unit tests
class TestMigrationDatabaseService implements DatabaseService {
  final String dbPath;
  Database? _db;

  TestMigrationDatabaseService(this.dbPath);

  @override
  Future<Database> get database async {
    if (_db != null && _db!.isOpen) {
      return _db!;
    }
    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS users (
            id TEXT PRIMARY KEY,
            fullName TEXT NOT NULL,
            email TEXT NOT NULL UNIQUE,
            phone TEXT NOT NULL,
            role TEXT NOT NULL,
            passwordHash TEXT,
            createdAt TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS loans (
            id TEXT PRIMARY KEY,
            userId TEXT NOT NULL,
            userName TEXT NOT NULL,
            amount REAL NOT NULL,
            tenureMonths INTEGER NOT NULL,
            purpose TEXT NOT NULL,
            priority TEXT NOT NULL,
            status TEXT NOT NULL,
            createdAt TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS loan_activities (
            id TEXT PRIMARY KEY,
            loanId TEXT NOT NULL,
            userId TEXT NOT NULL,
            userName TEXT NOT NULL,
            type TEXT NOT NULL,
            message TEXT NOT NULL,
            createdAt TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS notifications (
            id TEXT PRIMARY KEY,
            userId TEXT NOT NULL,
            title TEXT NOT NULL,
            message TEXT NOT NULL,
            type TEXT NOT NULL,
            loanId TEXT,
            createdAt TEXT NOT NULL,
            isRead INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
    );
    return _db!;
  }

  @override
  Future<void> close() async {
    if (_db != null && _db!.isOpen) {
      await _db!.close();
      _db = null;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String testDbPath;
  late TestMigrationDatabaseService testDbService;
  late MigrationService migrationService;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final tempDir = Directory.systemTemp.createTempSync('migration_repo_test_');
    testDbPath = p.join(tempDir.path, 'test_migration.db');
    testDbService = TestMigrationDatabaseService(testDbPath);
    migrationService = MigrationService(databaseService: testDbService);
  });

  tearDown(() async {
    await testDbService.close();
    final file = File(testDbPath);
    if (file.existsSync()) {
      file.deleteSync();
    }
  });

  group('MigrationService Tests', () {
    test('1. Successful migration transfers legacy loans, activities, and notifications', () async {
      final legacyLoan = LoanModel(
        id: 'LOAN-LEGACY-1',
        userId: 'USR-101',
        userName: 'Legacy User',
        amount: 12000.0,
        tenureMonths: 12,
        purpose: 'Vehicle',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      final legacyActivity = LoanActivityModel(
        id: 'ACT-LEGACY-1',
        loanId: 'LOAN-LEGACY-1',
        userId: 'USR-101',
        userName: 'Legacy User',
        type: ActivityType.submitted,
        message: 'Legacy Submission',
        createdAt: DateTime.now(),
      );

      final legacyNotification = NotificationModel(
        id: 'NOTIF-LEGACY-1',
        userId: 'USR-101',
        title: 'Legacy Notif',
        message: 'Legacy Message',
        type: NotificationType.loanSubmitted,
        loanId: 'LOAN-LEGACY-1',
        createdAt: DateTime.now(),
        isRead: true,
      );

      SharedPreferences.setMockInitialValues({
        MigrationService.keyLegacyLoans: jsonEncode([legacyLoan.toJson()]),
        MigrationService.keyLegacyActivities: jsonEncode([legacyActivity.toJson()]),
        MigrationService.keyLegacyNotifications: jsonEncode([legacyNotification.toJson()]),
      });

      final result = await migrationService.runMigration();
      expect(result, isTrue);

      final db = await testDbService.database;
      final loans = await db.query('loans');
      expect(loans.length, equals(1));
      expect(loans.first['id'], equals('LOAN-LEGACY-1'));

      final activities = await db.query('loan_activities');
      expect(activities.length, equals(1));
      expect(activities.first['id'], equals('ACT-LEGACY-1'));

      final notifications = await db.query('notifications');
      expect(notifications.length, equals(1));
      expect(notifications.first['id'], equals('NOTIF-LEGACY-1'));
    });

    test('2. Handles empty or missing legacy SharedPreferences keys safely', () async {
      SharedPreferences.setMockInitialValues({});
      final result = await migrationService.runMigration();
      expect(result, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(MigrationService.keyMigrationCompleted), isTrue);

      final db = await testDbService.database;
      expect(await db.query('loans'), isEmpty);
      expect(await db.query('loan_activities'), isEmpty);
      expect(await db.query('notifications'), isEmpty);
    });

    test('3. Skips legacy records if duplicate IDs already exist in SQLite (non-destructive)', () async {
      final db = await testDbService.database;
      await db.insert('loans', {
        'id': 'LOAN-EXISTING-1',
        'userId': 'USR-1',
        'userName': 'Original SQLite User',
        'amount': 9999.0,
        'tenureMonths': 12,
        'purpose': 'Original Purpose',
        'priority': 'high',
        'status': 'approved',
        'createdAt': DateTime.now().toIso8601String(),
      });

      final conflictingLegacyLoan = LoanModel(
        id: 'LOAN-EXISTING-1',
        userId: 'USR-LEGACY',
        userName: 'Legacy Overwriter Attempt',
        amount: 1111.0,
        tenureMonths: 6,
        purpose: 'Attempted Overwrite',
        priority: LoanPriority.low,
        status: LoanStatus.rejected,
        createdAt: DateTime.now(),
      );

      SharedPreferences.setMockInitialValues({
        MigrationService.keyLegacyLoans: jsonEncode([conflictingLegacyLoan.toJson()]),
      });

      final result = await migrationService.runMigration();
      expect(result, isTrue);

      final loans = await db.query('loans', where: 'id = ?', whereArgs: ['LOAN-EXISTING-1']);
      expect(loans.length, equals(1));
      // Verify original row was preserved and NOT overwritten
      expect(loans.first['userName'], equals('Original SQLite User'));
      expect(loans.first['amount'], equals(9999.0));
    });

    test('4. Migration idempotency: Re-running migration produces no duplicate rows', () async {
      final legacyLoan = LoanModel(
        id: 'LOAN-IDEMP-1',
        userId: 'USR-1',
        userName: 'Idemp User',
        amount: 5000.0,
        tenureMonths: 12,
        purpose: 'Idempotency',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      SharedPreferences.setMockInitialValues({
        MigrationService.keyLegacyLoans: jsonEncode([legacyLoan.toJson()]),
      });

      await migrationService.runMigration();
      // Run again
      await migrationService.runMigration();

      final db = await testDbService.database;
      final loans = await db.query('loans');
      expect(loans.length, equals(1));
    });

    test('5 & 6. Malformed legacy JSON fails safely and triggers transaction rollback', () async {
      SharedPreferences.setMockInitialValues({
        MigrationService.keyLegacyLoans: 'CORRUPTED_JSON_STRING_{{{',
      });

      final result = await migrationService.runMigration();
      expect(result, isFalse);

      final prefs = await SharedPreferences.getInstance();
      // Migration flag MUST remain false / unset
      expect(prefs.getBool(MigrationService.keyMigrationCompleted) ?? false, isFalse);

      // Legacy key remains intact
      expect(prefs.getString(MigrationService.keyLegacyLoans), equals('CORRUPTED_JSON_STRING_{{{'));

      final db = await testDbService.database;
      expect(await db.query('loans'), isEmpty);
    });

    test('7. Migration completion flag is written ONLY after successful execution', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      expect(prefs.getBool(MigrationService.keyMigrationCompleted), isNull);

      final result = await migrationService.runMigration();
      expect(result, isTrue);
      expect(prefs.getBool(MigrationService.keyMigrationCompleted), isTrue);
    });

    test('8. Notification isRead boolean state is preserved correctly (0 and 1)', () async {
      final notifUnread = NotificationModel(
        id: 'N-UNREAD',
        userId: 'USR-1',
        title: 'Unread Title',
        message: 'Unread Msg',
        type: NotificationType.system,
        createdAt: DateTime.now(),
        isRead: false,
      );
      final notifRead = NotificationModel(
        id: 'N-READ',
        userId: 'USR-1',
        title: 'Read Title',
        message: 'Read Msg',
        type: NotificationType.loanApproved,
        createdAt: DateTime.now(),
        isRead: true,
      );

      SharedPreferences.setMockInitialValues({
        MigrationService.keyLegacyNotifications: jsonEncode([notifUnread.toJson(), notifRead.toJson()]),
      });

      await migrationService.runMigration();

      final db = await testDbService.database;
      final unreadRow = await db.query('notifications', where: 'id = ?', whereArgs: ['N-UNREAD']);
      final readRow = await db.query('notifications', where: 'id = ?', whereArgs: ['N-READ']);

      expect(unreadRow.first['isRead'], equals(0));
      expect(readRow.first['isRead'], equals(1));
    });

    test('9. Nullable notification loanId is preserved for both null and non-null values', () async {
      final notifNull = NotificationModel(
        id: 'N-NULL-LOAN',
        userId: 'USR-1',
        title: 'System Alert',
        message: 'No loan attached',
        type: NotificationType.system,
        loanId: null,
        createdAt: DateTime.now(),
      );
      final notifWithLoan = NotificationModel(
        id: 'N-WITH-LOAN',
        userId: 'USR-1',
        title: 'Loan Update',
        message: 'Loan attached',
        type: NotificationType.loanSubmitted,
        loanId: 'LOAN-888',
        createdAt: DateTime.now(),
      );

      SharedPreferences.setMockInitialValues({
        MigrationService.keyLegacyNotifications: jsonEncode([notifNull.toJson(), notifWithLoan.toJson()]),
      });

      await migrationService.runMigration();

      final db = await testDbService.database;
      final nullRow = await db.query('notifications', where: 'id = ?', whereArgs: ['N-NULL-LOAN']);
      final loanRow = await db.query('notifications', where: 'id = ?', whereArgs: ['N-WITH-LOAN']);

      expect(nullRow.first['loanId'], isNull);
      expect(loanRow.first['loanId'], equals('LOAN-888'));
    });

    test('10. Auth and Session SharedPreferences keys remain completely untouched', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyIsLoggedIn: true,
        AppConstants.keyUserEmail: 'alex@loanapp.com',
        AppConstants.keyUserId: 'USR-DEMO-101',
        AppConstants.keyUserRole: 'user',
        AppConstants.keyUserName: 'Alex Morgan',
      });

      await migrationService.runMigration();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AppConstants.keyIsLoggedIn), isTrue);
      expect(prefs.getString(AppConstants.keyUserEmail), equals('alex@loanapp.com'));
      expect(prefs.getString(AppConstants.keyUserId), equals('USR-DEMO-101'));
      expect(prefs.getString(AppConstants.keyUserRole), equals('user'));
      expect(prefs.getString(AppConstants.keyUserName), equals('Alex Morgan'));
    });
  });
}

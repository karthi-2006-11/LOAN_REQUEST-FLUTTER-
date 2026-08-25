import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:loan_request_app/models/notification_model.dart';
import 'package:loan_request_app/repositories/notification_repository.dart';
import 'package:loan_request_app/services/database_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Test DatabaseService subclass creating an isolated SQLite database file in system temp
class TestNotificationDatabaseService implements DatabaseService {
  final String dbPath;
  Database? _db;

  TestNotificationDatabaseService(this.dbPath);

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
        await db.execute('CREATE INDEX IF NOT EXISTS idx_notifications_userId ON notifications(userId);');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_notifications_loanId ON notifications(loanId);');
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
  late TestNotificationDatabaseService testDbService;
  late LocalNotificationRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final tempDir = Directory.systemTemp.createTempSync('notif_repo_test_');
    testDbPath = p.join(tempDir.path, 'test_notifications.db');
    testDbService = TestNotificationDatabaseService(testDbPath);
    repository = LocalNotificationRepository(databaseService: testDbService);
  });

  tearDown(() async {
    await testDbService.close();
    final file = File(testDbPath);
    if (file.existsSync()) {
      file.deleteSync();
    }
  });

  group('LocalNotificationRepository SQLite Tests', () {
    test('Fresh database has empty notifications', () async {
      final notifs = await repository.getUserNotifications('USR-101');
      expect(notifs, isEmpty);
    });

    test('createNotification inserts record and prevents duplicates', () async {
      final notif = NotificationModel(
        id: 'NOTIF-1',
        userId: 'USR-101',
        title: 'Welcome',
        message: 'Welcome to BlackVault',
        type: NotificationType.system,
        loanId: null,
        createdAt: DateTime.now(),
        isRead: false,
      );

      final created = await repository.createNotification(notif);
      expect(created.id, equals('NOTIF-1'));

      final duplicate = await repository.createNotification(notif);
      expect(duplicate.id, equals('NOTIF-1'));

      final userNotifs = await repository.getUserNotifications('USR-101');
      expect(userNotifs.length, equals(1));
    });

    test('getUserNotifications returns user notifications sorted by createdAt DESC', () async {
      final now = DateTime.now();
      final n1 = NotificationModel(
        id: 'NOTIF-A',
        userId: 'USR-USER1',
        title: 'First',
        message: 'Old Message',
        type: NotificationType.loanSubmitted,
        loanId: 'LOAN-1',
        createdAt: now.subtract(const Duration(hours: 2)),
      );
      final n2 = NotificationModel(
        id: 'NOTIF-B',
        userId: 'USR-USER1',
        title: 'Second',
        message: 'New Message',
        type: NotificationType.loanApproved,
        loanId: 'LOAN-1',
        createdAt: now.subtract(const Duration(hours: 1)),
      );

      await repository.createNotification(n1);
      await repository.createNotification(n2);

      final userNotifs = await repository.getUserNotifications('USR-USER1');
      expect(userNotifs.length, equals(2));
      expect(userNotifs[0].id, equals('NOTIF-B'));
      expect(userNotifs[1].id, equals('NOTIF-A'));
    });

    test('getAdminNotifications retrieves notifications for admin and system', () async {
      final nAdmin = NotificationModel(
        id: 'NOTIF-ADM',
        userId: 'admin',
        title: 'Admin Alert',
        message: 'New loan application',
        type: NotificationType.loanSubmitted,
        createdAt: DateTime.now(),
      );
      final nSystem = NotificationModel(
        id: 'NOTIF-SYS',
        userId: 'system',
        title: 'System Alert',
        message: 'System maintenance scheduled',
        type: NotificationType.system,
        createdAt: DateTime.now(),
      );

      await repository.createNotification(nAdmin);
      await repository.createNotification(nSystem);

      final adminNotifs = await repository.getAdminNotifications();
      expect(adminNotifs.length, equals(2));
      expect(adminNotifs.map((n) => n.id), containsAll({'NOTIF-ADM', 'NOTIF-SYS'}));
    });

    test('markAsRead updates single notification isRead status', () async {
      final n = NotificationModel(
        id: 'NOTIF-READ-1',
        userId: 'USR-TEST',
        title: 'Unread',
        message: 'Test message',
        type: NotificationType.loanApproved,
        createdAt: DateTime.now(),
        isRead: false,
      );
      await repository.createNotification(n);

      expect(await repository.getUnreadCount('USR-TEST'), equals(1));

      final success = await repository.markAsRead('NOTIF-READ-1');
      expect(success, isTrue);

      expect(await repository.getUnreadCount('USR-TEST'), equals(0));
    });

    test('markAllAsRead updates all unread notifications for user and admin', () async {
      final n1 = NotificationModel(
        id: 'NOTIF-U1',
        userId: 'USR-BULK',
        title: 'Msg 1',
        message: 'Msg 1',
        type: NotificationType.loanSubmitted,
        createdAt: DateTime.now(),
      );
      final n2 = NotificationModel(
        id: 'NOTIF-U2',
        userId: 'USR-BULK',
        title: 'Msg 2',
        message: 'Msg 2',
        type: NotificationType.loanRejected,
        createdAt: DateTime.now(),
      );

      await repository.createNotification(n1);
      await repository.createNotification(n2);

      expect(await repository.getUnreadCount('USR-BULK'), equals(2));

      await repository.markAllAsRead('USR-BULK');
      expect(await repository.getUnreadCount('USR-BULK'), equals(0));
    });

    test('deleteNotification removes notification from SQLite', () async {
      final n = NotificationModel(
        id: 'NOTIF-DEL',
        userId: 'USR-DEL',
        title: 'Delete Me',
        message: 'Will be deleted',
        type: NotificationType.system,
        createdAt: DateTime.now(),
      );
      await repository.createNotification(n);

      final deleted = await repository.deleteNotification('NOTIF-DEL');
      expect(deleted, isTrue);

      final list = await repository.getUserNotifications('USR-DEL');
      expect(list, isEmpty);
    });

    test('NotificationType enum values and nullable loanId round-trip correctly', () async {
      for (final type in NotificationType.values) {
        final id = 'NOTIF-TYPE-${type.name}';
        final n = NotificationModel(
          id: id,
          userId: 'USR-ENUM',
          title: 'Title ${type.name}',
          message: 'Message ${type.name}',
          type: type,
          loanId: type == NotificationType.system ? null : 'LOAN-123',
          createdAt: DateTime.now(),
          isRead: false,
        );
        await repository.createNotification(n);
      }

      final list = await repository.getUserNotifications('USR-ENUM');
      expect(list.length, equals(NotificationType.values.length));
      final loadedTypes = list.map((n) => n.type).toSet();
      expect(loadedTypes, containsAll(NotificationType.values));
    });

    test('Notifications persist across closing and reopening database connection', () async {
      final n = NotificationModel(
        id: 'NOTIF-PERSIST',
        userId: 'USR-PERSIST',
        title: 'Persist Title',
        message: 'Persisted notification text',
        type: NotificationType.loanApproved,
        loanId: 'LOAN-PERSIST',
        createdAt: DateTime.now(),
        isRead: false,
      );
      await repository.createNotification(n);

      // Close database connection
      await testDbService.close();

      // Reopen repository with same DB path
      final reopenedDbService = TestNotificationDatabaseService(testDbPath);
      final reopenedRepository = LocalNotificationRepository(databaseService: reopenedDbService);

      final fetched = await reopenedRepository.getUserNotifications('USR-PERSIST');
      expect(fetched.length, equals(1));
      expect(fetched.first.title, equals('Persist Title'));
      expect(fetched.first.type, equals(NotificationType.loanApproved));
      expect(fetched.first.loanId, equals('LOAN-PERSIST'));

      await reopenedDbService.close();
    });
  });
}

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:loan_request_app/models/loan_activity_model.dart';
import 'package:loan_request_app/repositories/loan_activity_repository.dart';
import 'package:loan_request_app/services/database_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Test DatabaseService subclass creating an isolated SQLite database file in system temp
class TestActivityDatabaseService implements DatabaseService {
  final String dbPath;
  Database? _db;

  TestActivityDatabaseService(this.dbPath);

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
        await db.execute('CREATE INDEX IF NOT EXISTS idx_loan_activities_loanId ON loan_activities(loanId);');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_loan_activities_userId ON loan_activities(userId);');
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
  late TestActivityDatabaseService testDbService;
  late LocalLoanActivityRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final tempDir = Directory.systemTemp.createTempSync('activity_repo_test_');
    testDbPath = p.join(tempDir.path, 'test_activities.db');
    testDbService = TestActivityDatabaseService(testDbPath);
    repository = LocalLoanActivityRepository(databaseService: testDbService);
  });

  tearDown(() async {
    await testDbService.close();
    final file = File(testDbPath);
    if (file.existsSync()) {
      file.deleteSync();
    }
  });

  group('LocalLoanActivityRepository SQLite Tests', () {
    test('Fresh database has empty activity history', () async {
      final activities = await repository.getAllActivities();
      expect(activities, isEmpty);
    });

    test('addActivity inserts record into SQLite database', () async {
      final activity = LoanActivityModel(
        id: 'ACT-101',
        loanId: 'LOAN-1001',
        userId: 'USR-101',
        userName: 'Alex Morgan',
        type: ActivityType.submitted,
        message: 'Loan application submitted',
        createdAt: DateTime.now(),
      );

      final added = await repository.addActivity(activity);
      expect(added.id, equals('ACT-101'));

      final all = await repository.getAllActivities();
      expect(all.length, equals(1));
      expect(all.first.message, equals('Loan application submitted'));
    });

    test('getLoanActivities returns activities for specific loanId in chronological (ASC) order', () async {
      final now = DateTime.now();
      final act1 = LoanActivityModel(
        id: 'ACT-1',
        loanId: 'LOAN-A',
        userId: 'USR-1',
        userName: 'User One',
        type: ActivityType.submitted,
        message: 'Submitted',
        createdAt: now.subtract(const Duration(hours: 2)),
      );
      final act2 = LoanActivityModel(
        id: 'ACT-2',
        loanId: 'LOAN-A',
        userId: 'USR-1',
        userName: 'User One',
        type: ActivityType.approved,
        message: 'Approved',
        createdAt: now.subtract(const Duration(hours: 1)),
      );
      final actOther = LoanActivityModel(
        id: 'ACT-3',
        loanId: 'LOAN-B',
        userId: 'USR-1',
        userName: 'User One',
        type: ActivityType.submitted,
        message: 'Other Loan Submitted',
        createdAt: now,
      );

      await repository.addActivity(act1);
      await repository.addActivity(act2);
      await repository.addActivity(actOther);

      final loanAActivities = await repository.getLoanActivities('LOAN-A');
      expect(loanAActivities.length, equals(2));
      // Chronological order verification (oldest first)
      expect(loanAActivities[0].id, equals('ACT-1'));
      expect(loanAActivities[1].id, equals('ACT-2'));
    });

    test('getUserActivities returns activities for specific userId in newest-first (DESC) order', () async {
      final now = DateTime.now();
      final act1 = LoanActivityModel(
        id: 'ACT-10',
        loanId: 'LOAN-10',
        userId: 'USR-ALEX',
        userName: 'Alex',
        type: ActivityType.submitted,
        message: 'First Activity',
        createdAt: now.subtract(const Duration(hours: 5)),
      );
      final act2 = LoanActivityModel(
        id: 'ACT-20',
        loanId: 'LOAN-20',
        userId: 'USR-ALEX',
        userName: 'Alex',
        type: ActivityType.approved,
        message: 'Second Activity',
        createdAt: now.subtract(const Duration(hours: 1)),
      );

      await repository.addActivity(act1);
      await repository.addActivity(act2);

      final alexActivities = await repository.getUserActivities('USR-ALEX');
      expect(alexActivities.length, equals(2));
      // Newest first verification
      expect(alexActivities[0].id, equals('ACT-20'));
      expect(alexActivities[1].id, equals('ACT-10'));
    });

    test('ActivityType enum values round-trip correctly', () async {
      for (final type in ActivityType.values) {
        final id = 'ACT-TYPE-${type.name}';
        final activity = LoanActivityModel(
          id: id,
          loanId: 'LOAN-ENUM',
          userId: 'USR-ENUM',
          userName: 'Enum Tester',
          type: type,
          message: 'Testing type ${type.name}',
          createdAt: DateTime.now(),
        );

        await repository.addActivity(activity);
      }

      final activities = await repository.getLoanActivities('LOAN-ENUM');
      expect(activities.length, equals(ActivityType.values.length));
      final loadedTypes = activities.map((a) => a.type).toSet();
      expect(loadedTypes, containsAll(ActivityType.values));
    });

    test('Activities persist across database close and reopen', () async {
      final activity = LoanActivityModel(
        id: 'ACT-PERSIST-1',
        loanId: 'LOAN-PERSIST',
        userId: 'USR-PERSIST',
        userName: 'Persist User',
        type: ActivityType.underReview,
        message: 'Persisted Activity Message',
        createdAt: DateTime.now(),
      );
      await repository.addActivity(activity);

      // Close database
      await testDbService.close();

      // Reopen repository with same DB path
      final reopenedDbService = TestActivityDatabaseService(testDbPath);
      final reopenedRepository = LocalLoanActivityRepository(databaseService: reopenedDbService);

      final fetched = await reopenedRepository.getLoanActivities('LOAN-PERSIST');
      expect(fetched.length, equals(1));
      expect(fetched.first.message, equals('Persisted Activity Message'));
      expect(fetched.first.type, equals(ActivityType.underReview));

      await reopenedDbService.close();
    });
  });
}

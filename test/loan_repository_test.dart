import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:loan_request_app/models/loan_model.dart';
import 'package:loan_request_app/models/loan_priority.dart';
import 'package:loan_request_app/models/loan_status.dart';
import 'package:loan_request_app/repositories/loan_repository.dart';
import 'package:loan_request_app/services/database_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Test DatabaseService subclass creating an isolated SQLite database file in system temp
class TestDatabaseService implements DatabaseService {
  final String dbPath;
  Database? _db;

  TestDatabaseService(this.dbPath);

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
        await db.execute('CREATE INDEX IF NOT EXISTS idx_loans_userId ON loans(userId);');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_loans_status ON loans(status);');
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
  late TestDatabaseService testDbService;
  late LocalLoanRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final tempDir = Directory.systemTemp.createTempSync('loan_repo_test_');
    testDbPath = p.join(tempDir.path, 'test_loans.db');
    testDbService = TestDatabaseService(testDbPath);
    repository = LocalLoanRepository(databaseService: testDbService);
  });

  tearDown(() async {
    await testDbService.close();
    final file = File(testDbPath);
    if (file.existsSync()) {
      file.deleteSync();
    }
  });

  group('LocalLoanRepository SQLite Tests', () {
    test('Fresh database seeds default loans LOAN-1001 and LOAN-1002', () async {
      final loans = await repository.getAllLoans();
      expect(loans.length, equals(2));
      expect(loans.map((l) => l.id), containsAll({'LOAN-1001', 'LOAN-1002'}));
      expect(loans.first.userId, equals('USR-DEMO-101'));
    });

    test('getUserLoans returns loans filtered by userId', () async {
      final userLoans = await repository.getUserLoans('USR-DEMO-101');
      expect(userLoans.length, equals(2));

      final emptyLoans = await repository.getUserLoans('USR-NON-EXISTENT');
      expect(emptyLoans, isEmpty);
    });

    test('getLoanById returns correct loan or null if not found', () async {
      final loan = await repository.getLoanById('LOAN-1001');
      expect(loan, isNotNull);
      expect(loan!.userName, equals('Alex Morgan'));
      expect(loan.amount, equals(5000.00));

      final notFound = await repository.getLoanById('INVALID-ID');
      expect(notFound, isNull);
    });

    test('createLoan inserts new loan into SQLite database', () async {
      final newLoan = LoanModel(
        id: 'LOAN-9999',
        userId: 'USR-TEST-001',
        userName: 'Taylor Swift',
        amount: 25000.00,
        tenureMonths: 36,
        purpose: 'Equipment Purchase',
        priority: LoanPriority.high,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      final created = await repository.createLoan(newLoan);
      expect(created.id, equals('LOAN-9999'));

      final fetched = await repository.getLoanById('LOAN-9999');
      expect(fetched, isNotNull);
      expect(fetched!.amount, equals(25000.00));
      expect(fetched.priority, equals(LoanPriority.high));
      expect(fetched.status, equals(LoanStatus.pending));
    });

    test('updateLoanStatus updates loan status in SQLite', () async {
      final updated = await repository.updateLoanStatus('LOAN-1002', LoanStatus.approved);
      expect(updated.status, equals(LoanStatus.approved));

      final fetched = await repository.getLoanById('LOAN-1002');
      expect(fetched!.status, equals(LoanStatus.approved));
    });

    test('deleteLoan removes loan record from SQLite', () async {
      final deleted = await repository.deleteLoan('LOAN-1001');
      expect(deleted, isTrue);

      final fetched = await repository.getLoanById('LOAN-1001');
      expect(fetched, isNull);

      final remaining = await repository.getAllLoans();
      expect(remaining.length, equals(1));
    });

    test('Enum values LoanPriority and LoanStatus round-trip correctly', () async {
      for (final priority in LoanPriority.values) {
        for (final status in LoanStatus.values) {
          final id = 'LOAN-ENUM-${priority.name}-${status.name}';
          final model = LoanModel(
            id: id,
            userId: 'USR-ENUM',
            userName: 'Enum Tester',
            amount: 1000.0,
            tenureMonths: 6,
            purpose: 'Testing',
            priority: priority,
            status: status,
            createdAt: DateTime.now(),
          );
          await repository.createLoan(model);
          final fetched = await repository.getLoanById(id);
          expect(fetched!.priority, equals(priority));
          expect(fetched.status, equals(status));
        }
      }
    });

    test('Data persists across closing and reopening database connection', () async {
      final newLoan = LoanModel(
        id: 'LOAN-PERSIST-1',
        userId: 'USR-PERSIST',
        userName: 'Persist User',
        amount: 8000.0,
        tenureMonths: 12,
        purpose: 'Home Renovation',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );
      await repository.createLoan(newLoan);

      // Close database
      await testDbService.close();

      // Reopen repository with same DB path
      final reopenedDbService = TestDatabaseService(testDbPath);
      final reopenedRepository = LocalLoanRepository(databaseService: reopenedDbService);

      final fetched = await reopenedRepository.getLoanById('LOAN-PERSIST-1');
      expect(fetched, isNotNull);
      expect(fetched!.amount, equals(8000.0));
      expect(fetched.purpose, equals('Home Renovation'));

      await reopenedDbService.close();
    });
  });
}

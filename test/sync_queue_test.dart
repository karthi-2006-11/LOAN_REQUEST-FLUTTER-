import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:loan_request_app/models/loan_model.dart';
import 'package:loan_request_app/models/loan_priority.dart';
import 'package:loan_request_app/models/loan_status.dart';
import 'package:loan_request_app/models/sync_queue_item.dart';
import 'package:loan_request_app/repositories/loan_repository.dart';
import 'package:loan_request_app/repositories/sync_queue_repository.dart';
import 'package:loan_request_app/services/database_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class TestSyncQueueDatabaseService implements DatabaseService {
  final String dbPath;
  Database? _db;

  TestSyncQueueDatabaseService(this.dbPath);

  @override
  Future<Database> get database async {
    if (_db != null && _db!.isOpen) {
      return _db!;
    }
    _db = await openDatabase(
      dbPath,
      version: 2,
      onConfigure: (db) async => await db.execute('PRAGMA foreign_keys = ON;'),
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
        await db.execute('''
          CREATE TABLE IF NOT EXISTS sync_queue (
            id TEXT PRIMARY KEY,
            entityType TEXT NOT NULL,
            entityId TEXT NOT NULL,
            operation TEXT NOT NULL,
            payload TEXT NOT NULL,
            clientOperationId TEXT NOT NULL UNIQUE,
            createdAt TEXT NOT NULL,
            retryCount INTEGER NOT NULL DEFAULT 0,
            lastAttemptAt TEXT,
            status TEXT NOT NULL DEFAULT 'PENDING_SYNC',
            error TEXT
          )
        ''');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_sync_queue_status ON sync_queue(status);');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_sync_queue_createdAt ON sync_queue(createdAt);');
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
  late TestSyncQueueDatabaseService testDbService;
  late LocalSyncQueueRepository queueRepo;
  late LocalLoanRepository loanRepo;
  late String testDbPath;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final tempDir = Directory.systemTemp.createTempSync('sq_test_');
    testDbPath = p.join(tempDir.path, 'blackvault_sq_test.db');
    testDbService = TestSyncQueueDatabaseService(testDbPath);
    queueRepo = LocalSyncQueueRepository(databaseService: testDbService);
    loanRepo = LocalLoanRepository(databaseService: testDbService);
  });

  tearDown(() async {
    await testDbService.close();
    final file = File(testDbPath);
    if (file.existsSync()) {
      file.deleteSync();
    }
  });

  group('Sync Queue & Database Migration Tests', () {
    test('1. Database v1 to v2 Migration preserves existing loan data and creates sync_queue', () async {
      final migrationTempDir = Directory.systemTemp.createTempSync('mig_test_');
      final migDbPath = p.join(migrationTempDir.path, 'legacy_v1.db');

      // Create v1 database and insert legacy loan
      final v1Db = await openDatabase(
        migDbPath,
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE loans (
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
        },
      );

      await v1Db.insert('loans', {
        'id': 'LOAN-MIG-1',
        'userId': 'USR-MIG',
        'userName': 'Migration User',
        'amount': 12000.0,
        'tenureMonths': 12,
        'purpose': 'Upgrade Test',
        'priority': 'medium',
        'status': 'approved',
        'createdAt': DateTime.now().toIso8601String(),
      });
      await v1Db.close();

      // Open database with version 2 and run onUpgrade
      final v2Db = await openDatabase(
        migDbPath,
        version: 2,
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS sync_queue (
                id TEXT PRIMARY KEY,
                entityType TEXT NOT NULL,
                entityId TEXT NOT NULL,
                operation TEXT NOT NULL,
                payload TEXT NOT NULL,
                clientOperationId TEXT NOT NULL UNIQUE,
                createdAt TEXT NOT NULL,
                retryCount INTEGER NOT NULL DEFAULT 0,
                lastAttemptAt TEXT,
                status TEXT NOT NULL DEFAULT 'PENDING_SYNC',
                error TEXT
              )
            ''');
          }
        },
      );

      // Verify legacy data preserved
      final loans = await v2Db.query('loans', where: 'id = ?', whereArgs: ['LOAN-MIG-1']);
      expect(loans.length, equals(1));
      expect(loans.first['purpose'], equals('Upgrade Test'));

      // Verify sync_queue table created and empty
      final queueItems = await v2Db.query('sync_queue');
      expect(queueItems, isEmpty);

      await v2Db.close();
      if (File(migDbPath).existsSync()) {
        File(migDbPath).deleteSync();
      }
    });

    test('2. Enqueueing item creates sync_queue record with unique clientOperationId', () async {
      final now = DateTime.now();
      final item = SyncQueueItem(
        id: 'SQ-001',
        entityType: 'loan',
        entityId: 'LOAN-TEST-001',
        operation: 'CREATE',
        payload: {'id': 'LOAN-TEST-001', 'amount': 5000.0},
        clientOperationId: 'OP-CLIENT-UNIQUE-001',
        createdAt: now,
      );

      await queueRepo.enqueue(item);

      final retrieved = await queueRepo.getByClientOperationId('OP-CLIENT-UNIQUE-001');
      expect(retrieved, isNotNull);
      expect(retrieved!.entityType, equals('loan'));
      expect(retrieved.operation, equals('CREATE'));
      expect(retrieved.status, equals('PENDING_SYNC'));
    });

    test('3. Atomic Transaction Safety: Success path creates loan and sync_queue entry together', () async {
      final newLoan = LoanModel(
        id: 'LOAN-ATOMIC-OK',
        userId: 'USR-ATOMIC',
        userName: 'Atomic User',
        amount: 9000.0,
        tenureMonths: 12,
        purpose: 'Equipment Purchase',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(newLoan);

      // Verify loan created
      final savedLoan = await loanRepo.getLoanById('LOAN-ATOMIC-OK');
      expect(savedLoan, isNotNull);
      expect(savedLoan!.amount, equals(9000.0));

      // Verify sync_queue entry created
      final pending = await queueRepo.getPendingItems();
      expect(pending.any((i) => i.entityId == 'LOAN-ATOMIC-OK' && i.operation == 'CREATE'), isTrue);
    });

    test('4. Atomic Transaction Safety: Failure during sync_queue insertion rolls back business record', () async {
      final db = await testDbService.database;

      // Force failure by inserting a duplicate clientOperationId to violate UNIQUE constraint inside transaction
      const duplicateClientOpId = 'OP-DUP-FAIL-001';

      await queueRepo.enqueue(SyncQueueItem(
        id: 'SQ-EXISTING',
        entityType: 'loan',
        entityId: 'LOAN-PREV',
        operation: 'CREATE',
        payload: {},
        clientOperationId: duplicateClientOpId,
        createdAt: DateTime.now(),
      ));

      // Attempt transaction where sync_queue fails due to duplicate clientOperationId
      try {
        await db.transaction((txn) async {
          await txn.insert('loans', {
            'id': 'LOAN-SHOULD-ROLLBACK',
            'userId': 'USR-ROLLBACK',
            'userName': 'Rollback User',
            'amount': 50000.0,
            'tenureMonths': 24,
            'purpose': 'Rollback Test',
            'priority': 'high',
            'status': 'pending',
            'createdAt': DateTime.now().toIso8601String(),
          });

          // This will throw DatabaseException (UNIQUE constraint failed)
          await txn.insert('sync_queue', {
            'id': 'SQ-DUP-FAIL',
            'entityType': 'loan',
            'entityId': 'LOAN-SHOULD-ROLLBACK',
            'operation': 'CREATE',
            'payload': '{}',
            'clientOperationId': duplicateClientOpId, // Duplicate!
            'createdAt': DateTime.now().toIso8601String(),
            'status': 'PENDING_SYNC',
          });
        });
        fail('Transaction should have failed and thrown Exception');
      } catch (e) {
        expect(e, isA<DatabaseException>());
      }

      // Crucial assertion: Verify LOAN-SHOULD-ROLLBACK does NOT exist in loans table
      final rolledBackLoan = await loanRepo.getLoanById('LOAN-SHOULD-ROLLBACK');
      expect(rolledBackLoan, isNull);
    });

    test('5. Queue retrieval returns pending entries ordered deterministically (createdAt ASC)', () async {
      final t1 = DateTime.now().subtract(const Duration(minutes: 10));
      final t2 = DateTime.now().subtract(const Duration(minutes: 5));

      await queueRepo.enqueue(SyncQueueItem(
        id: 'SQ-ORDER-2',
        entityType: 'loan',
        entityId: 'LOAN-2',
        operation: 'UPDATE',
        payload: {},
        clientOperationId: 'OP-ORDER-2',
        createdAt: t2,
      ));

      await queueRepo.enqueue(SyncQueueItem(
        id: 'SQ-ORDER-1',
        entityType: 'loan',
        entityId: 'LOAN-1',
        operation: 'CREATE',
        payload: {},
        clientOperationId: 'OP-ORDER-1',
        createdAt: t1,
      ));

      final pending = await queueRepo.getPendingItems();
      expect(pending.length, equals(2));
      expect(pending.first.clientOperationId, equals('OP-ORDER-1'));
    });

    test('6. State Transitions: PENDING_SYNC -> SYNCING -> SYNCED and retry increments', () async {
      final item = SyncQueueItem(
        id: 'SQ-STATE-1',
        entityType: 'loan',
        entityId: 'LOAN-STATE-1',
        operation: 'CREATE',
        payload: {},
        clientOperationId: 'OP-STATE-1',
        createdAt: DateTime.now(),
      );

      await queueRepo.enqueue(item);

      // Transition to SYNCING
      await queueRepo.updateStatus('SQ-STATE-1', 'SYNCING');
      var updated = await queueRepo.getByClientOperationId('OP-STATE-1');
      expect(updated!.status, equals('SYNCING'));

      // Transition to SYNC_FAILED & increment retry
      await queueRepo.incrementRetry('SQ-STATE-1', error: 'Network timeout');
      updated = await queueRepo.getByClientOperationId('OP-STATE-1');
      expect(updated!.status, equals('SYNC_FAILED'));
      expect(updated.retryCount, equals(1));
      expect(updated.error, equals('Network timeout'));

      // Transition to SYNCED
      await queueRepo.updateStatus('SQ-STATE-1', 'SYNCED');
      updated = await queueRepo.getByClientOperationId('OP-STATE-1');
      expect(updated!.status, equals('SYNCED'));
    });
  });
}

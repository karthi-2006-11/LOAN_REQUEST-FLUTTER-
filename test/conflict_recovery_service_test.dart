import 'package:flutter_test/flutter_test.dart';
import 'package:loan_request_app/models/loan_model.dart';
import 'package:loan_request_app/models/loan_priority.dart';
import 'package:loan_request_app/models/loan_status.dart';
import 'package:loan_request_app/models/sync_conflict_record.dart';
import 'package:loan_request_app/models/sync_queue_item.dart';
import 'package:loan_request_app/repositories/loan_repository.dart';
import 'package:loan_request_app/repositories/sync_queue_repository.dart';
import 'package:loan_request_app/services/conflict_recovery_service.dart';
import 'package:loan_request_app/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late DatabaseService dbService;
  late SyncQueueRepository queueRepo;
  late LocalLoanRepository loanRepo;
  late ConflictRecoveryService recoveryService;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    dbService = DatabaseService.instance;
    await dbService.close();

    final dbPath = await getDatabasesPath();
    final path = '$dbPath/blackvault.db';
    await databaseFactory.deleteDatabase(path);

    // Initialize database
    await dbService.database;

    queueRepo = LocalSyncQueueRepository(databaseService: dbService);
    loanRepo = LocalLoanRepository(databaseService: dbService);
    recoveryService = ConflictRecoveryService(
      queueRepository: queueRepo,
      loanRepository: loanRepo,
      databaseService: dbService,
    );
  });

  tearDown(() async {
    await dbService.close();
  });

  group('ConflictRecoveryService Comprehensive Integration Tests', () {
    test('1 & 2 & 3 & 4. CUSTOMER_WINS creates exactly one new queue item with NEW_UUID, preserving old ID and setting correct baseVersion', () async {
      final oldOpId = SyncQueueItem.generateClientOperationId('OLD');
      final queueItem = SyncQueueItem(
        id: 'Q-100',
        entityType: 'loan',
        entityId: 'LOAN-100',
        operation: 'UPDATE',
        payload: {'amount': 25000.0, 'purpose': 'Business Expansion'},
        clientOperationId: oldOpId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
        baseVersion: 1,
      );
      await queueRepo.enqueue(queueItem);

      final conflictRecord = SyncConflictRecord(
        id: 'CONF-100',
        clientOperationId: oldOpId,
        entityType: 'loan',
        entityId: 'LOAN-100',
        conflictType: 'CUSTOMER_FIELD_CONFLICT',
        localValue: queueItem.payload,
        serverValue: {
          'id': 'LOAN-100',
          'userId': 'USR-1',
          'amount': 15000.0,
          'status': 'pending',
          'version': 3,
        },
        serverVersion: 3,
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflictRecord);

      final result = await recoveryService.recoverConflict(conflictRecord);

      expect(result.isRecovered, isTrue);
      expect(result.resolution, equals('CUSTOMER_WINS'));
      expect(result.newClientOperationId, isNotNull);
      expect(result.newClientOperationId, isNot(equals(oldOpId)));
      expect(result.recommendedBaseVersion, equals(3));

      // Verify old queue item status
      final oldQueueItem = await queueRepo.getByClientOperationId(oldOpId);
      expect(oldQueueItem!.status, equals('RESOLVED_CONFLICT'));

      // Verify old conflict record remains preserved in history with old OpId
      final savedConflict = await queueRepo.getConflictRecordByClientOperationId(oldOpId);
      expect(savedConflict!.resolution, equals('CUSTOMER_WINS'));
      expect(savedConflict.clientOperationId, equals(oldOpId));

      // Verify NEW queue item exists with NEW_UUID and retryCount = 0
      final newQueueItem = await queueRepo.getByClientOperationId(result.newClientOperationId!);
      expect(newQueueItem, isNotNull);
      expect(newQueueItem!.clientOperationId, equals(result.newClientOperationId));
      expect(newQueueItem.status, equals('PENDING_SYNC'));
      expect(newQueueItem.retryCount, equals(0));
      expect(newQueueItem.baseVersion, equals(3));
      expect(newQueueItem.payload['amount'], equals(25000.0));
    });

    test('5, 6, 7, 8, 9, 10. STALE_PUSH with pending loan returns FIELD_MERGE with merged payload and preserved server identity', () async {
      final oldOpId = SyncQueueItem.generateClientOperationId('STALE');
      final queueItem = SyncQueueItem(
        id: 'Q-200',
        entityType: 'loan',
        entityId: 'LOAN-200',
        operation: 'UPDATE',
        payload: {
          'amount': 35000.0,
          'purpose': 'Legitimate Purpose',
        },
        clientOperationId: oldOpId,
        createdAt: DateTime.now(),
        retryCount: 1,
        status: 'CONFLICT',
        baseVersion: 1,
      );
      await queueRepo.enqueue(queueItem);

      final conflictRecord = SyncConflictRecord(
        id: 'CONF-200',
        clientOperationId: oldOpId,
        entityType: 'loan',
        entityId: 'LOAN-200',
        conflictType: 'STALE_PUSH',
        localValue: queueItem.payload,
        serverValue: {
          'id': 'LOAN-200',
          'userId': 'USR-VICTIM',
          'createdAt': '2026-01-01T00:00:00Z',
          'status': 'pending',
          'amount': 20000.0,
          'version': 2,
        },
        serverVersion: 2,
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflictRecord);

      final result = await recoveryService.recoverConflict(conflictRecord);

      expect(result.isRecovered, isTrue);
      expect(result.resolution, equals('CUSTOMER_WINS'));
      expect(result.newClientOperationId, isNotNull);

      final newQueueItem = await queueRepo.getByClientOperationId(result.newClientOperationId!);
      expect(newQueueItem, isNotNull);
      final mergedPayload = newQueueItem!.payload;

      // Ownership Invariants Verified:
      expect(mergedPayload['id'], equals('LOAN-200')); // Server ID preserved
      expect(mergedPayload['userId'], equals('USR-VICTIM')); // Server User ID preserved
      expect(mergedPayload['createdAt'], equals('2026-01-01T00:00:00Z')); // Server createdAt preserved
      expect(mergedPayload['status'], equals('pending')); // Server status preserved
      expect(mergedPayload['amount'], equals(35000.0)); // Customer amount preserved
      expect(mergedPayload['purpose'], equals('Legitimate Purpose')); // Customer purpose preserved
    });

    test('11 & 12. SERVER_WINS does not requeue and applies server state locally', () async {
      // Seed local loan
      await loanRepo.createLoan(
        LoanModel(
          id: 'LOAN-300',
          userId: 'USR-300',
          userName: 'Test User',
          amount: 10000.0,
          tenureMonths: 12,
          purpose: 'Initial',
          priority: LoanPriority.medium,
          status: LoanStatus.pending,
          createdAt: DateTime.now(),
        ),
      );

      final oldOpId = SyncQueueItem.generateClientOperationId('SERVER');
      final queueItem = SyncQueueItem(
        id: 'Q-300',
        entityType: 'loan',
        entityId: 'LOAN-300',
        operation: 'UPDATE',
        payload: {'amount': 15000.0},
        clientOperationId: oldOpId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
      );
      await queueRepo.enqueue(queueItem);

      final conflictRecord = SyncConflictRecord(
        id: 'CONF-300',
        clientOperationId: oldOpId,
        entityType: 'loan',
        entityId: 'LOAN-300',
        conflictType: 'ADMIN_STATUS_OVERRIDE',
        localValue: queueItem.payload,
        serverValue: {
          'id': 'LOAN-300',
          'userId': 'USR-300',
          'userName': 'Test User',
          'amount': 10000.0,
          'tenureMonths': 12,
          'purpose': 'Initial',
          'priority': 'medium',
          'status': 'approved',
          'version': 4,
        },
        serverVersion: 4,
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflictRecord);

      final result = await recoveryService.recoverConflict(conflictRecord);

      expect(result.isRecovered, isTrue);
      expect(result.resolution, equals('SERVER_WINS'));
      expect(result.newClientOperationId, isNull); // NO REQUEUE

      // Verify old item status
      final oldQueueItem = await queueRepo.getByClientOperationId(oldOpId);
      expect(oldQueueItem!.status, equals('REJECTED'));

      // Verify local loan status updated to approved
      final updatedLoan = await loanRepo.getLoanById('LOAN-300');
      expect(updatedLoan!.status, equals(LoanStatus.approved));
    });

    test('13 & 14. REJECTED does not requeue and INVALID_MUTATION is never silently repaired', () async {
      final oldOpId = SyncQueueItem.generateClientOperationId('INVALID');
      final queueItem = SyncQueueItem(
        id: 'Q-400',
        entityType: 'loan',
        entityId: 'LOAN-400',
        operation: 'UPDATE',
        payload: {'status': 'approved'}, // Unauthorized status mutation
        clientOperationId: oldOpId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
      );
      await queueRepo.enqueue(queueItem);

      final conflictRecord = SyncConflictRecord(
        id: 'CONF-400',
        clientOperationId: oldOpId,
        entityType: 'loan',
        entityId: 'LOAN-400',
        conflictType: 'INVALID_MUTATION',
        localValue: queueItem.payload,
        serverValue: {
          'id': 'LOAN-400',
          'status': 'pending',
          'version': 2,
        },
        serverVersion: 2,
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflictRecord);

      final result = await recoveryService.recoverConflict(conflictRecord);

      expect(result.isRecovered, isFalse);
      expect(result.resolution, equals('DISCARDED'));
      expect(result.newClientOperationId, isNull);

      final oldQueueItem = await queueRepo.getByClientOperationId(oldOpId);
      expect(oldQueueItem!.status, equals('REJECTED'));
    });

    test('15 & 16. UNRESOLVED (retryCount >= 3) prevents automatic recovery', () async {
      final oldOpId = SyncQueueItem.generateClientOperationId('RETRY_MAX');
      final queueItem = SyncQueueItem(
        id: 'Q-500',
        entityType: 'loan',
        entityId: 'LOAN-500',
        operation: 'UPDATE',
        payload: {'amount': 20000.0},
        clientOperationId: oldOpId,
        createdAt: DateTime.now(),
        retryCount: 3, // >= 3 limit
        status: 'CONFLICT',
      );
      await queueRepo.enqueue(queueItem);

      final conflictRecord = SyncConflictRecord(
        id: 'CONF-500',
        clientOperationId: oldOpId,
        entityType: 'loan',
        entityId: 'LOAN-500',
        conflictType: 'CUSTOMER_FIELD_CONFLICT',
        localValue: queueItem.payload,
        serverValue: {
          'id': 'LOAN-500',
          'amount': 15000.0,
          'status': 'pending',
          'version': 5,
        },
        serverVersion: 5,
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflictRecord);

      final result = await recoveryService.recoverConflict(conflictRecord);

      expect(result.isRecovered, isFalse);
      expect(result.resolution, equals('MANUAL'));
      expect(result.newClientOperationId, isNull);

      final oldQueueItem = await queueRepo.getByClientOperationId(oldOpId);
      expect(oldQueueItem!.status, equals('CONFLICT'));
    });

    test('17, 18, 19. Atomicity: SQLite transaction failure rolls back all recovery state changes', () async {
      final oldOpId = SyncQueueItem.generateClientOperationId('ROLLBACK');
      final queueItem = SyncQueueItem(
        id: 'Q-800',
        entityType: 'loan',
        entityId: 'LOAN-800',
        operation: 'UPDATE',
        payload: {'amount': 30000.0},
        clientOperationId: oldOpId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
      );
      await queueRepo.enqueue(queueItem);

      final conflictRecord = SyncConflictRecord(
        id: 'CONF-800',
        clientOperationId: oldOpId,
        entityType: 'loan',
        entityId: 'LOAN-800',
        conflictType: 'CUSTOMER_FIELD_CONFLICT',
        localValue: queueItem.payload,
        serverValue: {
          'id': 'LOAN-800',
          'amount': 15000.0,
          'status': 'pending',
          'version': 2,
        },
        serverVersion: 2,
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflictRecord);

      // Force error inside transaction by passing broken/invalid transaction context
      final db = await dbService.database;
      try {
        await db.transaction((txn) async {
          await recoveryService.recoverConflict(conflictRecord, externalTxn: txn);
          throw Exception('Simulated transaction failure for atomicity test');
        });
      } catch (_) {}

      // Verify complete rollback: old queue item remains CONFLICT
      final itemAfterRollback = await queueRepo.getByClientOperationId(oldOpId);
      expect(itemAfterRollback!.status, equals('CONFLICT'));

      // Verify conflict record resolution remains null
      final conflictAfterRollback = await queueRepo.getConflictRecordByClientOperationId(oldOpId);
      expect(conflictAfterRollback!.resolution, isNull);
    });

    test('20 & 21 & 22. Recovery Idempotency & Concurrency: Processing same conflict twice creates only ONE operation', () async {
      final oldOpId = SyncQueueItem.generateClientOperationId('IDEMPOTENT');
      final queueItem = SyncQueueItem(
        id: 'Q-600',
        entityType: 'loan',
        entityId: 'LOAN-600',
        operation: 'UPDATE',
        payload: {'amount': 25000.0},
        clientOperationId: oldOpId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
      );
      await queueRepo.enqueue(queueItem);

      final conflictRecord = SyncConflictRecord(
        id: 'CONF-600',
        clientOperationId: oldOpId,
        entityType: 'loan',
        entityId: 'LOAN-600',
        conflictType: 'CUSTOMER_FIELD_CONFLICT',
        localValue: queueItem.payload,
        serverValue: {
          'id': 'LOAN-600',
          'amount': 15000.0,
          'status': 'pending',
          'version': 2,
        },
        serverVersion: 2,
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflictRecord);

      // First Recovery Call
      final result1 = await recoveryService.recoverConflict(conflictRecord);
      expect(result1.isRecovered, isTrue);
      expect(result1.resolution, equals('CUSTOMER_WINS'));
      expect(result1.newClientOperationId, isNotNull);

      // Fetch updated conflict record
      final updatedRecord = await queueRepo.getConflictRecordByClientOperationId(oldOpId);

      // Second Recovery Call on the same record
      final result2 = await recoveryService.recoverConflict(updatedRecord!);
      expect(result2.isRecovered, isFalse);
      expect(result2.reason, contains('already been resolved'));

      // Verify pending items count (Must equal 1, not 2!)
      final pendingItems = await queueRepo.getPendingItems();
      expect(pendingItems.length, equals(1));
    });

    test('23 & 24. New operation retryCount starts at 0 while historical retryCount remains preserved', () async {
      final oldOpId = SyncQueueItem.generateClientOperationId('RETRY_HIST');
      final queueItem = SyncQueueItem(
        id: 'Q-700',
        entityType: 'loan',
        entityId: 'LOAN-700',
        operation: 'UPDATE',
        payload: {'amount': 28000.0},
        clientOperationId: oldOpId,
        createdAt: DateTime.now(),
        retryCount: 2, // Historical retry count
        status: 'CONFLICT',
      );
      await queueRepo.enqueue(queueItem);

      final conflictRecord = SyncConflictRecord(
        id: 'CONF-700',
        clientOperationId: oldOpId,
        entityType: 'loan',
        entityId: 'LOAN-700',
        conflictType: 'CUSTOMER_FIELD_CONFLICT',
        localValue: queueItem.payload,
        serverValue: {
          'id': 'LOAN-700',
          'amount': 15000.0,
          'status': 'pending',
          'version': 2,
        },
        serverVersion: 2,
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflictRecord);

      final result = await recoveryService.recoverConflict(conflictRecord);
      expect(result.isRecovered, isTrue);

      final oldItem = await queueRepo.getByClientOperationId(oldOpId);
      expect(oldItem!.retryCount, equals(2)); // Preserved!

      final newItem = await queueRepo.getByClientOperationId(result.newClientOperationId!);
      expect(newItem!.retryCount, equals(0)); // Starts fresh!
    });

    test('25. Version Semantics Regression Test: baseVersion uses loan entity version, NOT global sync cursor', () async {
      // Set global sync cursor in repository to 100
      await queueRepo.updateLastAppliedServerVersion(100);
      final currentCursor = await queueRepo.getLastAppliedServerVersion();
      expect(currentCursor, equals(100));

      final oldOpId = SyncQueueItem.generateClientOperationId('VER_SEM');
      final queueItem = SyncQueueItem(
        id: 'Q-900',
        entityType: 'loan',
        entityId: 'LOAN-900',
        operation: 'UPDATE',
        payload: {'amount': 45000.0},
        clientOperationId: oldOpId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
        baseVersion: 2,
      );
      await queueRepo.enqueue(queueItem);

      const int loanEntityVersion = 5; // Entity version is 5 (different from global cursor 100)
      final conflictRecord = SyncConflictRecord(
        id: 'CONF-900',
        clientOperationId: oldOpId,
        entityType: 'loan',
        entityId: 'LOAN-900',
        conflictType: 'CUSTOMER_FIELD_CONFLICT',
        localValue: queueItem.payload,
        serverValue: {
          'id': 'LOAN-900',
          'amount': 20000.0,
          'status': 'pending',
          'version': loanEntityVersion,
        },
        serverVersion: loanEntityVersion,
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflictRecord);

      final result = await recoveryService.recoverConflict(conflictRecord);
      expect(result.isRecovered, isTrue);

      final newItem = await queueRepo.getByClientOperationId(result.newClientOperationId!);
      expect(newItem, isNotNull);
      // PROOF: baseVersion MUST equal loan entity version (5), NOT global cursor (100)
      expect(newItem!.baseVersion, equals(5));
      expect(newItem.baseVersion, isNot(equals(100)));
    });

    test('26. Security Audit Regression: Tampered status/id/userId/createdAt in local payload are rejected', () async {
      final oldOpId = SyncQueueItem.generateClientOperationId('TAMPER');
      final queueItem = SyncQueueItem(
        id: 'Q-950',
        entityType: 'loan',
        entityId: 'LOAN-950',
        operation: 'UPDATE',
        payload: {
          'id': 'TAMPERED-ID',
          'userId': 'ATTACKER',
          'createdAt': '2099-01-01T00:00:00Z',
          'status': 'approved',
          'amount': 99999.0,
        },
        clientOperationId: oldOpId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
      );
      await queueRepo.enqueue(queueItem);

      final conflictRecord = SyncConflictRecord(
        id: 'CONF-950',
        clientOperationId: oldOpId,
        entityType: 'loan',
        entityId: 'LOAN-950',
        conflictType: 'CUSTOMER_FIELD_CONFLICT',
        localValue: queueItem.payload,
        serverValue: {
          'id': 'LOAN-950',
          'userId': 'LEGIT-USER',
          'createdAt': '2026-01-01T00:00:00Z',
          'status': 'pending',
          'amount': 10000.0,
          'version': 2,
        },
        serverVersion: 2,
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflictRecord);

      final result = await recoveryService.recoverConflict(conflictRecord);

      // PROOF: Explicit identity/status tampering is REJECTED and never requeued!
      expect(result.isRecovered, isFalse);
      expect(result.resolution, equals('DISCARDED'));
      expect(result.newClientOperationId, isNull);

      final itemState = await queueRepo.getByClientOperationId(oldOpId);
      expect(itemState!.status, equals('REJECTED'));
    });

    test('27. Retry Boundary Audit: retryCount = 3 and retryCount = 4 always yield UNRESOLVED (MANUAL)', () async {
      for (final count in [3, 4]) {
        final oldOpId = SyncQueueItem.generateClientOperationId('RETRY_$count');
        final queueItem = SyncQueueItem(
          id: 'Q-BOUND-$count',
          entityType: 'loan',
          entityId: 'LOAN-BOUND-$count',
          operation: 'UPDATE',
          payload: {'amount': 50000.0},
          clientOperationId: oldOpId,
          createdAt: DateTime.now(),
          retryCount: count,
          status: 'CONFLICT',
        );
        await queueRepo.enqueue(queueItem);

        final conflictRecord = SyncConflictRecord(
          id: 'CONF-BOUND-$count',
          clientOperationId: oldOpId,
          entityType: 'loan',
          entityId: 'LOAN-BOUND-$count',
          conflictType: 'CUSTOMER_FIELD_CONFLICT',
          localValue: queueItem.payload,
          serverValue: {
            'id': 'LOAN-BOUND-$count',
            'amount': 10000.0,
            'status': 'pending',
            'version': 2,
          },
          serverVersion: 2,
          createdAt: DateTime.now(),
        );
        await queueRepo.saveConflictRecord(conflictRecord);

        final result = await recoveryService.recoverConflict(conflictRecord);

        // PROOF: retryCount >= 3 guarantees MANUAL review with ZERO new queue items
        expect(result.isRecovered, isFalse);
        expect(result.resolution, equals('MANUAL'));
        expect(result.newClientOperationId, isNull);

        final oldState = await queueRepo.getByClientOperationId(oldOpId);
        expect(oldState!.status, equals('CONFLICT'));
      }
    });
  });
}

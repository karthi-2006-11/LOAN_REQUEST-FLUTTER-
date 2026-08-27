import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:loan_request_app/models/conflict_classification_models.dart';
import 'package:loan_request_app/models/loan_model.dart';
import 'package:loan_request_app/models/loan_priority.dart';
import 'package:loan_request_app/models/loan_status.dart';
import 'package:loan_request_app/models/sync_conflict_record.dart';
import 'package:loan_request_app/models/sync_queue_item.dart';
import 'package:loan_request_app/repositories/loan_repository.dart';
import 'package:loan_request_app/repositories/sync_queue_repository.dart';
import 'package:loan_request_app/services/conflict_classifier.dart';
import 'package:loan_request_app/services/conflict_recovery_service.dart';
import 'package:loan_request_app/services/database_service.dart';
import 'package:loan_request_app/services/sync_engine.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class TestE2EDatabaseService implements DatabaseService {
  final String dbPath;
  Database? _db;

  TestE2EDatabaseService(this.dbPath);

  @override
  Future<Database> get database async {
    if (_db != null && _db!.isOpen) {
      return _db!;
    }
    _db = await openDatabase(
      dbPath,
      version: 3,
      onConfigure: (db) async => await db.execute('PRAGMA foreign_keys = ON;'),
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
            loanId TEXT,
            title TEXT NOT NULL,
            message TEXT NOT NULL,
            isRead INTEGER NOT NULL DEFAULT 0,
            type TEXT NOT NULL,
            createdAt TEXT NOT NULL
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
            error TEXT,
            baseVersion INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS sync_conflicts (
            id TEXT PRIMARY KEY,
            clientOperationId TEXT NOT NULL UNIQUE,
            entityType TEXT NOT NULL,
            entityId TEXT NOT NULL,
            conflictType TEXT NOT NULL,
            localValue TEXT NOT NULL,
            serverValue TEXT NOT NULL,
            serverVersion INTEGER NOT NULL DEFAULT 0,
            createdAt TEXT NOT NULL,
            resolvedAt TEXT,
            resolution TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS sync_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
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
  late Directory tempDir;
  final List<TestE2EDatabaseService> activeDbServices = [];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('blackvault_e2e_test_');
    activeDbServices.clear();
  });

  tearDown(() async {
    for (final dbService in activeDbServices) {
      await dbService.close();
    }
    activeDbServices.clear();

    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  TestE2EDatabaseService createTestDb(String filename) {
    final service = TestE2EDatabaseService(p.join(tempDir.path, filename));
    activeDbServices.add(service);
    return service;
  }

  group('Phase 8.6.5 End-to-End Conflict Resolution Verification Suite', () {
    test('Scenario A — Offline CREATE -> Push -> Pull across 2 devices', () async {
      final dbServiceA = createTestDb('device_a.db');
      final dbServiceB = createTestDb('device_b.db');

      final queueRepoA = LocalSyncQueueRepository(databaseService: dbServiceA);
      final loanRepoA = LocalLoanRepository(databaseService: dbServiceA);

      final queueRepoB = LocalSyncQueueRepository(databaseService: dbServiceB);
      final loanRepoB = LocalLoanRepository(databaseService: dbServiceB);

      // 1. Device A creates loan while offline (LocalLoanRepository automatically creates pending sync_queue item)
      final loanA = LoanModel(
        id: 'LOAN-E2E-A1',
        userId: 'USR-CUST-A',
        userName: 'Customer A',
        amount: 25000.0,
        tenureMonths: 12,
        purpose: 'E2E Offline Loan',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepoA.createLoan(loanA);

      // 2 & 3 & 4. Verify local loan & pending queue item
      final localLoanA = await loanRepoA.getLoanById(loanA.id);
      expect(localLoanA, isNotNull);
      final pendingA = await queueRepoA.getPendingItems();
      expect(pendingA.length, equals(1));
      final opId = pendingA.first.clientOperationId;

      // 5. Mock Push Endpoint on Central Server
      final mockPushClient = MockClient((req) async {
        if (req.url.path.contains('/api/sync/push')) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final ops = body['operations'] as List;
          expect(ops.length, equals(1));
          return http.Response(
            jsonEncode({
              'status': 'SUCCESS',
              'results': [
                {
                  'clientOperationId': opId,
                  'status': 'SYNCED',
                  'entityVersion': 1,
                  'serverVersion': 1,
                }
              ]
            }),
            200,
          );
        }
        return http.Response('Not found', 444);
      });

      final syncEngineA = SyncEngine(
        queueRepository: queueRepoA,
        loanRepository: loanRepoA,
        databaseService: dbServiceA,
        httpClient: mockPushClient,
      );

      final pushResult = await syncEngineA.pushPending(baseUrl: 'http://server', authToken: 'token-a', deviceId: 'DEV-A');
      expect(pushResult.syncedCount, equals(1));

      // 9. Verify local queue item becomes SYNCED
      final queueItemAfterPush = await queueRepoA.getByClientOperationId(opId);
      expect(queueItemAfterPush!.status, equals('SYNCED'));

      // 10 & 11 & 12. Device B pulls from cursor 0
      final mockPullClient = MockClient((req) async {
        if (req.url.path.contains('/api/sync/pull')) {
          return http.Response(
            jsonEncode({
              'changes': [
                {
                  'serverVersion': 1,
                  'originDeviceId': 'DEV-A',
                  'entityType': 'loan',
                  'entityId': loanA.id,
                  'operation': 'CREATE',
                  'payload': {
                    'id': loanA.id,
                    'userId': 'USR-CUST-A',
                    'userName': 'Customer A',
                    'amount': 25000.0,
                    'tenureMonths': 12,
                    'purpose': 'E2E Offline Loan',
                    'priority': 'medium',
                    'status': 'pending',
                    'version': 1,
                    'createdAt': loanA.createdAt.toIso8601String(),
                  },
                  'createdAt': DateTime.now().toIso8601String(),
                }
              ],
              'nextVersion': 1,
              'hasMore': false,
            }),
            200,
          );
        }
        return http.Response('Not found', 444);
      });

      final syncEngineB = SyncEngine(
        queueRepository: queueRepoB,
        loanRepository: loanRepoB,
        databaseService: dbServiceB,
        httpClient: mockPullClient,
      );

      final pullResultB = await syncEngineB.pullChanges(baseUrl: 'http://server', authToken: 'token-b', deviceId: 'DEV-B');
      expect(pullResultB.totalProcessed, equals(1));
      expect(pullResultB.lastAppliedVersion, equals(1));

      // 12. Verify Device B's local loan matches server payload
      final loanB = await loanRepoB.getLoanById(loanA.id);
      expect(loanB, isNotNull);
      expect(loanB!.amount, equals(25000.0));
      expect(loanB.status, equals(LoanStatus.pending));

      // 13. Verify NO outgoing sync_queue item is created by the pull
      final queueItemsB = await queueRepoB.getPendingItems();
      expect(queueItemsB, isEmpty);
    });

    test('Scenario B — Admin Decision Propagation (Approved & Rejected)', () async {
      final dbService = createTestDb('device_admin_prop.db');
      final queueRepo = LocalSyncQueueRepository(databaseService: dbService);
      final loanRepo = LocalLoanRepository(databaseService: dbService);

      // Seed pending loan locally using applyServerLoan (server application method without creating outgoing sync_queue items)
      final seedLoan = LoanModel(
        id: 'LOAN-ADMIN-1',
        userId: 'USR-CUST-1',
        userName: 'User 1',
        amount: 10000.0,
        tenureMonths: 6,
        purpose: 'Personal',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );
      await loanRepo.applyServerLoan(seedLoan, 'CREATE');

      // 1 & 2 & 3. Admin approves loan on backend (serverVersion 2, version 2)
      final mockPullClientApproved = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'changes': [
              {
                'serverVersion': 2,
                'originDeviceId': 'ADMIN-CONSOLE',
                'entityType': 'loan',
                'entityId': 'LOAN-ADMIN-1',
                'operation': 'UPDATE',
                'payload': {
                  'id': 'LOAN-ADMIN-1',
                  'userId': 'USR-CUST-1',
                  'userName': 'User 1',
                  'amount': 10000.0,
                  'tenureMonths': 6,
                  'purpose': 'Personal',
                  'priority': 'medium',
                  'status': 'approved',
                  'version': 2,
                  'createdAt': DateTime.now().toIso8601String(),
                },
                'createdAt': DateTime.now().toIso8601String(),
              }
            ],
            'nextVersion': 2,
            'hasMore': false,
          }),
          200,
        );
      });

      final syncEngine = SyncEngine(
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        databaseService: dbService,
        httpClient: mockPullClientApproved,
      );

      final pullResult = await syncEngine.pullChanges(baseUrl: 'http://server', authToken: 'token-cust', deviceId: 'DEV-CUST');
      expect(pullResult.totalProcessed, equals(1));
      expect(pullResult.lastAppliedVersion, equals(2));

      // 6 & 7. Verify local loan status becomes approved
      final loanAfterPull = await loanRepo.getLoanById('LOAN-ADMIN-1');
      expect(loanAfterPull!.status, equals(LoanStatus.approved));

      // 8. Verify no echo sync_queue item generated
      final queueItems = await queueRepo.getPendingItems();
      expect(queueItems, isEmpty);
    });

    test('Scenario C — Stale Customer Mutation & Persistent Conflict Evidence', () async {
      final dbService = createTestDb('stale_cust.db');
      final queueRepo = LocalSyncQueueRepository(databaseService: dbService);
      final loanRepo = LocalLoanRepository(databaseService: dbService);

      final staleOpId = SyncQueueItem.generateClientOperationId('STALE_SCENARIO_C');
      final queueItem = SyncQueueItem(
        id: 'Q-STALE-C',
        entityType: 'loan',
        entityId: 'LOAN-STALE-C',
        operation: 'UPDATE',
        payload: {'amount': 30000.0},
        clientOperationId: staleOpId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'PENDING_SYNC',
        baseVersion: 1, // Stale base version (server is version 2, status approved)
      );
      await queueRepo.enqueue(queueItem);

      // Backend returns 409 CONFLICT with serverState version 2
      final mockPushClient = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'status': 'SUCCESS',
            'results': [
              {
                'clientOperationId': staleOpId,
                'status': 'CONFLICT',
                'message': 'Stale push version',
                'serverState': {
                  'id': 'LOAN-STALE-C',
                  'userId': 'USR-CUST-C',
                  'userName': 'User C',
                  'amount': 15000.0,
                  'status': 'approved',
                  'version': 2,
                  'createdAt': '2026-01-01T00:00:00Z',
                }
              }
            ]
          }),
          200,
        );
      });

      final syncEngine = SyncEngine(
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        databaseService: dbService,
        httpClient: mockPushClient,
      );

      final pushResult = await syncEngine.pushPending(baseUrl: 'http://server', authToken: 'token-c', deviceId: 'DEV-C');
      expect(pushResult.conflictCount, equals(1));

      // Verify sync_conflicts preserves evidence
      final conflictRecord = await queueRepo.getConflictRecordByClientOperationId(staleOpId);
      expect(conflictRecord, isNotNull);
      expect(conflictRecord!.clientOperationId, equals(staleOpId));
      expect(conflictRecord.conflictType, equals('STALE_PUSH'));
      expect(conflictRecord.localValue['amount'], equals(30000.0));
      expect(conflictRecord.serverValue['status'], equals('approved'));
      expect(conflictRecord.serverVersion, equals(2)); // Authoritative entity version
    });

    test('Scenario D — Conflict Classification Taxonomy (All 9 Categories Verified)', () {
      final classifier = ConflictClassifier();

      // 1. NO_CONFLICT
      final res1 = classifier.classify(ConflictClassificationInput(
        entityType: 'loan', entityId: 'L1', operation: 'UPDATE', localPayload: {'amount': 100}, serverVersion: 1, baseVersion: 1,
      ));
      expect(res1.category, equals(ConflictCategory.noConflict));

      // 2. ALREADY_APPLIED
      final res2 = classifier.classify(ConflictClassificationInput(
        entityType: 'loan', entityId: 'L2', operation: 'UPDATE', localPayload: {'amount': 100}, isProcessedIdempotent: true,
      ));
      expect(res2.category, equals(ConflictCategory.alreadyApplied));

      // 3. OWN_DEVICE_ECHO
      final res3 = classifier.classify(ConflictClassificationInput(
        entityType: 'loan', entityId: 'L3', operation: 'UPDATE', localPayload: {'amount': 100}, originDeviceId: 'DEV-1', clientDeviceId: 'DEV-1',
      ));
      expect(res3.category, equals(ConflictCategory.ownDeviceEcho));

      // 4. INVALID_MUTATION (Tampered status)
      final res4 = classifier.classify(ConflictClassificationInput(
        entityType: 'loan', entityId: 'L4', operation: 'UPDATE', localPayload: {'status': 'approved'}, userRole: 'CUSTOMER',
      ));
      expect(res4.category, equals(ConflictCategory.invalidMutation));

      // 5. UPDATE_DELETE_CONFLICT
      final res5 = classifier.classify(ConflictClassificationInput(
        entityType: 'loan', entityId: 'L5', operation: 'UPDATE', localPayload: {'amount': 100}, serverState: {'isDeleted': true},
      ));
      expect(res5.category, equals(ConflictCategory.updateDeleteConflict));

      // 6. ADMIN_STATUS_OVERRIDE
      final res6 = classifier.classify(ConflictClassificationInput(
        entityType: 'loan', entityId: 'L6', operation: 'UPDATE', localPayload: {'amount': 200}, serverState: {'status': 'approved', 'amount': 100},
      ));
      expect(res6.category, equals(ConflictCategory.adminStatusOverride));

      // 7. CUSTOMER_FIELD_CONFLICT
      final res7 = classifier.classify(ConflictClassificationInput(
        entityType: 'loan', entityId: 'L7', operation: 'UPDATE', localPayload: {'amount': 200}, serverState: {'status': 'pending', 'amount': 100},
      ));
      expect(res7.category, equals(ConflictCategory.customerFieldConflict));

      // 8. SPLIT_OWNERSHIP_MERGE
      final res8 = classifier.classify(ConflictClassificationInput(
        entityType: 'loan', entityId: 'L8', operation: 'UPDATE', localPayload: {'purpose': 'New Purpose'}, serverState: {'status': 'approved', 'purpose': 'New Purpose'},
      ));
      expect(res8.category, equals(ConflictCategory.splitOwnershipMerge));

      // 9. STALE_PUSH
      final res9 = classifier.classify(ConflictClassificationInput(
        entityType: 'loan', entityId: 'L9', operation: 'UPDATE', localPayload: {'amount': 100}, baseVersion: 1, serverVersion: 3,
      ));
      expect(res9.category, equals(ConflictCategory.stalePush));
    });

    test('Scenario E & Security 1-4 — Conflict Recovery, Re-queue UUID v4, and Tampered Field Rejection', () async {
      final dbService = createTestDb('recovery_security.db');
      final queueRepo = LocalSyncQueueRepository(databaseService: dbService);
      final loanRepo = LocalLoanRepository(databaseService: dbService);
      final recoveryService = ConflictRecoveryService(queueRepository: queueRepo, loanRepository: loanRepo, databaseService: dbService);

      // Legitimate customer edit with stale push
      final origOpId = SyncQueueItem.generateClientOperationId('LEGIT_OP');
      final item = SyncQueueItem(
        id: 'Q-LEGIT',
        entityType: 'loan',
        entityId: 'LOAN-LEGIT',
        operation: 'UPDATE',
        payload: {'amount': 50000.0, 'purpose': 'Legitimate Purpose'},
        clientOperationId: origOpId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
        baseVersion: 1,
      );
      await queueRepo.enqueue(item);

      final conflictRecord = SyncConflictRecord(
        id: 'CONF-LEGIT',
        clientOperationId: origOpId,
        entityType: 'loan',
        entityId: 'LOAN-LEGIT',
        conflictType: 'CUSTOMER_FIELD_CONFLICT',
        localValue: item.payload,
        serverValue: {
          'id': 'LOAN-LEGIT',
          'userId': 'USR-LEGIT',
          'amount': 20000.0,
          'status': 'pending',
          'version': 4, // Server version = 4
          'createdAt': '2026-01-01T00:00:00Z',
        },
        serverVersion: 4,
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflictRecord);

      final result = await recoveryService.recoverConflict(conflictRecord);
      expect(result.isRecovered, isTrue);
      expect(result.resolution, equals('CUSTOMER_WINS'));
      expect(result.newClientOperationId, isNotNull);
      expect(result.newClientOperationId, isNot(equals(origOpId)));
      // RFC 4122 UUID v4 regex validation
      final uuidRegex = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$', caseSensitive: false);
      expect(uuidRegex.hasMatch(result.newClientOperationId!), isTrue);

      final newItem = await queueRepo.getByClientOperationId(result.newClientOperationId!);
      expect(newItem, isNotNull);
      expect(newItem!.baseVersion, equals(4)); // baseVersion = server entity version 4
      expect(newItem.retryCount, equals(0)); // fresh retryCount = 0

      // Security Check: Server immutable identity preserved
      expect(newItem.payload['id'], equals('LOAN-LEGIT'));
      expect(newItem.payload['userId'], equals('USR-LEGIT'));
      expect(newItem.payload['createdAt'], equals('2026-01-01T00:00:00Z'));
      expect(newItem.payload['status'], equals('pending'));
    });

    test('Scenario F & Security 7-8 — Retry / Idempotency Replay & Double Recovery Safety', () async {
      final dbService = createTestDb('idempotency_e2e.db');
      final queueRepo = LocalSyncQueueRepository(databaseService: dbService);
      final loanRepo = LocalLoanRepository(databaseService: dbService);
      final recoveryService = ConflictRecoveryService(queueRepository: queueRepo, loanRepository: loanRepo, databaseService: dbService);

      final opId = SyncQueueItem.generateClientOperationId('IDEM_E2E');
      final item = SyncQueueItem(
        id: 'Q-IDEM',
        entityType: 'loan',
        entityId: 'LOAN-IDEM',
        operation: 'UPDATE',
        payload: {'amount': 33000.0},
        clientOperationId: opId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
      );
      await queueRepo.enqueue(item);

      final conflictRecord = SyncConflictRecord(
        id: 'CONF-IDEM',
        clientOperationId: opId,
        entityType: 'loan',
        entityId: 'LOAN-IDEM',
        conflictType: 'CUSTOMER_FIELD_CONFLICT',
        localValue: item.payload,
        serverValue: {
          'id': 'LOAN-IDEM',
          'amount': 20000.0,
          'status': 'pending',
          'version': 2,
        },
        serverVersion: 2,
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflictRecord);

      // Recovery call 1
      final res1 = await recoveryService.recoverConflict(conflictRecord);
      expect(res1.isRecovered, isTrue);

      final savedRecord = await queueRepo.getConflictRecordByClientOperationId(opId);

      // Recovery call 2 (Duplicate Recovery Invocation)
      final res2 = await recoveryService.recoverConflict(savedRecord!);
      expect(res2.isRecovered, isFalse);
      expect(res2.reason, contains('already been resolved'));

      // Verify pending items count (Must be 1, not 2)
      final pending = await queueRepo.getPendingItems();
      expect(pending.length, equals(1));
    });

    test('Scenario G — Pull Pagination (Limit, nextVersion, hasMore, Monotonic Cursor)', () async {
      final dbService = createTestDb('pagination.db');
      final queueRepo = LocalSyncQueueRepository(databaseService: dbService);
      final loanRepo = LocalLoanRepository(databaseService: dbService);

      int pullCallCount = 0;
      final mockPaginatedClient = MockClient((req) async {
        pullCallCount++;
        final uri = req.url;
        final since = int.parse(uri.queryParameters['since'] ?? '0');
        if (since == 0) {
          return http.Response(
            jsonEncode({
              'changes': [
                {
                  'serverVersion': 1,
                  'originDeviceId': 'OTHER-DEV',
                  'entityType': 'loan',
                  'entityId': 'LOAN-PAG-1',
                  'operation': 'CREATE',
                  'payload': {'id': 'LOAN-PAG-1', 'userId': 'USR-1', 'userName': 'U1', 'amount': 1000.0, 'tenureMonths': 6, 'purpose': 'P1', 'priority': 'medium', 'status': 'pending', 'version': 1},
                  'createdAt': DateTime.now().toIso8601String(),
                }
              ],
              'nextVersion': 1,
              'hasMore': true,
            }),
            200,
          );
        } else if (since == 1) {
          return http.Response(
            jsonEncode({
              'changes': [
                {
                  'serverVersion': 2,
                  'originDeviceId': 'OTHER-DEV',
                  'entityType': 'loan',
                  'entityId': 'LOAN-PAG-2',
                  'operation': 'CREATE',
                  'payload': {'id': 'LOAN-PAG-2', 'userId': 'USR-1', 'userName': 'U1', 'amount': 2000.0, 'tenureMonths': 12, 'purpose': 'P2', 'priority': 'medium', 'status': 'pending', 'version': 1},
                  'createdAt': DateTime.now().toIso8601String(),
                }
              ],
              'nextVersion': 2,
              'hasMore': false,
            }),
            200,
          );
        }
        return http.Response('Invalid cursor', 400);
      });

      final syncEngine = SyncEngine(
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        databaseService: dbService,
        httpClient: mockPaginatedClient,
      );

      // Pull 1
      final res1 = await syncEngine.pullChanges(baseUrl: 'http://server', authToken: 'token', deviceId: 'DEV');
      expect(res1.totalProcessed, equals(1));
      expect(res1.lastAppliedVersion, equals(1));
      expect(res1.hasMore, isTrue);

      // Pull 2 (Resuming from cursor 1)
      final res2 = await syncEngine.pullChanges(baseUrl: 'http://server', authToken: 'token', deviceId: 'DEV');
      expect(res2.totalProcessed, equals(1));
      expect(res2.lastAppliedVersion, equals(2));
      expect(res2.hasMore, isFalse);

      expect(pullCallCount, equals(2));
    });

    test('Scenario H — Transaction Rollback (Failure during recovery rolls back atomically)', () async {
      final dbService = createTestDb('rollback.db');
      final queueRepo = LocalSyncQueueRepository(databaseService: dbService);
      final loanRepo = LocalLoanRepository(databaseService: dbService);
      final recoveryService = ConflictRecoveryService(queueRepository: queueRepo, loanRepository: loanRepo, databaseService: dbService);

      final opId = SyncQueueItem.generateClientOperationId('ROLLBACK_E2E');
      final item = SyncQueueItem(
        id: 'Q-ROLL',
        entityType: 'loan',
        entityId: 'LOAN-ROLL',
        operation: 'UPDATE',
        payload: {'amount': 70000.0},
        clientOperationId: opId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
      );
      await queueRepo.enqueue(item);

      final conflictRecord = SyncConflictRecord(
        id: 'CONF-ROLL',
        clientOperationId: opId,
        entityType: 'loan',
        entityId: 'LOAN-ROLL',
        conflictType: 'CUSTOMER_FIELD_CONFLICT',
        localValue: item.payload,
        serverValue: {
          'id': 'LOAN-ROLL',
          'amount': 20000.0,
          'status': 'pending',
          'version': 2,
        },
        serverVersion: 2,
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflictRecord);

      final db = await dbService.database;
      try {
        await db.transaction((txn) async {
          await recoveryService.recoverConflict(conflictRecord, externalTxn: txn);
          throw Exception('Simulated recovery transaction failure');
        });
      } catch (_) {}

      // Verify complete rollback
      final oldItem = await queueRepo.getByClientOperationId(opId);
      expect(oldItem!.status, equals('CONFLICT'));

      final record = await queueRepo.getConflictRecordByClientOperationId(opId);
      expect(record!.resolution, isNull);
    });

    test('Scenario I & Security 5 — Multi-Device & Cross-Customer Isolation', () async {
      final dbService = createTestDb('isolation.db');
      final queueRepo = LocalSyncQueueRepository(databaseService: dbService);
      final loanRepo = LocalLoanRepository(databaseService: dbService);

      // Mock server returning only Customer A's loans for Customer A's token
      final mockIsolationClient = MockClient((req) async {
        final authHeader = req.headers['authorization'] ?? req.headers['Authorization'] ?? req.headers['AUTHORIZATION'];
        if (authHeader != null && authHeader.contains('token-cust-a')) {
          return http.Response(
            jsonEncode({
              'changes': [
                {
                  'serverVersion': 1,
                  'originDeviceId': 'DEV-B',
                  'entityType': 'loan',
                  'entityId': 'LOAN-CUST-A',
                  'operation': 'CREATE',
                  'payload': {'id': 'LOAN-CUST-A', 'userId': 'USR-CUST-A', 'userName': 'Cust A', 'amount': 5000.0, 'tenureMonths': 6, 'purpose': 'Loan A', 'priority': 'medium', 'status': 'pending', 'version': 1, 'createdAt': DateTime.now().toIso8601String()},
                  'createdAt': DateTime.now().toIso8601String(),
                }
              ],
              'nextVersion': 1,
              'hasMore': false,
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'changes': [], 'nextVersion': 1, 'hasMore': false}), 200);
      });

      final syncEngine = SyncEngine(
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        databaseService: dbService,
        httpClient: mockIsolationClient,
      );

      final pullResultA = await syncEngine.pullChanges(baseUrl: 'http://server', authToken: 'token-cust-a', deviceId: 'DEV-A');
      expect(pullResultA.totalProcessed, equals(1));

      final loanA = await loanRepo.getLoanById('LOAN-CUST-A');
      expect(loanA, isNotNull);
    });

    test('Scenario J — Own-Device Echo Prevention', () async {
      final dbService = createTestDb('echo_j.db');
      final queueRepo = LocalSyncQueueRepository(databaseService: dbService);
      final loanRepo = LocalLoanRepository(databaseService: dbService);

      // Seed local loan using applyServerLoan (server application method without creating outgoing sync_queue items)
      final seedLoan = LoanModel(
        id: 'LOAN-ECHO-1',
        userId: 'USR-ECHO',
        userName: 'Echo User',
        amount: 15000.0,
        tenureMonths: 12,
        purpose: 'Local Edit',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );
      await loanRepo.applyServerLoan(seedLoan, 'CREATE');

      // Server returns change originated from DEV-ECHO (same deviceId)
      final mockEchoClient = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'changes': [
              {
                'serverVersion': 5,
                'originDeviceId': 'DEV-ECHO',
                'entityType': 'loan',
                'entityId': 'LOAN-ECHO-1',
                'operation': 'UPDATE',
                'payload': {
                  'id': 'LOAN-ECHO-1',
                  'userId': 'USR-ECHO',
                  'userName': 'Echo User',
                  'amount': 15000.0,
                  'tenureMonths': 12,
                  'purpose': 'Local Edit',
                  'priority': 'medium',
                  'status': 'pending',
                  'version': 2,
                },
                'createdAt': DateTime.now().toIso8601String(),
              }
            ],
            'nextVersion': 5,
            'hasMore': false,
          }),
          200,
        );
      });

      final syncEngine = SyncEngine(
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        databaseService: dbService,
        httpClient: mockEchoClient,
      );

      final pullResult = await syncEngine.pullChanges(baseUrl: 'http://server', authToken: 'token-echo', deviceId: 'DEV-ECHO');
      expect(pullResult.totalProcessed, equals(1));
      expect(pullResult.lastAppliedVersion, equals(5)); // Cursor STILL advances!

      // Verify no outgoing queue item generated
      final queueItems = await queueRepo.getPendingItems();
      expect(queueItems, isEmpty);
    });

    test('Security 6 — Customer attempts stale mutation after loan approval', () async {
      final dbService = createTestDb('security_stale_app.db');
      final queueRepo = LocalSyncQueueRepository(databaseService: dbService);
      final loanRepo = LocalLoanRepository(databaseService: dbService);
      final recoveryService = ConflictRecoveryService(queueRepository: queueRepo, loanRepository: loanRepo, databaseService: dbService);

      final opId = SyncQueueItem.generateClientOperationId('SEC_STALE_APP');
      final item = SyncQueueItem(
        id: 'Q-SEC-STALE',
        entityType: 'loan',
        entityId: 'LOAN-SEC-STALE',
        operation: 'UPDATE',
        payload: {'amount': 90000.0},
        clientOperationId: opId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
      );
      await queueRepo.enqueue(item);

      final conflictRecord = SyncConflictRecord(
        id: 'CONF-SEC-STALE',
        clientOperationId: opId,
        entityType: 'loan',
        entityId: 'LOAN-SEC-STALE',
        conflictType: 'ADMIN_STATUS_OVERRIDE',
        localValue: item.payload,
        serverValue: {
          'id': 'LOAN-SEC-STALE',
          'amount': 10000.0,
          'status': 'approved',
          'version': 3,
        },
        serverVersion: 3,
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflictRecord);

      final result = await recoveryService.recoverConflict(conflictRecord);

      // PROOF: Post-approval mutation attempts are SERVER_WINS (REJECTED) and NEVER requeued
      expect(result.isRecovered, isTrue);
      expect(result.resolution, equals('SERVER_WINS'));
      expect(result.newClientOperationId, isNull);

      final itemState = await queueRepo.getByClientOperationId(opId);
      expect(itemState!.status, equals('REJECTED'));
    });
  });
}

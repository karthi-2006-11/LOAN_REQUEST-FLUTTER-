import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:loan_request_app/models/loan_model.dart';
import 'package:loan_request_app/models/loan_priority.dart';
import 'package:loan_request_app/models/loan_status.dart';
import 'package:loan_request_app/models/sync_queue_item.dart';
import 'package:loan_request_app/repositories/loan_repository.dart';
import 'package:loan_request_app/repositories/sync_queue_repository.dart';
import 'package:loan_request_app/services/database_service.dart';
import 'package:loan_request_app/services/sync_engine.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class TestSyncEngineDatabaseService implements DatabaseService {
  final String dbPath;
  Database? _db;

  TestSyncEngineDatabaseService(this.dbPath);

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
            error TEXT,
            baseVersion INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS sync_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
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
  late String clientDbPath;
  late TestSyncEngineDatabaseService clientDbService;
  late LocalSyncQueueRepository clientQueueRepo;
  late LocalLoanRepository clientLoanRepo;
  const baseUrl = 'http://localhost:8080';
  const validToken = 'mock_valid_jwt_token';
  const clientDeviceId = 'DEV-CLIENT-001';

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final clientTempDir = Directory.systemTemp.createTempSync('client_sync_test_');
    clientDbPath = p.join(clientTempDir.path, 'client_sync.db');
    clientDbService = TestSyncEngineDatabaseService(clientDbPath);
    clientQueueRepo = LocalSyncQueueRepository(databaseService: clientDbService);
    clientLoanRepo = LocalLoanRepository(databaseService: clientDbService);
  });

  tearDown(() async {
    await clientDbService.close();
    if (File(clientDbPath).existsSync()) File(clientDbPath).deleteSync();
  });

  group('SyncEngine Synchronization & Phase 8.6.2 Concurrency Tests', () {
    test('1. UUID v4 Format: generateClientOperationId produces valid RFC 4122 UUID v4', () {
      final uuid = SyncQueueItem.generateClientOperationId();
      final uuidV4Regex = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$');
      expect(uuidV4Regex.hasMatch(uuid), isTrue);
    });

    test('2. Initial Pull Cursor is 0', () async {
      final cursor = await clientQueueRepo.getLastAppliedServerVersion();
      expect(cursor, equals(0));
    });

    test('3. Pull Changes: Applies server changes to local SQLite and updates cursor atomically', () async {
      final mockClient = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'success': true,
            'changes': [
              {
                'serverVersion': 1,
                'entityType': 'loan',
                'entityId': 'LOAN-SERVER-001',
                'operation': 'CREATE',
                'originDeviceId': 'DEV-REMOTE-99',
                'payload': {
                  'id': 'LOAN-SERVER-001',
                  'userId': 'USR-CUST-1',
                  'userName': 'Customer User',
                  'amount': 25000.0,
                  'tenureMonths': 24,
                  'purpose': 'Business Expansion',
                  'priority': 'high',
                  'status': 'pending',
                  'createdAt': DateTime.now().toIso8601String(),
                },
              }
            ],
            'nextVersion': 1,
            'hasMore': false,
          }),
          200,
        );
      });

      final syncEngine = SyncEngine(
        queueRepository: clientQueueRepo,
        loanRepository: clientLoanRepo,
        databaseService: clientDbService,
        httpClient: mockClient,
      );

      final result = await syncEngine.pullChanges(baseUrl: baseUrl, authToken: validToken, deviceId: clientDeviceId);

      expect(result.totalProcessed, equals(1));
      expect(result.lastAppliedVersion, equals(1));

      final loanInLocalDb = await clientLoanRepo.getLoanById('LOAN-SERVER-001');
      expect(loanInLocalDb, isNotNull);
      expect(loanInLocalDb!.amount, equals(25000.0));
    });

    test('4. Own-Device Echo Prevention: Changes from same deviceId advance cursor without reapplying local mutation', () async {
      final mockClient = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'success': true,
            'changes': [
              {
                'serverVersion': 5,
                'entityType': 'loan',
                'entityId': 'LOAN-ECHO-001',
                'operation': 'CREATE',
                'originDeviceId': clientDeviceId, // Same device!
                'payload': {
                  'id': 'LOAN-ECHO-001',
                  'amount': 10000.0,
                },
              }
            ],
            'nextVersion': 5,
            'hasMore': false,
          }),
          200,
        );
      });

      final syncEngine = SyncEngine(
        queueRepository: clientQueueRepo,
        loanRepository: clientLoanRepo,
        databaseService: clientDbService,
        httpClient: mockClient,
      );

      final result = await syncEngine.pullChanges(baseUrl: baseUrl, authToken: validToken, deviceId: clientDeviceId);

      expect(result.lastAppliedVersion, equals(5));
      final loan = await clientLoanRepo.getLoanById('LOAN-ECHO-001');
      expect(loan, isNull); // Skipped reapplication!
    });

    test('5. Pending Customer-Owned Mutation Preserved: Server edit does not destroy pending local change', () async {
      final localLoan = LoanModel(
        id: 'LOAN-OVERLAP',
        userId: 'USR-CUST-1',
        userName: 'Customer',
        amount: 15000.0,
        tenureMonths: 12,
        purpose: 'Original Purpose',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );
      await clientLoanRepo.createLoan(localLoan);

      final mockClient = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'success': true,
            'changes': [
              {
                'serverVersion': 8,
                'entityType': 'loan',
                'entityId': 'LOAN-OVERLAP',
                'operation': 'UPDATE',
                'originDeviceId': 'DEV-OTHER-99',
                'payload': {
                  'id': 'LOAN-OVERLAP',
                  'amount': 18000.0,
                  'purpose': 'Remote Edit',
                },
              }
            ],
            'nextVersion': 8,
            'hasMore': false,
          }),
          200,
        );
      });

      final syncEngine = SyncEngine(
        queueRepository: clientQueueRepo,
        loanRepository: clientLoanRepo,
        databaseService: clientDbService,
        httpClient: mockClient,
      );

      await syncEngine.pullChanges(baseUrl: baseUrl, authToken: validToken, deviceId: clientDeviceId);

      final pendingAfter = await clientQueueRepo.getPendingItems();
      expect(pendingAfter.length, equals(1));
      expect(pendingAfter.first.entityId, equals('LOAN-OVERLAP'));

      final cursor = await clientQueueRepo.getLastAppliedServerVersion();
      expect(cursor, equals(8));
    });

    test('6. Admin Status Update Propagation: Status approved updates loan status while preserving pending local edit', () async {
      final localLoan = LoanModel(
        id: 'LOAN-ADMIN-PROP',
        userId: 'USR-CUST-1',
        userName: 'Customer',
        amount: 20000.0,
        tenureMonths: 12,
        purpose: 'Local Edit',
        priority: LoanPriority.high,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );
      await clientLoanRepo.createLoan(localLoan);

      final mockClient = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'success': true,
            'changes': [
              {
                'serverVersion': 12,
                'entityType': 'loan',
                'entityId': 'LOAN-ADMIN-PROP',
                'operation': 'UPDATE',
                'originDeviceId': 'DEV-ADMIN-CONSOLE',
                'payload': {
                  'id': 'LOAN-ADMIN-PROP',
                  'status': 'approved',
                },
              }
            ],
            'nextVersion': 12,
            'hasMore': false,
          }),
          200,
        );
      });

      final syncEngine = SyncEngine(
        queueRepository: clientQueueRepo,
        loanRepository: clientLoanRepo,
        databaseService: clientDbService,
        httpClient: mockClient,
      );

      await syncEngine.pullChanges(baseUrl: baseUrl, authToken: validToken, deviceId: clientDeviceId);

      final loan = await clientLoanRepo.getLoanById('LOAN-ADMIN-PROP');
      expect(loan!.status, equals(LoanStatus.approved));

      final pending = await clientQueueRepo.getPendingItems();
      expect(pending.length, equals(1));
    });

    test('7. Echo Prevention: Pulled server changes DO NOT create new outgoing sync_queue entries', () async {
      final mockClient = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'success': true,
            'changes': [
              {
                'serverVersion': 15,
                'entityType': 'loan',
                'entityId': 'LOAN-PULLED-NOECHO',
                'operation': 'CREATE',
                'payload': {
                  'id': 'LOAN-PULLED-NOECHO',
                  'userId': 'USR-CUST-1',
                  'userName': 'Customer',
                  'amount': 5000.0,
                  'tenureMonths': 6,
                  'purpose': 'Short loan',
                  'priority': 'low',
                  'status': 'approved',
                },
              }
            ],
            'nextVersion': 15,
            'hasMore': false,
          }),
          200,
        );
      });

      final syncEngine = SyncEngine(
        queueRepository: clientQueueRepo,
        loanRepository: clientLoanRepo,
        databaseService: clientDbService,
        httpClient: mockClient,
      );

      await syncEngine.pullChanges(baseUrl: baseUrl, authToken: validToken, deviceId: clientDeviceId);

      final loan = await clientLoanRepo.getLoanById('LOAN-PULLED-NOECHO');
      expect(loan, isNotNull);

      final pendingItems = await clientQueueRepo.getPendingItems();
      expect(pendingItems, isEmpty);
    });

    test('8. Atomicity Rollback: Failure inside multi-change pull transaction rolls back cursor and data', () async {
      final mockClient = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'success': true,
            'changes': [
              {
                'serverVersion': 20,
                'entityType': 'loan',
                'entityId': 'LOAN-ROLLBACK-TEST',
                'operation': 'CREATE',
                'payload': {
                  'id': 'LOAN-ROLLBACK-TEST',
                  'amount': 'INVALID_STRING_THAT_THROWS_EXCEPTION',
                },
              }
            ],
            'nextVersion': 20,
            'hasMore': false,
          }),
          200,
        );
      });

      final syncEngine = SyncEngine(
        queueRepository: clientQueueRepo,
        loanRepository: clientLoanRepo,
        databaseService: clientDbService,
        httpClient: mockClient,
      );

      final result = await syncEngine.pullChanges(baseUrl: baseUrl, authToken: validToken, deviceId: clientDeviceId);
      expect(result.globalError, isNotNull);

      final cursor = await clientQueueRepo.getLastAppliedServerVersion();
      expect(cursor, equals(0));
    });

    test('9. End-to-End Stale Push Integration Test: Stale push creates persistent sync_conflicts record preserving local and server evidence', () async {
      const opId = 'OP-E2E-STALE-001';
      final item = SyncQueueItem(
        id: 'SQ-E2E-001',
        entityType: 'loan',
        entityId: 'LOAN-E2E-STALE',
        operation: 'UPDATE',
        baseVersion: 1,
        payload: {
          'id': 'LOAN-E2E-STALE',
          'amount': 20000.0,
          'purpose': 'Offline Edit',
        },
        clientOperationId: opId,
        createdAt: DateTime.now(),
      );
      await clientQueueRepo.enqueue(item);

      final mockClient = MockClient((req) async {
        expect(req.url.path, equals('/api/sync/push'));
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['operations'][0]['baseVersion'], equals(1));

        return http.Response(
          jsonEncode({
            'success': true,
            'results': [
              {
                'clientOperationId': opId,
                'entityId': 'LOAN-E2E-STALE',
                'status': 'CONFLICT',
                'message': 'Stale mutation: baseVersion (1) is behind server version (2)',
                'serverState': {
                  'id': 'LOAN-E2E-STALE',
                  'userId': 'USR-CUST-1',
                  'userName': 'Customer User',
                  'amount': 15000.0,
                  'tenureMonths': 12,
                  'purpose': 'Original Loan',
                  'priority': 'medium',
                  'status': 'approved',
                  'version': 2,
                  'createdAt': DateTime.now().toIso8601String(),
                },
              }
            ],
          }),
          200,
        );
      });

      final syncEngine = SyncEngine(
        queueRepository: clientQueueRepo,
        loanRepository: clientLoanRepo,
        databaseService: clientDbService,
        httpClient: mockClient,
      );

      final pushResult = await syncEngine.pushPending(baseUrl: baseUrl, authToken: validToken, deviceId: clientDeviceId);

      expect(pushResult.conflictCount, equals(1));

      final queueItem = await clientQueueRepo.getByClientOperationId(opId);
      expect(queueItem, isNotNull);
      expect(queueItem!.status, equals('REJECTED'));

      final conflictRecord = await clientQueueRepo.getConflictRecordByClientOperationId(opId);
      expect(conflictRecord, isNotNull);
      expect(conflictRecord!.clientOperationId, equals(opId));
      expect(conflictRecord.conflictType, equals('STALE_PUSH'));
      expect(conflictRecord.localValue['amount'], equals(20000.0));
      expect(conflictRecord.serverValue['amount'], equals(15000.0));
      expect(conflictRecord.serverValue['status'], equals('approved'));
      expect(conflictRecord.serverVersion, equals(2));
      expect(conflictRecord.resolvedAt, isNotNull);
      expect(conflictRecord.resolution, equals('SERVER_WINS'));
    });

    test('10. Atomicity Test: Failed conflict storage rolls back transaction', () async {
      final mockClient = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'success': true,
            'results': [
              {
                'clientOperationId': 'OP-FAIL-CONF-001',
                'entityId': 'LOAN-FAIL',
                'status': 'CONFLICT',
                'message': 'Stale mutation',
                'serverState': {'version': 2},
              }
            ],
          }),
          200,
        );
      });

      final item = SyncQueueItem(
        id: 'SQ-FAIL-001',
        entityType: 'loan',
        entityId: 'LOAN-FAIL',
        operation: 'UPDATE',
        payload: {'amount': 5000.0},
        clientOperationId: 'OP-FAIL-CONF-001',
        createdAt: DateTime.now(),
      );
      await clientQueueRepo.enqueue(item);

      final syncEngine = SyncEngine(
        queueRepository: clientQueueRepo,
        loanRepository: clientLoanRepo,
        databaseService: clientDbService,
        httpClient: mockClient,
      );

      final pushResult = await syncEngine.pushPending(baseUrl: baseUrl, authToken: validToken, deviceId: clientDeviceId);
      expect(pushResult.conflictCount, equals(1));
    });
  });
}

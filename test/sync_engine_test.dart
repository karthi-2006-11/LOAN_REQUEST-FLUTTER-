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
      version: 2,
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
            error TEXT
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

  group('SyncEngine Synchronization & Surgical Review Tests', () {
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
        expect(req.url.path, equals('/api/sync/pull'));
        expect(req.url.queryParameters['since'], equals('0'));

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

      final updatedCursor = await clientQueueRepo.getLastAppliedServerVersion();
      expect(updatedCursor, equals(1));

      final pendingQueue = await clientQueueRepo.getPendingItems();
      expect(pendingQueue, isEmpty);
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
                'entityId': 'LOAN-OWN-ECHO',
                'operation': 'CREATE',
                'originDeviceId': clientDeviceId, // Same deviceId as client
                'payload': {
                  'id': 'LOAN-OWN-ECHO',
                  'amount': 99999.0,
                  'status': 'pending',
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

      // Verify change was skipped from local business table
      final loan = await clientLoanRepo.getLoanById('LOAN-OWN-ECHO');
      expect(loan, isNull);

      // Verify sync_queue remains empty
      final pendingItems = await clientQueueRepo.getPendingItems();
      expect(pendingItems, isEmpty);
    });

    test('5. Pending Customer-Owned Mutation Preserved: Server edit does not destroy pending local change', () async {
      // 1. Enqueue local offline mutation for LOAN-OVERLAP (customer edited amount to 20000)
      final localLoan = LoanModel(
        id: 'LOAN-OVERLAP',
        userId: 'USR-CUST-1',
        userName: 'Customer',
        amount: 20000.0,
        tenureMonths: 12,
        purpose: 'Local Edit Offline',
        priority: LoanPriority.high,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );
      await clientLoanRepo.createLoan(localLoan);

      final pendingBefore = await clientQueueRepo.getPendingItems();
      expect(pendingBefore.length, equals(1));

      // 2. Server sends a pull change for LOAN-OVERLAP (amount = 15000)
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
                'originDeviceId': 'DEV-OTHER-DEVICE',
                'payload': {
                  'id': 'LOAN-OVERLAP',
                  'amount': 15000.0,
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

      // Pending local mutation MUST remain intact in sync_queue!
      final pendingAfter = await clientQueueRepo.getPendingItems();
      expect(pendingAfter.length, equals(1));
      expect(pendingAfter.first.entityId, equals('LOAN-OVERLAP'));

      // Cursor advances to 8
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

      // Local loan status is updated to approved
      final loan = await clientLoanRepo.getLoanById('LOAN-ADMIN-PROP');
      expect(loan!.status, equals(LoanStatus.approved));

      // Local pending mutation in sync_queue remains intact
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

      // Verify sync_queue count is exactly 0
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

      // Cursor MUST remain at 0
      final cursor = await clientQueueRepo.getLastAppliedServerVersion();
      expect(cursor, equals(0));
    });
  });
}

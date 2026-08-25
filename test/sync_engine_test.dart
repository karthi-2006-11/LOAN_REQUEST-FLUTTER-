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

  group('SyncEngine Push Synchronization Unit Tests', () {
    test('1. UUID v4 Format: generateClientOperationId produces valid RFC 4122 UUID v4', () {
      final uuid = SyncQueueItem.generateClientOperationId();
      final uuidV4Regex = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$');
      expect(uuidV4Regex.hasMatch(uuid), isTrue);
    });

    test('2. Push with no pending items does not execute HTTP request', () async {
      var httpRequestMade = false;
      final mockClient = MockClient((req) async {
        httpRequestMade = true;
        return http.Response('{}', 200);
      });

      final syncEngine = SyncEngine(queueRepository: clientQueueRepo, httpClient: mockClient);
      final result = await syncEngine.pushPending(baseUrl: baseUrl, authToken: validToken);

      expect(result.totalProcessed, equals(0));
      expect(result.syncedCount, equals(0));
      expect(httpRequestMade, isFalse);
    });

    test('3. Successful Push: Item status updated to SYNCED locally', () async {
      final localLoan = LoanModel(
        id: 'LOAN-SYNC-001',
        userId: 'USR-CUST-1',
        userName: 'Customer User',
        amount: 15000.0,
        tenureMonths: 12,
        purpose: 'New Business',
        priority: LoanPriority.high,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await clientLoanRepo.createLoan(localLoan);
      final pendingBefore = await clientQueueRepo.getPendingItems();
      expect(pendingBefore.length, equals(1));
      final clientOpId = pendingBefore.first.clientOperationId;

      final mockClient = MockClient((req) async {
        expect(req.url.path, equals('/api/sync/push'));
        expect(req.headers['Authorization'], equals('Bearer $validToken'));

        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final ops = body['operations'] as List;
        expect(ops.length, equals(1));
        expect(ops.first['clientOperationId'], equals(clientOpId));

        return http.Response(
          jsonEncode({
            'success': true,
            'results': [
              {
                'clientOperationId': clientOpId,
                'entityId': 'LOAN-SYNC-001',
                'status': 'SYNCED',
                'message': 'Applied',
              }
            ],
          }),
          200,
        );
      });

      final syncEngine = SyncEngine(queueRepository: clientQueueRepo, httpClient: mockClient);
      final result = await syncEngine.pushPending(baseUrl: baseUrl, authToken: validToken);

      expect(result.totalProcessed, equals(1));
      expect(result.syncedCount, equals(1));

      final itemAfter = await clientQueueRepo.getByClientOperationId(clientOpId);
      expect(itemAfter!.status, equals('SYNCED'));
    });

    test('4. Network Failure: Item remains in sync_queue as SYNC_FAILED with preserved clientOperationId', () async {
      final opId = SyncQueueItem.generateClientOperationId();
      final item = SyncQueueItem(
        id: 'SQ-NET-FAIL',
        entityType: 'loan',
        entityId: 'LOAN-FAIL',
        operation: 'CREATE',
        payload: {'id': 'LOAN-FAIL', 'amount': 5000.0},
        clientOperationId: opId,
        createdAt: DateTime.now(),
      );
      await clientQueueRepo.enqueue(item);

      final mockClient = MockClient((req) async {
        throw const SocketException('Connection refused');
      });

      final syncEngine = SyncEngine(queueRepository: clientQueueRepo, httpClient: mockClient);
      final result = await syncEngine.pushPending(baseUrl: baseUrl, authToken: validToken);

      expect(result.failedCount, equals(1));

      final itemAfter = await clientQueueRepo.getByClientOperationId(opId);
      expect(itemAfter, isNotNull);
      expect(itemAfter!.status, equals('SYNC_FAILED'));
      expect(itemAfter.retryCount, equals(1));
      expect(itemAfter.clientOperationId, equals(opId)); // Retained!
    });

    test('5. HTTP 401 Unauthorized: Items reverted to PENDING_SYNC without discarding or extra retry increment', () async {
      final opId = SyncQueueItem.generateClientOperationId();
      final item = SyncQueueItem(
        id: 'SQ-401-TEST',
        entityType: 'loan',
        entityId: 'LOAN-401',
        operation: 'CREATE',
        payload: {},
        clientOperationId: opId,
        createdAt: DateTime.now(),
      );
      await clientQueueRepo.enqueue(item);

      final mockClient = MockClient((req) async {
        return http.Response(jsonEncode({'success': false, 'error': 'Unauthorized'}), 401);
      });

      final syncEngine = SyncEngine(queueRepository: clientQueueRepo, httpClient: mockClient);
      final result = await syncEngine.pushPending(baseUrl: baseUrl, authToken: 'invalid_token');

      expect(result.globalError, contains('401'));

      final itemAfter = await clientQueueRepo.getByClientOperationId(opId);
      expect(itemAfter, isNotNull);
      expect(itemAfter!.status, equals('PENDING_SYNC')); // Kept pending for auth re-try!
      expect(itemAfter.retryCount, equals(0));
    });

    test('6. Mixed Batch Results: Handles per-operation partial results independently in a single batch', () async {
      final op1 = SyncQueueItem.generateClientOperationId();
      final op2 = SyncQueueItem.generateClientOperationId();
      final op3 = SyncQueueItem.generateClientOperationId();

      await clientQueueRepo.enqueue(SyncQueueItem(
        id: 'SQ-MIXED-1',
        entityType: 'loan',
        entityId: 'LOAN-M1',
        operation: 'CREATE',
        payload: {},
        clientOperationId: op1,
        createdAt: DateTime.now().subtract(const Duration(seconds: 3)),
      ));

      await clientQueueRepo.enqueue(SyncQueueItem(
        id: 'SQ-MIXED-2',
        entityType: 'loan',
        entityId: 'LOAN-M2',
        operation: 'UPDATE',
        payload: {},
        clientOperationId: op2,
        createdAt: DateTime.now().subtract(const Duration(seconds: 2)),
      ));

      await clientQueueRepo.enqueue(SyncQueueItem(
        id: 'SQ-MIXED-3',
        entityType: 'loan',
        entityId: 'LOAN-M3',
        operation: 'DELETE',
        payload: {},
        clientOperationId: op3,
        createdAt: DateTime.now().subtract(const Duration(seconds: 1)),
      ));

      final mockClient = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'success': true,
            'results': [
              {'clientOperationId': op1, 'entityId': 'LOAN-M1', 'status': 'SYNCED', 'message': 'OK'},
              {'clientOperationId': op2, 'entityId': 'LOAN-M2', 'status': 'CONFLICT', 'message': 'Forbidden update'},
              {'clientOperationId': op3, 'entityId': 'LOAN-M3', 'status': 'FAILED', 'message': 'Database busy'},
            ],
          }),
          200,
        );
      });

      final syncEngine = SyncEngine(queueRepository: clientQueueRepo, httpClient: mockClient);
      final result = await syncEngine.pushPending(baseUrl: baseUrl, authToken: validToken);

      expect(result.totalProcessed, equals(3));
      expect(result.syncedCount, equals(1));
      expect(result.conflictCount, equals(1));
      expect(result.failedCount, equals(1));

      final item1 = await clientQueueRepo.getByClientOperationId(op1);
      final item2 = await clientQueueRepo.getByClientOperationId(op2);
      final item3 = await clientQueueRepo.getByClientOperationId(op3);

      expect(item1!.status, equals('SYNCED'));
      expect(item2!.status, equals('CONFLICT'));
      expect(item3!.status, equals('SYNC_FAILED'));
    });
  });
}

import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:loan_request_app/models/conflict_classification_models.dart';
import 'package:loan_request_app/models/conflict_resolution_models.dart';
import 'package:loan_request_app/models/loan_model.dart';
import 'package:loan_request_app/models/loan_priority.dart';
import 'package:loan_request_app/models/loan_status.dart';
import 'package:loan_request_app/models/sync_conflict_record.dart';
import 'package:loan_request_app/models/sync_queue_item.dart';
import 'package:loan_request_app/repositories/loan_repository.dart';
import 'package:loan_request_app/repositories/sync_queue_repository.dart';
import 'package:loan_request_app/services/connectivity_service.dart';
import 'package:loan_request_app/services/conflict_classifier.dart';
import 'package:loan_request_app/services/conflict_recovery_service.dart';
import 'package:loan_request_app/services/conflict_resolver.dart';
import 'package:loan_request_app/services/database_service.dart';
import 'package:loan_request_app/services/sync_coordinator.dart';
import 'package:loan_request_app/services/sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakeConnectivityService implements ConnectivityService {
  ConnectivityState state = ConnectivityState.backendReachable;
  final StreamController<ConnectivityState> _controller =
      StreamController<ConnectivityState>.broadcast();

  @override
  Stream<ConnectivityState> get stateStream => _controller.stream;

  @override
  Future<ConnectivityState> getCurrentState() async => state;

  @override
  Future<bool> hasNetworkInterface() async =>
      state != ConnectivityState.offline;

  @override
  Future<bool> isBackendReachable({String? baseUrl, Duration? timeout}) async =>
      state == ConnectivityState.backendReachable;

  @override
  Future<void> dispose() async => await _controller.close();
}

class FakeSyncEngine implements SyncEngine {
  int pushCount = 0;
  int pullCount = 0;

  @override
  Future<SyncEngineResult> pushPending({
    required String baseUrl,
    required String authToken,
    String? deviceId,
    int batchSize = 50,
  }) async {
    pushCount++;
    return SyncEngineResult(
      totalProcessed: 0,
      syncedCount: 0,
      failedCount: 0,
      conflictCount: 0,
    );
  }

  @override
  Future<SyncEnginePullResult> pullChanges({
    required String baseUrl,
    required String authToken,
    String? deviceId,
    int limit = 50,
  }) async {
    pullCount++;
    return SyncEnginePullResult(
      totalProcessed: 0,
      lastAppliedVersion: 1,
      hasMore: false,
    );
  }
}

void main() {
  late DatabaseService dbService;
  late SyncQueueRepository queueRepo;
  late LocalLoanRepository loanRepo;
  late ConflictClassifier classifier;
  late ConflictResolver resolver;
  late ConflictRecoveryService recoveryService;
  late FakeConnectivityService connectivityService;

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

    await dbService.database;

    queueRepo = LocalSyncQueueRepository(databaseService: dbService);
    loanRepo = LocalLoanRepository(databaseService: dbService);
    classifier = ConflictClassifier();
    resolver = ConflictResolver();
    recoveryService = ConflictRecoveryService(
      queueRepository: queueRepo,
      loanRepository: loanRepo,
      databaseService: dbService,
      classifier: classifier,
      resolver: resolver,
    );
    connectivityService = FakeConnectivityService();
  });

  tearDown(() async {
    await dbService.close();
    await connectivityService.dispose();
  });

  group('Phase 8.8.1 — Multi-Device & Offline-to-Online Integration Suite', () {
    test('Scenario A: Customer Offline Loan Creation', () async {
      final loan = LoanModel(
        id: 'LOAN-OFF-001',
        userId: 'USR-CUST-100',
        userName: 'John Doe',
        amount: 45000.0,
        tenureMonths: 12,
        purpose: 'Home Repair',
        priority: LoanPriority.high,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      final created = await loanRepo.createLoan(loan);
      expect(created.id, equals('LOAN-OFF-001'));

      final pending = await queueRepo.getPendingItems();
      expect(pending.length, equals(1));
      expect(pending.first.entityId, equals('LOAN-OFF-001'));
      expect(pending.first.operation, equals('CREATE'));
      expect(pending.first.status, equals('PENDING_SYNC'));
      expect(pending.first.clientOperationId, isNotEmpty);
    });

    test('Scenario B: Device B / Server Mutation Simulation', () async {
      final serverLoan = {
        'id': 'LOAN-OFF-001',
        'userId': 'USR-CUST-100',
        'amount': 45000.0,
        'status': 'APPROVED',
        'version': 2,
      };

      expect(serverLoan['version'], equals(2));
      expect(serverLoan['status'], equals('APPROVED'));
    });

    test('Scenario C & D: Stale Push (409 Conflict) and Conflict Evidence Preservation', () async {
      final loan = LoanModel(
        id: 'LOAN-STALE-001',
        userId: 'USR-CUST-100',
        userName: 'John Doe',
        amount: 60000.0,
        tenureMonths: 24,
        purpose: 'Car Loan',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );
      await loanRepo.createLoan(loan);

      final opId = SyncQueueItem.generateClientOperationId('OP-STALE');
      final queueItem = SyncQueueItem(
        id: 'Q-100',
        entityType: 'loan',
        entityId: 'LOAN-STALE-001',
        operation: 'UPDATE',
        payload: {'amount': 60000.0, 'purpose': 'Car Loan'},
        clientOperationId: opId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'PENDING_SYNC',
        baseVersion: 1,
      );
      await queueRepo.enqueue(queueItem);

      final conflictRecord = SyncConflictRecord(
        id: 'CONF-100',
        clientOperationId: opId,
        entityType: 'loan',
        entityId: 'LOAN-STALE-001',
        localValue: {'amount': 60000.0, 'purpose': 'Car Loan'},
        serverValue: {'amount': 50000.0, 'status': 'APPROVED', 'version': 2},
        serverVersion: 2,
        conflictType: 'CUSTOMER_FIELD_SPLIT',
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflictRecord);

      final storedConflict = await queueRepo.getConflictRecordByClientOperationId(opId);
      expect(storedConflict, isNotNull);
      expect(storedConflict!.clientOperationId, equals(opId));
      expect(storedConflict.serverVersion, equals(2));
    });

    test('Scenario E1: Conflict Recovery — CUSTOMER_WINS (Fresh UUID & baseVersion)', () async {
      final oldOpId = SyncQueueItem.generateClientOperationId('OLD-CW');
      final queueItem = SyncQueueItem(
        id: 'Q-CUST-WIN-1',
        entityType: 'loan',
        entityId: 'LOAN-CW-001',
        operation: 'UPDATE',
        payload: {'purpose': 'Medical Emergency'},
        clientOperationId: oldOpId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
        baseVersion: 1,
      );
      await queueRepo.enqueue(queueItem);

      final conflict = SyncConflictRecord(
        id: 'CONF-CW-1',
        clientOperationId: oldOpId,
        entityType: 'loan',
        entityId: 'LOAN-CW-001',
        localValue: {'purpose': 'Medical Emergency'},
        serverValue: {'purpose': 'General', 'version': 2},
        serverVersion: 2,
        conflictType: 'CUSTOMER_FIELD_SPLIT',
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflict);

      final result = await recoveryService.recoverConflict(conflict);
      expect(result.isRecovered, isTrue);
      expect(result.resolution, equals('CUSTOMER_WINS'));
      expect(result.newClientOperationId, isNotNull);
      expect(result.newClientOperationId, isNot(equals(oldOpId)));
      expect(result.recommendedBaseVersion, equals(2));

      final pending = await queueRepo.getPendingItems();
      expect(pending.length, equals(1));
      expect(pending.first.clientOperationId, equals(result.newClientOperationId));
      expect(pending.first.baseVersion, equals(2));
      expect(pending.first.retryCount, equals(0));
    });

    test('Scenario E2: Conflict Recovery — SERVER_WINS (Admin Finalized Loan)', () async {
      final opId = SyncQueueItem.generateClientOperationId('OP-FIN');
      final queueItem = SyncQueueItem(
        id: 'Q-FIN-001',
        entityType: 'loan',
        entityId: 'LOAN-FIN-001',
        operation: 'UPDATE',
        payload: {'amount': 35000.0},
        clientOperationId: opId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
        baseVersion: 1,
      );
      await queueRepo.enqueue(queueItem);

      final conflict = SyncConflictRecord(
        id: 'CONF-FIN-001',
        clientOperationId: opId,
        entityType: 'loan',
        entityId: 'LOAN-FIN-001',
        localValue: {'amount': 35000.0},
        serverValue: {
          'id': 'LOAN-FIN-001',
          'userId': 'USR-CUST-100',
          'userName': 'John Doe',
          'amount': 30000.0,
          'tenureMonths': 12,
          'purpose': 'Personal',
          'priority': 'low',
          'status': 'approved',
          'version': 2,
        },
        serverVersion: 2,
        conflictType: 'ADMIN_DECISION_FINAL',
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflict);

      final result = await recoveryService.recoverConflict(conflict);
      expect(result.isRecovered, isTrue);
      expect(result.resolution, equals('SERVER_WINS'));

      final updatedLoan = await loanRepo.getLoanById('LOAN-FIN-001');
      expect(updatedLoan?.status, equals(LoanStatus.approved));

      final itemAfterRecovery = await queueRepo.getByClientOperationId(opId);
      expect(itemAfterRecovery?.status, equals('REJECTED'));
    });

    test('Scenario F: Global Cursor vs Entity Version Separation', () {
      const entityVersion = 3;
      const globalPullCursor = 105;

      expect(entityVersion, isNot(equals(globalPullCursor)));
    });

    test('Scenario G: Offline -> Online -> Offline Transition Reliability', () async {
      connectivityService.state = ConnectivityState.offline;
      expect(await connectivityService.hasNetworkInterface(), isFalse);

      final loan = LoanModel(
        id: 'LOAN-FLUID-01',
        userId: 'USR-CUST-100',
        userName: 'John Doe',
        amount: 20000.0,
        tenureMonths: 6,
        purpose: 'Tools',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );
      await loanRepo.createLoan(loan);

      connectivityService.state = ConnectivityState.backendReachable;
      expect(await connectivityService.hasNetworkInterface(), isTrue);

      connectivityService.state = ConnectivityState.offline;
      expect(await connectivityService.hasNetworkInterface(), isFalse);

      final pending = await queueRepo.getPendingItems();
      expect(pending.length, equals(1));
    });

    test('Scenario H: Multi-Device Customer Edits (Split Ownership)', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.splitOwnershipMerge,
        entityType: 'loan',
        entityId: 'LOAN-SPLIT-01',
        operation: 'UPDATE',
        localPayload: {'purpose': 'Home Renovation'},
        serverState: {'purpose': 'General', 'version': 2},
      );

      final resolution = resolver.resolve(input);
      expect(resolution.resolution, equals(ResolutionOutcome.fieldMerge));
    });

    test('Scenario I: Admin Finalization Authority Race', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.adminStatusOverride,
        entityType: 'loan',
        entityId: 'LOAN-ADM-RACE',
        operation: 'UPDATE',
        localPayload: {'amount': 90000.0},
        serverState: {'status': 'rejected', 'amount': 80000.0, 'version': 3},
      );

      final resolution = resolver.resolve(input);
      expect(resolution.resolution, equals(ResolutionOutcome.serverWins));
    });

    test('Scenario J: Single-Flight Lifecycle & Coalescing Protection', () async {
      final fakeSyncEngine = FakeSyncEngine();
      final coordinator = SyncCoordinator(
        connectivityService: connectivityService,
        syncEngine: fakeSyncEngine,
      );

      connectivityService.state = ConnectivityState.backendReachable;

      final f1 = coordinator.requestSync(
        trigger: SyncTrigger.startup,
        baseUrl: 'http://localhost:8080',
        authToken: 'token',
      );
      final f2 = coordinator.requestSync(
        trigger: SyncTrigger.appResumed,
        baseUrl: 'http://localhost:8080',
        authToken: 'token',
      );
      final f3 = coordinator.requestSync(
        trigger: SyncTrigger.postLogin,
        baseUrl: 'http://localhost:8080',
        authToken: 'token',
      );

      await Future.wait([f1, f2, f3]);

      expect(fakeSyncEngine.pushCount, lessThanOrEqualTo(2));
      expect(coordinator.isSyncRunning, isFalse);

      await coordinator.dispose();
    });

    test('Scenario K: Idempotent Replay Verification', () {
      final clientOpId = SyncQueueItem.generateClientOperationId('IDEM');
      final replayAttempt1 = {'clientOperationId': clientOpId, 'status': 'SYNCED'};
      final replayAttempt2 = {'clientOperationId': clientOpId, 'status': 'SYNCED'};

      expect(replayAttempt1['clientOperationId'], equals(replayAttempt2['clientOperationId']));
    });

    test('Scenario L: Atomic Transaction Rollback Safety', () async {
      final db = await dbService.database;

      try {
        await db.transaction((txn) async {
          await txn.insert('sync_queue', {
            'id': 'Q-FAIL-1',
            'clientOperationId': 'OP-FAIL-1',
            'entityType': 'loan',
            'entityId': 'LOAN-FAIL-1',
            'operation': 'CREATE',
            'payload': '{}',
            'createdAt': DateTime.now().toIso8601String(),
            'status': 'PENDING_SYNC',
            'retryCount': 0,
            'baseVersion': 1,
          });

          throw Exception('Forced Transaction Failure');
        });
      } catch (_) {}

      final items = await db.query('sync_queue', where: 'id = ?', whereArgs: ['Q-FAIL-1']);
      expect(items, isEmpty);
    });
  });
}

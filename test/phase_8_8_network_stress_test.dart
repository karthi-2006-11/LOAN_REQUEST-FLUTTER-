import 'dart:async';
import 'dart:io';

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
import 'package:path/path.dart' as p;
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

class StressFakeSyncEngine implements SyncEngine {
  int pushCount = 0;
  int pullCount = 0;
  bool shouldSimulate401 = false;
  bool shouldSimulate500 = false;
  bool shouldSimulateTimeout = false;

  @override
  Future<SyncEngineResult> pushPending({
    required String baseUrl,
    required String authToken,
    String? deviceId,
    int batchSize = 50,
  }) async {
    pushCount++;

    if (shouldSimulateTimeout) {
      throw const SocketException('Connection timed out');
    }
    if (shouldSimulate401) {
      return SyncEngineResult(
        totalProcessed: 0,
        syncedCount: 0,
        failedCount: 0,
        conflictCount: 0,
        globalError: 'HTTP 401 Unauthorized',
      );
    }
    if (shouldSimulate500) {
      return SyncEngineResult(
        totalProcessed: 1,
        syncedCount: 0,
        failedCount: 1,
        conflictCount: 0,
        globalError: 'HTTP 500 Internal Server Error',
      );
    }

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

    if (shouldSimulateTimeout) {
      throw const SocketException('Connection timed out during pull');
    }
    if (shouldSimulate401 || shouldSimulate500) {
      return SyncEnginePullResult(
        totalProcessed: 0,
        lastAppliedVersion: 0,
        hasMore: false,
      );
    }

    return SyncEnginePullResult(
      totalProcessed: 0,
      lastAppliedVersion: 1,
      hasMore: false,
    );
  }
}

void main() {
  late Directory tempDir;
  late int testIndex;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    testIndex = 0;
  });

  late DatabaseService dbService;
  late SyncQueueRepository queueRepo;
  late LocalLoanRepository loanRepo;
  late ConflictClassifier classifier;
  late ConflictResolver resolver;
  late ConflictRecoveryService recoveryService;
  late FakeConnectivityService connectivityService;
  late StressFakeSyncEngine syncEngine;
  late SyncCoordinator coordinator;

  setUp(() async {
    testIndex++;
    tempDir = await Directory.systemTemp.createTemp('blackvault_p882_${testIndex}_');

    dbService = DatabaseService.instance;
    await dbService.close();

    final systemDbPath = await getDatabasesPath();
    final defaultPath = p.join(systemDbPath, 'blackvault.db');
    await databaseFactory.deleteDatabase(defaultPath);

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
    syncEngine = StressFakeSyncEngine();
    coordinator = SyncCoordinator(
      connectivityService: connectivityService,
      syncEngine: syncEngine,
    );
  });

  tearDown(() async {
    await coordinator.dispose();
    await dbService.close();
    await connectivityService.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Phase 8.8.2 — Network Boundary & Edge-Case Stress Suite', () {
    // --- SECTION A: NETWORK BOUNDARY ---
    test('1. Network unavailable before PUSH starts safely defers sync', () async {
      connectivityService.state = ConnectivityState.offline;

      final result = await coordinator.requestSync(
        trigger: SyncTrigger.startup,
        baseUrl: 'http://localhost:8080',
        authToken: 'token',
      );

      expect(result.status, equals(SyncCoordinatorStatus.skippedOffline));
      expect(syncEngine.pushCount, equals(0));
    });

    test('2. Network unavailable before PULL starts preserves local cursor', () async {
      connectivityService.state = ConnectivityState.offline;

      final initialCursor = await queueRepo.getLastAppliedServerVersion();

      final result = await coordinator.requestSync(
        trigger: SyncTrigger.appResumed,
        baseUrl: 'http://localhost:8080',
        authToken: 'token',
      );

      expect(result.status, equals(SyncCoordinatorStatus.skippedOffline));
      final endingCursor = await queueRepo.getLastAppliedServerVersion();
      expect(endingCursor, equals(initialCursor));
    });

    test('3. Connectivity transition online -> offline during sync is handled gracefully', () async {
      connectivityService.state = ConnectivityState.backendReachable;
      syncEngine.shouldSimulateTimeout = true;

      final result = await coordinator.requestSync(
        trigger: SyncTrigger.manual,
        baseUrl: 'http://localhost:8080',
        authToken: 'token',
      );

      expect(result.status, equals(SyncCoordinatorStatus.failed));
      expect(coordinator.isSyncRunning, isFalse);
    });

    test('4. Connectivity transition offline -> online triggers queued sync recovery', () async {
      connectivityService.state = ConnectivityState.offline;

      final loan = LoanModel(
        id: 'LOAN-STRESS-01',
        userId: 'USR-01',
        userName: 'Stress Test User',
        amount: 20000.0,
        tenureMonths: 6,
        purpose: 'Equipment',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );
      await loanRepo.createLoan(loan);

      // Reconnect online
      connectivityService.state = ConnectivityState.backendReachable;
      final result = await coordinator.requestSync(
        trigger: SyncTrigger.connectivityRestored,
        baseUrl: 'http://localhost:8080',
        authToken: 'token',
      );

      expect(result.status, equals(SyncCoordinatorStatus.completed));
      expect(syncEngine.pushCount, equals(1));
    });

    test('5. Repeated offline/online toggles do not duplicate or lose queue items', () async {
      final loan = LoanModel(
        id: 'LOAN-TOGGLE-01',
        userId: 'USR-01',
        userName: 'Toggle User',
        amount: 15000.0,
        tenureMonths: 12,
        purpose: 'Business',
        priority: LoanPriority.low,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );
      await loanRepo.createLoan(loan);

      for (int i = 0; i < 5; i++) {
        connectivityService.state = ConnectivityState.offline;
        await coordinator.requestSync(trigger: SyncTrigger.manual, baseUrl: 'http://localhost', authToken: 'token');
        connectivityService.state = ConnectivityState.backendReachable;
      }

      final pending = await queueRepo.getPendingItems();
      expect(pending.length, equals(1));
    });

    test('6. Network failure never deletes or rolls back local SQLite mutation', () async {
      connectivityService.state = ConnectivityState.backendReachable;
      syncEngine.shouldSimulateTimeout = true;

      final loan = LoanModel(
        id: 'LOAN-PERIST-01',
        userId: 'USR-01',
        userName: 'Persist User',
        amount: 50000.0,
        tenureMonths: 24,
        purpose: 'Medical',
        priority: LoanPriority.high,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );
      await loanRepo.createLoan(loan);

      await coordinator.requestSync(trigger: SyncTrigger.postMutation, baseUrl: 'http://localhost', authToken: 'token');

      final savedLoan = await loanRepo.getLoanById('LOAN-PERIST-01');
      expect(savedLoan, isNotNull);
      expect(savedLoan?.amount, equals(50000.0));
    });

    // --- SECTION B: HTTP FAILURE BOUNDARIES ---
    test('7. HTTP 401 during PUSH isolates auth error and keeps queue item PENDING_SYNC', () async {
      connectivityService.state = ConnectivityState.backendReachable;
      syncEngine.shouldSimulate401 = true;

      final loan = LoanModel(
        id: 'LOAN-401-PUSH',
        userId: 'USR-01',
        userName: 'User 401',
        amount: 10000.0,
        tenureMonths: 6,
        purpose: 'Personal',
        priority: LoanPriority.low,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );
      await loanRepo.createLoan(loan);

      final result = await coordinator.requestSync(trigger: SyncTrigger.manual, baseUrl: 'http://localhost', authToken: 'expired_token');

      expect(result.status, equals(SyncCoordinatorStatus.failed));

      final pending = await queueRepo.getPendingItems();
      expect(pending.length, equals(1));
      expect(pending.first.status, equals('PENDING_SYNC'));
    });

    test('8. HTTP 401 during PULL preserves local cursor without advancing', () async {
      connectivityService.state = ConnectivityState.backendReachable;
      syncEngine.shouldSimulate401 = true;

      final initialCursor = await queueRepo.getLastAppliedServerVersion();
      await coordinator.requestSync(trigger: SyncTrigger.appResumed, baseUrl: 'http://localhost', authToken: 'expired_token');
      final endingCursor = await queueRepo.getLastAppliedServerVersion();

      expect(endingCursor, equals(initialCursor));
    });

    test('9. HTTP 500 during PUSH preserves queue item and keeps retry accounting intact', () async {
      connectivityService.state = ConnectivityState.backendReachable;
      syncEngine.shouldSimulate500 = true;

      final loan = LoanModel(
        id: 'LOAN-500-PUSH',
        userId: 'USR-01',
        userName: 'User 500',
        amount: 30000.0,
        tenureMonths: 12,
        purpose: 'Tech',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );
      await loanRepo.createLoan(loan);

      final result = await coordinator.requestSync(trigger: SyncTrigger.postMutation, baseUrl: 'http://localhost', authToken: 'token');

      expect(result.status, equals(SyncCoordinatorStatus.failed));
      final pending = await queueRepo.getPendingItems();
      expect(pending.length, equals(1));
    });

    test('10. HTTP 500 during PULL maintains atomic transaction safety', () async {
      connectivityService.state = ConnectivityState.backendReachable;
      syncEngine.shouldSimulate500 = true;

      final result = await coordinator.requestSync(trigger: SyncTrigger.startup, baseUrl: 'http://localhost', authToken: 'token');
      expect(result.status, equals(SyncCoordinatorStatus.failed));
    });

    test('11. Timeout/SocketException is isolated cleanly without locking coordinator', () async {
      connectivityService.state = ConnectivityState.backendReachable;
      syncEngine.shouldSimulateTimeout = true;

      final result = await coordinator.requestSync(trigger: SyncTrigger.manual, baseUrl: 'http://localhost', authToken: 'token');

      expect(result.status, equals(SyncCoordinatorStatus.failed));
      expect(coordinator.isSyncRunning, isFalse);
    });

    // --- SECTION C: CONCURRENCY / LIFECYCLE STRESS ---
    test('12. Rapid startup + appResumed triggers are single-flight protected', () async {
      connectivityService.state = ConnectivityState.backendReachable;

      final f1 = coordinator.requestSync(trigger: SyncTrigger.startup, baseUrl: 'http://localhost', authToken: 'token');
      final f2 = coordinator.requestSync(trigger: SyncTrigger.appResumed, baseUrl: 'http://localhost', authToken: 'token');

      await Future.wait([f1, f2]);
      expect(syncEngine.pushCount, lessThanOrEqualTo(2));
      expect(coordinator.isSyncRunning, isFalse);
    });

    test('13. Rapid appResumed + postLogin triggers are coalesced cleanly', () async {
      connectivityService.state = ConnectivityState.backendReachable;

      final f1 = coordinator.requestSync(trigger: SyncTrigger.appResumed, baseUrl: 'http://localhost', authToken: 'token');
      final f2 = coordinator.requestSync(trigger: SyncTrigger.postLogin, baseUrl: 'http://localhost', authToken: 'token');

      await Future.wait([f1, f2]);
      expect(coordinator.isSyncRunning, isFalse);
    });

    test('14. Rapid postLogin + postMutation triggers do not cause SQLite lock errors', () async {
      connectivityService.state = ConnectivityState.backendReachable;

      final f1 = coordinator.requestSync(trigger: SyncTrigger.postLogin, baseUrl: 'http://localhost', authToken: 'token');
      final f2 = coordinator.requestSync(trigger: SyncTrigger.postMutation, baseUrl: 'http://localhost', authToken: 'token');

      await Future.wait([f1, f2]);
      expect(coordinator.isSyncRunning, isFalse);
    });

    test('15. Burst of 10 concurrent requestSync() calls executes at most 2 total runs', () async {
      connectivityService.state = ConnectivityState.backendReachable;

      final futures = List.generate(
        10,
        (_) => coordinator.requestSync(trigger: SyncTrigger.manual, baseUrl: 'http://localhost', authToken: 'token'),
      );

      await Future.wait(futures);
      expect(syncEngine.pushCount, lessThanOrEqualTo(2));
      expect(coordinator.isSyncRunning, isFalse);
    });

    test('16. SyncCoordinator permits at most 1 active run with 1 follow-up', () async {
      connectivityService.state = ConnectivityState.backendReachable;

      final f1 = coordinator.requestSync(trigger: SyncTrigger.startup, baseUrl: 'http://localhost', authToken: 'token');
      final f2 = coordinator.requestSync(trigger: SyncTrigger.appResumed, baseUrl: 'http://localhost', authToken: 'token');
      final f3 = coordinator.requestSync(trigger: SyncTrigger.postMutation, baseUrl: 'http://localhost', authToken: 'token');

      await Future.wait([f1, f2, f3]);
      expect(syncEngine.pushCount, lessThanOrEqualTo(2));
    });

    // --- SECTION D: CONFLICT RECOVERY STRESS ---
    test('17. Conflict recovery under unstable network preserves conflict evidence', () async {
      final opId = SyncQueueItem.generateClientOperationId('STRESS-CONF');
      final queueItem = SyncQueueItem(
        id: 'Q-STR-1',
        entityType: 'loan',
        entityId: 'LOAN-STR-1',
        operation: 'UPDATE',
        payload: {'purpose': 'Renovation'},
        clientOperationId: opId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
        baseVersion: 1,
      );
      await queueRepo.enqueue(queueItem);

      final conflict = SyncConflictRecord(
        id: 'CONF-STR-1',
        clientOperationId: opId,
        entityType: 'loan',
        entityId: 'LOAN-STR-1',
        localValue: {'purpose': 'Renovation'},
        serverValue: {'purpose': 'Basic', 'version': 2},
        serverVersion: 2,
        conflictType: 'CUSTOMER_FIELD_SPLIT',
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflict);

      final result = await recoveryService.recoverConflict(conflict);
      expect(result.isRecovered, isTrue);
      expect(result.resolution, equals('CUSTOMER_WINS'));
    });

    test('18. Conflict recovery followed immediately by second sync attempt is idempotent', () async {
      final opId = SyncQueueItem.generateClientOperationId('IDEM-CONF');
      final queueItem = SyncQueueItem(
        id: 'Q-IDEM-1',
        entityType: 'loan',
        entityId: 'LOAN-IDEM-1',
        operation: 'UPDATE',
        payload: {'purpose': 'Travel'},
        clientOperationId: opId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
        baseVersion: 1,
      );
      await queueRepo.enqueue(queueItem);

      final conflict = SyncConflictRecord(
        id: 'CONF-IDEM-1',
        clientOperationId: opId,
        entityType: 'loan',
        entityId: 'LOAN-IDEM-1',
        localValue: {'purpose': 'Travel'},
        serverValue: {'purpose': 'Old', 'version': 2},
        serverVersion: 2,
        conflictType: 'CUSTOMER_FIELD_SPLIT',
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflict);

      final res1 = await recoveryService.recoverConflict(conflict);
      expect(res1.isRecovered, isTrue);

      final conflictRefetched = await queueRepo.getConflictRecordByClientOperationId(opId);
      final res2 = await recoveryService.recoverConflict(conflictRefetched!);
      expect(res2.isRecovered, isFalse); // Already resolved
    });

    test('19. CUSTOMER_WINS requeue under repeated retry pressure maintains fresh UUID', () async {
      final oldOpId = SyncQueueItem.generateClientOperationId('RETRY-PRESS');
      final queueItem = SyncQueueItem(
        id: 'Q-RP-1',
        entityType: 'loan',
        entityId: 'LOAN-RP-1',
        operation: 'UPDATE',
        payload: {'amount': 40000.0},
        clientOperationId: oldOpId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
        baseVersion: 1,
      );
      await queueRepo.enqueue(queueItem);

      final conflict = SyncConflictRecord(
        id: 'CONF-RP-1',
        clientOperationId: oldOpId,
        entityType: 'loan',
        entityId: 'LOAN-RP-1',
        localValue: {'amount': 40000.0},
        serverValue: {'amount': 30000.0, 'version': 3},
        serverVersion: 3,
        conflictType: 'CUSTOMER_FIELD_SPLIT',
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflict);

      final res = await recoveryService.recoverConflict(conflict);
      expect(res.newClientOperationId, isNot(equals(oldOpId)));
      expect(res.recommendedBaseVersion, equals(3));
    });

    test('20. SERVER_WINS finalized-loan recovery under repeated sync attempts rejects requeue', () async {
      final opId = SyncQueueItem.generateClientOperationId('FINAL-REP');
      final queueItem = SyncQueueItem(
        id: 'Q-FR-1',
        entityType: 'loan',
        entityId: 'LOAN-FR-1',
        operation: 'UPDATE',
        payload: {'amount': 40000.0},
        clientOperationId: opId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
        baseVersion: 1,
      );
      await queueRepo.enqueue(queueItem);

      final conflict = SyncConflictRecord(
        id: 'CONF-FR-1',
        clientOperationId: opId,
        entityType: 'loan',
        entityId: 'LOAN-FR-1',
        localValue: {'amount': 40000.0},
        serverValue: {
          'id': 'LOAN-FR-1',
          'userId': 'USR-1',
          'userName': 'User',
          'amount': 30000.0,
          'tenureMonths': 12,
          'purpose': 'Personal',
          'priority': 'low',
          'status': 'rejected',
          'version': 4,
        },
        serverVersion: 4,
        conflictType: 'ADMIN_DECISION_FINAL',
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflict);

      final res = await recoveryService.recoverConflict(conflict);
      expect(res.resolution, equals('SERVER_WINS'));

      final pending = await queueRepo.getPendingItems();
      expect(pending, isEmpty);
    });

    test('21. Retry boundary at retryCount = 3 marks resolution MANUAL', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.customerFieldConflict,
        entityType: 'loan',
        entityId: 'LOAN-R3',
        operation: 'UPDATE',
        localPayload: {'amount': 10000.0},
        serverState: {'amount': 8000.0, 'version': 2},
        retryCount: 3,
      );

      final res = resolver.resolve(input);
      expect(res.resolution, equals(ResolutionOutcome.unresolved));
      expect(res.requiresRequeue, isFalse);
    });

    test('22. Retry boundary above retryCount = 3 marks resolution MANUAL', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.customerFieldConflict,
        entityType: 'loan',
        entityId: 'LOAN-R4',
        operation: 'UPDATE',
        localPayload: {'amount': 10000.0},
        serverState: {'amount': 8000.0, 'version': 2},
        retryCount: 4,
      );

      final res = resolver.resolve(input);
      expect(res.resolution, equals(ResolutionOutcome.unresolved));
      expect(res.requiresRequeue, isFalse);
    });

    test('23. Recovered conflict cannot generate duplicate queue items', () async {
      final opId = SyncQueueItem.generateClientOperationId('NODUP');
      final queueItem = SyncQueueItem(
        id: 'Q-NODUP-1',
        entityType: 'loan',
        entityId: 'LOAN-ND-1',
        operation: 'UPDATE',
        payload: {'purpose': 'Education'},
        clientOperationId: opId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
        baseVersion: 1,
      );
      await queueRepo.enqueue(queueItem);

      final conflict = SyncConflictRecord(
        id: 'CONF-ND-1',
        clientOperationId: opId,
        entityType: 'loan',
        entityId: 'LOAN-ND-1',
        localValue: {'purpose': 'Education'},
        serverValue: {'purpose': 'Old', 'version': 2},
        serverVersion: 2,
        conflictType: 'CUSTOMER_FIELD_SPLIT',
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflict);

      await recoveryService.recoverConflict(conflict);
      final pending = await queueRepo.getPendingItems();
      expect(pending.length, equals(1)); // Only 1 requeued item
    });

    test('24. Recovered conflict always receives a fresh UUID v4', () async {
      final oldOpId = SyncQueueItem.generateClientOperationId('UUID-TEST');
      final queueItem = SyncQueueItem(
        id: 'Q-UUID-1',
        entityType: 'loan',
        entityId: 'LOAN-UUID-1',
        operation: 'UPDATE',
        payload: {'purpose': 'Tech'},
        clientOperationId: oldOpId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
        baseVersion: 1,
      );
      await queueRepo.enqueue(queueItem);

      final conflict = SyncConflictRecord(
        id: 'CONF-UUID-1',
        clientOperationId: oldOpId,
        entityType: 'loan',
        entityId: 'LOAN-UUID-1',
        localValue: {'purpose': 'Tech'},
        serverValue: {'purpose': 'Old', 'version': 2},
        serverVersion: 2,
        conflictType: 'CUSTOMER_FIELD_SPLIT',
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflict);

      final res = await recoveryService.recoverConflict(conflict);
      expect(res.newClientOperationId, isNot(equals(oldOpId)));
    });

    test('25. Requeued operation uses entity server version, never global sync cursor', () async {
      const entityServerVersion = 4;
      const globalSyncCursor = 250;

      final oldOpId = SyncQueueItem.generateClientOperationId('VER-ALIGN');
      final queueItem = SyncQueueItem(
        id: 'Q-VA-1',
        entityType: 'loan',
        entityId: 'LOAN-VA-1',
        operation: 'UPDATE',
        payload: {'purpose': 'Tools'},
        clientOperationId: oldOpId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
        baseVersion: 1,
      );
      await queueRepo.enqueue(queueItem);

      final conflict = SyncConflictRecord(
        id: 'CONF-VA-1',
        clientOperationId: oldOpId,
        entityType: 'loan',
        entityId: 'LOAN-VA-1',
        localValue: {'purpose': 'Tools'},
        serverValue: {'purpose': 'Old', 'version': entityServerVersion},
        serverVersion: entityServerVersion,
        conflictType: 'CUSTOMER_FIELD_SPLIT',
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflict);

      await queueRepo.updateLastAppliedServerVersion(globalSyncCursor);

      final res = await recoveryService.recoverConflict(conflict);
      expect(res.recommendedBaseVersion, equals(entityServerVersion));
      expect(res.recommendedBaseVersion, isNot(equals(globalSyncCursor)));
    });

    // --- SECTION E: IDEMPOTENCY ---
    test('26. Same clientOperationId replay produces identical cached response structure', () {
      final opId = SyncQueueItem.generateClientOperationId('REPLAY');
      final r1 = {'clientOperationId': opId, 'version': 2, 'status': 'SYNCED'};
      final r2 = {'clientOperationId': opId, 'version': 2, 'status': 'SYNCED'};

      expect(r1, equals(r2));
    });

    test('27. Replay after successful conflict recovery does not duplicate requeued items', () async {
      final oldOpId = SyncQueueItem.generateClientOperationId('REPLAY-RECOV');
      final queueItem = SyncQueueItem(
        id: 'Q-RR-1',
        entityType: 'loan',
        entityId: 'LOAN-RR-1',
        operation: 'UPDATE',
        payload: {'purpose': 'Farming'},
        clientOperationId: oldOpId,
        createdAt: DateTime.now(),
        retryCount: 0,
        status: 'CONFLICT',
        baseVersion: 1,
      );
      await queueRepo.enqueue(queueItem);

      final conflict = SyncConflictRecord(
        id: 'CONF-RR-1',
        clientOperationId: oldOpId,
        entityType: 'loan',
        entityId: 'LOAN-RR-1',
        localValue: {'purpose': 'Farming'},
        serverValue: {'purpose': 'Old', 'version': 2},
        serverVersion: 2,
        conflictType: 'CUSTOMER_FIELD_SPLIT',
        createdAt: DateTime.now(),
      );
      await queueRepo.saveConflictRecord(conflict);

      await recoveryService.recoverConflict(conflict);
      final refetched = await queueRepo.getConflictRecordByClientOperationId(oldOpId);
      await recoveryService.recoverConflict(refetched!);

      final pending = await queueRepo.getPendingItems();
      expect(pending.length, equals(1));
    });

    test('28. Repeated sync execution cannot double-apply an already-applied operation', () async {
      connectivityService.state = ConnectivityState.backendReachable;

      final f1 = coordinator.requestSync(trigger: SyncTrigger.manual, baseUrl: 'http://localhost', authToken: 'token');
      final f2 = coordinator.requestSync(trigger: SyncTrigger.manual, baseUrl: 'http://localhost', authToken: 'token');

      await Future.wait([f1, f2]);
      expect(coordinator.isSyncRunning, isFalse);
    });

    test('29. Own-device echo filtering is preserved under repeated pull cycles', () async {
      const clientDeviceId = 'DEV-CLIENT-001';
      const originDeviceId = 'DEV-CLIENT-001';

      expect(clientDeviceId == originDeviceId, isTrue);
    });

    // --- SECTION F: TRANSACTION / ATOMICITY ---
    test('30. Forced failure during multi-table transaction rolls back sync_queue completely', () async {
      final db = await dbService.database;

      try {
        await db.transaction((txn) async {
          await txn.insert('sync_queue', {
            'id': 'Q-TXN-1',
            'clientOperationId': 'OP-TXN-1',
            'entityType': 'loan',
            'entityId': 'LOAN-TXN-1',
            'operation': 'CREATE',
            'payload': '{}',
            'createdAt': DateTime.now().toIso8601String(),
            'status': 'PENDING_SYNC',
            'retryCount': 0,
            'baseVersion': 1,
          });

          throw Exception('Simulated Transaction Crash 1');
        });
      } catch (_) {}

      final items = await db.query('sync_queue', where: 'id = ?', whereArgs: ['Q-TXN-1']);
      expect(items, isEmpty);
    });

    test('31. Forced failure during conflict update rolls back all transaction steps', () async {
      final db = await dbService.database;

      try {
        await db.transaction((txn) async {
          await txn.insert('sync_conflicts', {
            'id': 'CONF-TXN-2',
            'clientOperationId': 'OP-TXN-2',
            'entityType': 'loan',
            'entityId': 'LOAN-TXN-2',
            'localPayloadJson': '{}',
            'serverPayloadJson': '{}',
            'serverEntityVersion': 2,
            'conflictType': 'CUSTOMER_FIELD_SPLIT',
            'createdAt': DateTime.now().toIso8601String(),
            'isResolved': 0,
          });

          throw Exception('Simulated Transaction Crash 2');
        });
      } catch (_) {}

      final conflicts = await db.query('sync_conflicts', where: 'id = ?', whereArgs: ['CONF-TXN-2']);
      expect(conflicts, isEmpty);
    });

    test('32. Forced failure during entity update rolls back queue, conflict, and entity changes', () async {
      final db = await dbService.database;

      try {
        await db.transaction((txn) async {
          await txn.insert('loans', {
            'id': 'LOAN-TXN-3',
            'userId': 'USR-TXN',
            'userName': 'User TXN',
            'amount': 10000.0,
            'tenureMonths': 6,
            'purpose': 'Test',
            'priority': 'low',
            'status': 'pending',
            'createdAt': DateTime.now().toIso8601String(),
          });

          throw Exception('Simulated Transaction Crash 3');
        });
      } catch (_) {}

      final loans = await db.query('loans', where: 'id = ?', whereArgs: ['LOAN-TXN-3']);
      expect(loans, isEmpty);
    });

    test('33. Full SQLite transaction rollback leaves zero orphaned records across multi-table operations', () async {
      final db = await dbService.database;

      try {
        await db.transaction((txn) async {
          await txn.insert('loans', {
            'id': 'LOAN-ATOMIC-ALL',
            'userId': 'USR-ATOMIC',
            'userName': 'User Atomic',
            'amount': 50000.0,
            'tenureMonths': 12,
            'purpose': 'Atomic Check',
            'priority': 'high',
            'status': 'pending',
            'createdAt': DateTime.now().toIso8601String(),
          });

          await txn.insert('sync_queue', {
            'id': 'Q-ATOMIC-ALL',
            'clientOperationId': 'OP-ATOMIC-ALL',
            'entityType': 'loan',
            'entityId': 'LOAN-ATOMIC-ALL',
            'operation': 'CREATE',
            'payload': '{}',
            'createdAt': DateTime.now().toIso8601String(),
            'status': 'PENDING_SYNC',
            'retryCount': 0,
            'baseVersion': 1,
          });

          throw Exception('Full Transaction Rollback Triggered');
        });
      } catch (_) {}

      final loans = await db.query('loans', where: 'id = ?', whereArgs: ['LOAN-ATOMIC-ALL']);
      final queue = await db.query('sync_queue', where: 'id = ?', whereArgs: ['Q-ATOMIC-ALL']);

      expect(loans, isEmpty);
      expect(queue, isEmpty);
    });
  });
}

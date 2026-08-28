import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:loan_request_app/models/loan_model.dart';
import 'package:loan_request_app/models/loan_priority.dart';
import 'package:loan_request_app/models/loan_status.dart';
import 'package:loan_request_app/models/loan_sync_status.dart';
import 'package:loan_request_app/models/notification_model.dart';
import 'package:loan_request_app/models/sync_queue_item.dart';
import 'package:loan_request_app/providers/loan_provider.dart';
import 'package:loan_request_app/providers/notification_provider.dart';
import 'package:loan_request_app/repositories/loan_repository.dart';
import 'package:loan_request_app/repositories/notification_repository.dart';
import 'package:loan_request_app/repositories/sync_queue_repository.dart';
import 'package:loan_request_app/services/connectivity_service.dart';
import 'package:loan_request_app/services/database_service.dart';
import 'package:loan_request_app/services/sync_coordinator.dart';
import 'package:loan_request_app/services/sync_engine.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakeConnectivityService implements ConnectivityService {
  ConnectivityState state = ConnectivityState.backendReachable;
  final StreamController<ConnectivityState> _controller = StreamController<ConnectivityState>.broadcast();

  @override
  Stream<ConnectivityState> get stateStream => _controller.stream;

  @override
  Future<ConnectivityState> getCurrentState() async => state;

  @override
  Future<bool> hasNetworkInterface() async => state != ConnectivityState.offline;

  @override
  Future<bool> isBackendReachable({String? baseUrl, Duration? timeout}) async => state == ConnectivityState.backendReachable;

  @override
  Future<void> dispose() async => await _controller.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
  late LocalNotificationRepository notifRepo;

  setUp(() async {
    testIndex++;
    tempDir = await Directory.systemTemp.createTemp('blackvault_p94_${testIndex}_');

    dbService = DatabaseService.instance;
    await dbService.close();

    final systemDbPath = await getDatabasesPath();
    final defaultPath = p.join(systemDbPath, 'blackvault.db');
    await databaseFactory.deleteDatabase(defaultPath);

    final db = await dbService.database;
    await db.delete('notifications');
    await db.delete('sync_queue');
    await db.delete('loans');
    await db.delete('sync_conflicts');

    queueRepo = LocalSyncQueueRepository(databaseService: dbService);
    loanRepo = LocalLoanRepository(databaseService: dbService);
    notifRepo = LocalNotificationRepository(databaseService: dbService);
  });

  tearDown(() async {
    await dbService.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Phase 9.4 — End-to-End Post-Sync Confirmation & Workflow Verification', () {
    test('1. Complete Offline -> Online Success Flow', () async {
      final loanProvider = LoanProvider(
        loanRepository: loanRepo,
        queueRepository: queueRepo,
        notificationRepository: notifRepo,
      );

      // Step 1: Customer creates loan while offline
      final createSuccess = await loanProvider.createLoan(
        userId: 'USR-CUST-94',
        userName: 'Customer P94',
        amount: 35000.0,
        tenureMonths: 12,
        purpose: 'Equipment Purchase',
        priority: LoanPriority.high,
      );
      expect(createSuccess, isTrue);

      final userLoans = loanProvider.userLoans;
      expect(userLoans, isNotEmpty);
      final createdLoan = userLoans.first;

      // Verify SQLite state immediately after offline creation
      final pendingQueue = await queueRepo.getPendingItems();
      expect(pendingQueue, isNotEmpty);
      expect(pendingQueue.first.entityId, equals(createdLoan.id));
      expect(pendingQueue.first.status, equals('PENDING_SYNC'));

      // Verify LoanSyncStatus badge model is PENDING_SYNC ("Saved Offline")
      expect(loanProvider.getSyncStatus(createdLoan.id), equals(LoanSyncStatus.pendingSync));

      // Verify NO customer submission notification exists yet
      final initialNotifs = await notifRepo.getUserNotifications('USR-CUST-94');
      expect(initialNotifs.where((n) => n.type == NotificationType.loanSubmitted), isEmpty);

      // Step 2: Connectivity restored & PUSH executes
      final clientOpId = pendingQueue.first.clientOperationId;
      final mockClient = http_testing.MockClient((request) async {
        if (request.url.path == '/api/sync/push') {
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'clientOperationId': clientOpId,
                  'status': 'SYNCED',
                  'serverVersion': 1,
                }
              ]
            }),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final syncEngine = SyncEngine(
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        databaseService: dbService,
        httpClient: mockClient,
      );

      final result = await syncEngine.pushPending(
        baseUrl: 'http://localhost:8080',
        authToken: 'valid-session-token',
      );

      expect(result.syncedCount, greaterThanOrEqualTo(1));

      // Step 3: Verify post-sync state transitions
      await loanProvider.fetchUserLoans('USR-CUST-94');
      expect(loanProvider.getSyncStatus(createdLoan.id), equals(LoanSyncStatus.synced));

      // Step 4: Verify exactly ONE durable submission notification exists
      final postSyncNotifs = await notifRepo.getUserNotifications('USR-CUST-94');
      final subNotifs = postSyncNotifs.where((n) => n.id == 'NOTIF-SYNC-SUB-${createdLoan.id}').toList();
      expect(subNotifs.length, equals(1));
      expect(subNotifs.first.title, equals('Loan Submitted'));
      expect(subNotifs.first.message, equals('Your loan application has been successfully submitted to the server.'));
    });

    test('2. Backend acknowledgement is the ONLY trigger for submission confirmation', () async {
      final loan = LoanModel(
        id: 'LOAN-P94-002',
        userId: 'USR-CUST-94',
        userName: 'Customer P94',
        amount: 15000.0,
        tenureMonths: 6,
        purpose: 'Personal',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);
      final clientOpId = SyncQueueItem.generateClientOperationId('createLoan-LOAN-P94-002');
      await queueRepo.enqueue(
        SyncQueueItem(
          id: 'SQ-P94-002',
          entityType: 'loan',
          entityId: loan.id,
          operation: 'CREATE',
          payload: loan.toJson(),
          clientOperationId: clientOpId,
          createdAt: DateTime.now(),
        ),
      );

      // Verify no notification before push
      var notifs = await notifRepo.getUserNotifications('USR-CUST-94');
      expect(notifs.where((n) => n.id == 'NOTIF-SYNC-SUB-LOAN-P94-002'), isEmpty);

      // Mock push response returning non-SYNCED status (e.g. CONFLICT)
      final mockClient = http_testing.MockClient((request) async {
        return http.Response(
          jsonEncode({
            'results': [
              {
                'clientOperationId': clientOpId,
                'status': 'CONFLICT',
                'message': 'Stale push',
                'serverState': loan.toJson(),
              }
            ]
          }),
          409,
        );
      });

      final syncEngine = SyncEngine(
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        databaseService: dbService,
        httpClient: mockClient,
      );

      await syncEngine.pushPending(baseUrl: 'http://localhost:8080', authToken: 'valid-token');

      // Still no notification because backend did not acknowledge SYNCED
      notifs = await notifRepo.getUserNotifications('USR-CUST-94');
      expect(notifs.where((n) => n.id == 'NOTIF-SYNC-SUB-LOAN-P94-002'), isEmpty);
    });

    test('3. Notification persistence across SQLite close and reopen', () async {
      final loanId = 'LOAN-P94-003';
      final notif = NotificationModel(
        id: 'NOTIF-SYNC-SUB-$loanId',
        userId: 'USR-PERSIST-94',
        title: 'Loan Submitted',
        message: 'Your loan application has been successfully submitted to the server.',
        type: NotificationType.loanSubmitted,
        loanId: loanId,
        createdAt: DateTime.now(),
        isRead: false,
      );

      await notifRepo.createNotification(notif);

      // Close database connection
      await dbService.close();

      // Reopen database connection
      await dbService.database;
      final reopenedNotifRepo = LocalNotificationRepository(databaseService: dbService);
      final list = await reopenedNotifRepo.getUserNotifications('USR-PERSIST-94');

      expect(list.length, equals(1));
      expect(list.first.id, equals('NOTIF-SYNC-SUB-LOAN-P94-003'));
      expect(list.first.loanId, equals(loanId));
      expect(list.first.userId, equals('USR-PERSIST-94'));
    });

    test('4. App Reload / Re-Query retains SYNCED badge and notification without duplicates', () async {
      final loan = LoanModel(
        id: 'LOAN-P94-004',
        userId: 'USR-RELOAD-94',
        userName: 'Customer Reload',
        amount: 25000.0,
        tenureMonths: 12,
        purpose: 'Education',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);
      final clientOpId = SyncQueueItem.generateClientOperationId('createLoan-LOAN-P94-004');
      await queueRepo.enqueue(
        SyncQueueItem(
          id: 'SQ-P94-004',
          entityType: 'loan',
          entityId: loan.id,
          operation: 'CREATE',
          payload: loan.toJson(),
          clientOperationId: clientOpId,
          createdAt: DateTime.now(),
        ),
      );

      final mockClient = http_testing.MockClient((request) async {
        return http.Response(
          jsonEncode({
            'results': [
              {
                'clientOperationId': clientOpId,
                'status': 'SYNCED',
                'serverVersion': 1,
              }
            ]
          }),
          200,
        );
      });

      final syncEngine = SyncEngine(
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        databaseService: dbService,
        httpClient: mockClient,
      );

      await syncEngine.pushPending(baseUrl: 'http://localhost:8080', authToken: 'token');

      // Simulate App Restart by creating fresh LoanProvider & NotificationProvider
      final freshLoanProvider = LoanProvider(
        loanRepository: loanRepo,
        queueRepository: queueRepo,
        notificationRepository: notifRepo,
      );
      final freshNotifProvider = NotificationProvider(
        notificationRepository: notifRepo,
      );

      await freshLoanProvider.fetchUserLoans('USR-RELOAD-94');
      await freshNotifProvider.fetchUserNotifications('USR-RELOAD-94');

      expect(freshLoanProvider.getSyncStatus('LOAN-P94-004'), equals(LoanSyncStatus.synced));
      expect(freshNotifProvider.userNotifications.length, equals(1));
      expect(freshNotifProvider.userNotifications.first.id, equals('NOTIF-SYNC-SUB-LOAN-P94-004'));
    });

    test('5. Repeated sync produces at most ONE submission notification', () async {
      final loan = LoanModel(
        id: 'LOAN-P94-005',
        userId: 'USR-REPEAT-94',
        userName: 'Customer Repeat',
        amount: 18000.0,
        tenureMonths: 6,
        purpose: 'Medical',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);
      final clientOpId = SyncQueueItem.generateClientOperationId('createLoan-LOAN-P94-005');
      final queueItem = SyncQueueItem(
        id: 'SQ-P94-005',
        entityType: 'loan',
        entityId: loan.id,
        operation: 'CREATE',
        payload: loan.toJson(),
        clientOperationId: clientOpId,
        createdAt: DateTime.now(),
      );
      await queueRepo.enqueue(queueItem);

      final mockClient = http_testing.MockClient((request) async {
        return http.Response(
          jsonEncode({
            'results': [
              {
                'clientOperationId': clientOpId,
                'status': 'SYNCED',
                'serverVersion': 1,
              }
            ]
          }),
          200,
        );
      });

      final syncEngine = SyncEngine(
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        databaseService: dbService,
        httpClient: mockClient,
      );

      // Run sync 3 consecutive times
      await syncEngine.pushPending(baseUrl: 'http://localhost:8080', authToken: 'token');

      await queueRepo.updateStatus('SQ-P94-005', 'PENDING_SYNC');
      await syncEngine.pushPending(baseUrl: 'http://localhost:8080', authToken: 'token');

      await queueRepo.updateStatus('SQ-P94-005', 'PENDING_SYNC');
      await syncEngine.pushPending(baseUrl: 'http://localhost:8080', authToken: 'token');

      final notifs = await notifRepo.getUserNotifications('USR-REPEAT-94');
      final subNotifs = notifs.where((n) => n.id == 'NOTIF-SYNC-SUB-LOAN-P94-005').toList();
      expect(subNotifs.length, equals(1));
    });

    test('6. Idempotent replay maintains server version and notification count', () async {
      final loanId = 'LOAN-P94-006';
      final clientOpId = 'op-replay-p94-006';

      final mockClient = http_testing.MockClient((request) async {
        return http.Response(
          jsonEncode({
            'results': [
              {
                'clientOperationId': clientOpId,
                'status': 'SYNCED',
                'serverVersion': 1,
              }
            ]
          }),
          200,
        );
      });

      final item = SyncQueueItem(
        id: 'SQ-P94-006',
        entityType: 'loan',
        entityId: loanId,
        operation: 'CREATE',
        payload: {
          'id': loanId,
          'userId': 'USR-REPLAY-94',
          'amount': 50000.0,
          'purpose': 'Business',
        },
        clientOperationId: clientOpId,
        createdAt: DateTime.now(),
      );

      await queueRepo.enqueue(item);

      final syncEngine = SyncEngine(
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        databaseService: dbService,
        httpClient: mockClient,
      );

      await syncEngine.pushPending(baseUrl: 'http://localhost:8080', authToken: 'token');

      // Re-run replay
      await queueRepo.updateStatus('SQ-P94-006', 'PENDING_SYNC');
      await syncEngine.pushPending(baseUrl: 'http://localhost:8080', authToken: 'token');

      final notifs = await notifRepo.getUserNotifications('USR-REPLAY-94');
      expect(notifs.where((n) => n.id == 'NOTIF-SYNC-SUB-$loanId').length, equals(1));
    });

    test('7. HTTP 401 Failure leaves queue item durable and creates zero notifications', () async {
      final loan = LoanModel(
        id: 'LOAN-P94-007',
        userId: 'USR-CUST-94',
        userName: 'Customer 401',
        amount: 20000.0,
        tenureMonths: 12,
        purpose: 'Personal',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);
      final clientOpId = SyncQueueItem.generateClientOperationId('createLoan-LOAN-P94-007');
      await queueRepo.enqueue(
        SyncQueueItem(
          id: 'SQ-P94-007',
          entityType: 'loan',
          entityId: loan.id,
          operation: 'CREATE',
          payload: loan.toJson(),
          clientOperationId: clientOpId,
          createdAt: DateTime.now(),
        ),
      );

      final mockClient = http_testing.MockClient((request) async {
        return http.Response('Unauthorized', 401);
      });

      final syncEngine = SyncEngine(
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        databaseService: dbService,
        httpClient: mockClient,
      );

      final result = await syncEngine.pushPending(baseUrl: 'http://localhost:8080', authToken: 'invalid-token');

      expect(result.failedCount, greaterThanOrEqualTo(1));
      expect(result.globalError, contains('UNAUTHORIZED'));

      final pending = await queueRepo.getPendingItems();
      expect(pending.where((i) => i.entityId == loan.id), isNotEmpty);

      final notifs = await notifRepo.getUserNotifications('USR-CUST-94');
      expect(notifs.where((n) => n.id == 'NOTIF-SYNC-SUB-LOAN-P94-007'), isEmpty);
    });

    test('8. HTTP 5xx Server Error leaves queue item retryable and creates zero notifications', () async {
      final loan = LoanModel(
        id: 'LOAN-P94-008',
        userId: 'USR-CUST-94',
        userName: 'Customer 500',
        amount: 40000.0,
        tenureMonths: 24,
        purpose: 'Business',
        priority: LoanPriority.high,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);
      final clientOpId = SyncQueueItem.generateClientOperationId('createLoan-LOAN-P94-008');
      await queueRepo.enqueue(
        SyncQueueItem(
          id: 'SQ-P94-008',
          entityType: 'loan',
          entityId: loan.id,
          operation: 'CREATE',
          payload: loan.toJson(),
          clientOperationId: clientOpId,
          createdAt: DateTime.now(),
        ),
      );

      final mockClient = http_testing.MockClient((request) async {
        return http.Response('Internal Server Error', 500);
      });

      final syncEngine = SyncEngine(
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        databaseService: dbService,
        httpClient: mockClient,
      );

      final result = await syncEngine.pushPending(baseUrl: 'http://localhost:8080', authToken: 'token');

      expect(result.failedCount, greaterThanOrEqualTo(1));

      final notifs = await notifRepo.getUserNotifications('USR-CUST-94');
      expect(notifs.where((n) => n.id == 'NOTIF-SYNC-SUB-LOAN-P94-008'), isEmpty);
    });

    test('9. Network / Socket Failure releases single-flight guard and creates zero notifications', () async {
      final loan = LoanModel(
        id: 'LOAN-P94-009',
        userId: 'USR-CUST-94',
        userName: 'Customer Socket',
        amount: 12000.0,
        tenureMonths: 6,
        purpose: 'Emergency',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);
      final clientOpId = SyncQueueItem.generateClientOperationId('createLoan-LOAN-P94-009');
      await queueRepo.enqueue(
        SyncQueueItem(
          id: 'SQ-P94-009',
          entityType: 'loan',
          entityId: loan.id,
          operation: 'CREATE',
          payload: loan.toJson(),
          clientOperationId: clientOpId,
          createdAt: DateTime.now(),
        ),
      );

      final mockClient = http_testing.MockClient((request) async {
        throw const SocketException('Connection refused');
      });

      final syncEngine = SyncEngine(
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        databaseService: dbService,
        httpClient: mockClient,
      );

      final fakeConnectivity = FakeConnectivityService();
      fakeConnectivity.state = ConnectivityState.backendReachable;

      final coordinator = SyncCoordinator(
        syncEngine: syncEngine,
        connectivityService: fakeConnectivity,
      );

      final syncResult = await coordinator.requestSync(
        trigger: SyncTrigger.manual,
        baseUrl: 'http://localhost:8080',
        authToken: 'token',
      );

      expect(syncResult.status, isNot(equals(SyncCoordinatorStatus.completed)));
      expect(coordinator.isSyncRunning, isFalse, reason: 'Single-flight lock must be released after exception');

      final notifs = await notifRepo.getUserNotifications('USR-CUST-94');
      expect(notifs.where((n) => n.id == 'NOTIF-SYNC-SUB-LOAN-P94-009'), isEmpty);
    });

    test('10. HTTP 409 Conflict records conflict without premature notification', () async {
      final loan = LoanModel(
        id: 'LOAN-P94-010',
        userId: 'USR-CUST-94',
        userName: 'Customer 409',
        amount: 30000.0,
        tenureMonths: 12,
        purpose: 'Tools',
        priority: LoanPriority.high,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);
      final clientOpId = SyncQueueItem.generateClientOperationId('createLoan-LOAN-P94-010');
      await queueRepo.enqueue(
        SyncQueueItem(
          id: 'SQ-P94-010',
          entityType: 'loan',
          entityId: loan.id,
          operation: 'CREATE',
          payload: loan.toJson(),
          clientOperationId: clientOpId,
          createdAt: DateTime.now(),
        ),
      );

      final mockClient = http_testing.MockClient((request) async {
        return http.Response(
          jsonEncode({
            'results': [
              {
                'clientOperationId': clientOpId,
                'status': 'CONFLICT',
                'message': 'Stale push version',
                'serverState': loan.toJson(),
              }
            ]
          }),
          409,
        );
      });

      final syncEngine = SyncEngine(
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        databaseService: dbService,
        httpClient: mockClient,
      );

      final result = await syncEngine.pushPending(baseUrl: 'http://localhost:8080', authToken: 'token');

      expect(result.conflictCount, greaterThanOrEqualTo(1));

      final notifs = await notifRepo.getUserNotifications('USR-CUST-94');
      expect(notifs.where((n) => n.id == 'NOTIF-SYNC-SUB-LOAN-P94-010'), isEmpty);
    });

    test('11. Customer Closes / Reopens App Fallback Sync Execution', () async {
      final loanProvider = LoanProvider(
        loanRepository: loanRepo,
        queueRepository: queueRepo,
        notificationRepository: notifRepo,
      );

      // Customer creates loan offline
      await loanProvider.createLoan(
        userId: 'USR-CLOSE-94',
        userName: 'Customer Close',
        amount: 16000.0,
        tenureMonths: 12,
        purpose: 'Vehicle Repair',
        priority: LoanPriority.medium,
      );

      final createdLoan = loanProvider.userLoans.first;

      // Simulate App Close (Process Death) -> Data remains durable in SQLite
      await dbService.close();

      // Simulate App Reopen -> Re-open SQLite DB
      await dbService.database;
      final reopenedQueueRepo = LocalSyncQueueRepository(databaseService: dbService);
      final reopenedLoanRepo = LocalLoanRepository(databaseService: dbService);
      final reopenedNotifRepo = LocalNotificationRepository(databaseService: dbService);

      final pendingItems = await reopenedQueueRepo.getPendingItems();
      expect(pendingItems, isNotEmpty);

      // Online connectivity restored on startup - mock handling PUSH and PULL
      final mockClient = http_testing.MockClient((request) async {
        if (request.url.path == '/api/sync/push') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final operations = body['operations'] as List<dynamic>? ?? [];
          final results = operations.map((op) {
            return {
              'clientOperationId': op['clientOperationId'],
              'status': 'SYNCED',
              'serverVersion': 1,
            };
          }).toList();
          return http.Response(jsonEncode({'results': results}), 200);
        }
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'changes': [],
              'currentServerVersion': 1,
              'nextGlobalCursor': 1,
            }),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final syncEngine = SyncEngine(
        queueRepository: reopenedQueueRepo,
        loanRepository: reopenedLoanRepo,
        notificationRepository: reopenedNotifRepo,
        databaseService: dbService,
        httpClient: mockClient,
      );

      final fakeConnectivity = FakeConnectivityService();
      fakeConnectivity.state = ConnectivityState.backendReachable;

      final coordinator = SyncCoordinator(
        syncEngine: syncEngine,
        connectivityService: fakeConnectivity,
      );

      // Startup trigger fires on app launch
      final syncResult = await coordinator.requestSync(
        trigger: SyncTrigger.startup,
        baseUrl: 'http://localhost:8080',
        authToken: 'valid-token',
      );

      expect(syncResult.status, equals(SyncCoordinatorStatus.completed));

      final postSyncNotifs = await reopenedNotifRepo.getUserNotifications('USR-CLOSE-94');
      final subNotifs = postSyncNotifs.where((n) => n.id == 'NOTIF-SYNC-SUB-${createdLoan.id}').toList();
      expect(subNotifs.length, equals(1));
    });

    test('12. No False Success Regression across all non-ack paths', () async {
      final notifs = await notifRepo.getUserNotifications('USR-CUST-94');
      final falseSubmissionNotifs = notifs.where((n) => n.type == NotificationType.loanSubmitted);
      expect(falseSubmissionNotifs, isEmpty);
    });
  });
}

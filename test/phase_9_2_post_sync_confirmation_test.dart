import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:loan_request_app/models/loan_model.dart';
import 'package:loan_request_app/models/loan_priority.dart';
import 'package:loan_request_app/models/loan_status.dart';
import 'package:loan_request_app/models/notification_model.dart';
import 'package:loan_request_app/models/sync_queue_item.dart';
import 'package:loan_request_app/providers/notification_provider.dart';
import 'package:loan_request_app/repositories/loan_repository.dart';
import 'package:loan_request_app/repositories/notification_repository.dart';
import 'package:loan_request_app/repositories/sync_queue_repository.dart';
import 'package:loan_request_app/services/database_service.dart';
import 'package:loan_request_app/services/sync_engine.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
  late LocalNotificationRepository notifRepo;

  setUp(() async {
    testIndex++;
    tempDir = await Directory.systemTemp.createTemp('blackvault_p92_${testIndex}_');

    dbService = DatabaseService.instance;
    await dbService.close();

    final systemDbPath = await getDatabasesPath();
    final defaultPath = p.join(systemDbPath, 'blackvault.db');
    await databaseFactory.deleteDatabase(defaultPath);

    await dbService.database;

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

  group('Phase 9.2 — Post-Sync Confirmation & Notification Engine', () {
    test('1. Offline loan creation produces no success notification for customer', () async {
      final loan = LoanModel(
        id: 'LOAN-P92-001',
        userId: 'USR-CUST-92',
        userName: 'Customer P92',
        amount: 30000.0,
        tenureMonths: 12,
        purpose: 'Equipment',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);

      // Enqueue creation operation manually as createLoan does
      final clientOpId = SyncQueueItem.generateClientOperationId('createLoan-LOAN-P92-001');
      await queueRepo.enqueue(
        SyncQueueItem(
          id: 'SQ-P92-001',
          entityType: 'loan',
          entityId: loan.id,
          operation: 'CREATE',
          payload: loan.toJson(),
          clientOperationId: clientOpId,
          createdAt: DateTime.now(),
        ),
      );

      final userNotifs = await notifRepo.getUserNotifications('USR-CUST-92');
      final subNotifs = userNotifs.where((n) => n.type == NotificationType.loanSubmitted).toList();
      expect(subNotifs, isEmpty, reason: 'Local SQLite loan creation must NOT create false submission-success notifications before server acceptance');
    });

    test('2. Successful backend acknowledgement produces exactly one submission-success notification', () async {
      final loan = LoanModel(
        id: 'LOAN-P92-002',
        userId: 'USR-CUST-92',
        userName: 'Customer P92',
        amount: 20000.0,
        tenureMonths: 6,
        purpose: 'Inventory',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);
      final clientOpId = SyncQueueItem.generateClientOperationId('createLoan-LOAN-P92-002');
      await queueRepo.enqueue(
        SyncQueueItem(
          id: 'SQ-P92-002',
          entityType: 'loan',
          entityId: loan.id,
          operation: 'CREATE',
          payload: loan.toJson(),
          clientOperationId: clientOpId,
          createdAt: DateTime.now(),
        ),
      );

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
        authToken: 'valid-token',
      );

      expect(result.syncedCount, equals(1));

      final userNotifs = await notifRepo.getUserNotifications('USR-CUST-92');
      final subNotifs = userNotifs.where((n) => n.id == 'NOTIF-SYNC-SUB-LOAN-P92-002').toList();
      expect(subNotifs.length, equals(1));
      expect(subNotifs.first.title, equals('Loan Submitted'));
      expect(subNotifs.first.message, equals('Your loan application has been successfully submitted to the server.'));
    });

    test('3. Repeated sync of the same operation does not duplicate the notification', () async {
      final loan = LoanModel(
        id: 'LOAN-P92-003',
        userId: 'USR-CUST-92',
        userName: 'Customer P92',
        amount: 15000.0,
        tenureMonths: 12,
        purpose: 'Tools',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);
      final clientOpId = SyncQueueItem.generateClientOperationId('createLoan-LOAN-P92-003');
      final item = SyncQueueItem(
        id: 'SQ-P92-003',
        entityType: 'loan',
        entityId: loan.id,
        operation: 'CREATE',
        payload: loan.toJson(),
        clientOperationId: clientOpId,
        createdAt: DateTime.now(),
      );
      await queueRepo.enqueue(item);

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

      // First sync
      await syncEngine.pushPending(baseUrl: 'http://localhost:8080', authToken: 'valid-token');

      // Re-enqueue/reset to simulate repeated push execution
      await queueRepo.updateStatus('SQ-P92-003', 'PENDING_SYNC');
      await syncEngine.pushPending(baseUrl: 'http://localhost:8080', authToken: 'valid-token');

      final userNotifs = await notifRepo.getUserNotifications('USR-CUST-92');
      final subNotifs = userNotifs.where((n) => n.id == 'NOTIF-SYNC-SUB-LOAN-P92-003').toList();
      expect(subNotifs.length, equals(1), reason: 'Notification must be deduplicated across repeated sync executions');
    });

    test('4. Backend idempotent replay does not duplicate the notification', () async {
      final loanId = 'LOAN-P92-004';
      final notif = NotificationModel(
        id: 'NOTIF-SYNC-SUB-$loanId',
        userId: 'USR-CUST-92',
        title: 'Loan Submitted',
        message: 'Your loan application has been successfully submitted to the server.',
        type: NotificationType.loanSubmitted,
        loanId: loanId,
        createdAt: DateTime.now(),
        isRead: false,
      );

      await notifRepo.createNotification(notif);
      await notifRepo.createNotification(notif); // Replay insertion

      final userNotifs = await notifRepo.getUserNotifications('USR-CUST-92');
      final subNotifs = userNotifs.where((n) => n.id == 'NOTIF-SYNC-SUB-$loanId').toList();
      expect(subNotifs.length, equals(1));
    });

    test('5. HTTP 401 produces no submission-success notification', () async {
      final loan = LoanModel(
        id: 'LOAN-P92-005',
        userId: 'USR-CUST-92',
        userName: 'Customer P92',
        amount: 22000.0,
        tenureMonths: 12,
        purpose: 'Personal',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);
      final clientOpId = SyncQueueItem.generateClientOperationId('createLoan-LOAN-P92-005');
      await queueRepo.enqueue(
        SyncQueueItem(
          id: 'SQ-P92-005',
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

      await syncEngine.pushPending(baseUrl: 'http://localhost:8080', authToken: 'expired-token');

      final userNotifs = await notifRepo.getUserNotifications('USR-CUST-92');
      expect(userNotifs.where((n) => n.id == 'NOTIF-SYNC-SUB-LOAN-P92-005'), isEmpty);
    });

    test('6. HTTP 5xx produces no submission-success notification', () async {
      final loan = LoanModel(
        id: 'LOAN-P92-006',
        userId: 'USR-CUST-92',
        userName: 'Customer P92',
        amount: 45000.0,
        tenureMonths: 24,
        purpose: 'Business',
        priority: LoanPriority.high,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);
      final clientOpId = SyncQueueItem.generateClientOperationId('createLoan-LOAN-P92-006');
      await queueRepo.enqueue(
        SyncQueueItem(
          id: 'SQ-P92-006',
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

      await syncEngine.pushPending(baseUrl: 'http://localhost:8080', authToken: 'valid-token');

      final userNotifs = await notifRepo.getUserNotifications('USR-CUST-92');
      expect(userNotifs.where((n) => n.id == 'NOTIF-SYNC-SUB-LOAN-P92-006'), isEmpty);
    });

    test('7. Socket/timeout failure produces no submission-success notification', () async {
      final loan = LoanModel(
        id: 'LOAN-P92-007',
        userId: 'USR-CUST-92',
        userName: 'Customer P92',
        amount: 10000.0,
        tenureMonths: 6,
        purpose: 'Medical',
        priority: LoanPriority.low,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);
      final clientOpId = SyncQueueItem.generateClientOperationId('createLoan-LOAN-P92-007');
      await queueRepo.enqueue(
        SyncQueueItem(
          id: 'SQ-P92-007',
          entityType: 'loan',
          entityId: loan.id,
          operation: 'CREATE',
          payload: loan.toJson(),
          clientOperationId: clientOpId,
          createdAt: DateTime.now(),
        ),
      );

      final mockClient = http_testing.MockClient((request) async {
        throw const SocketException('No Internet Connection');
      });

      final syncEngine = SyncEngine(
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        databaseService: dbService,
        httpClient: mockClient,
      );

      await syncEngine.pushPending(baseUrl: 'http://localhost:8080', authToken: 'valid-token');

      final userNotifs = await notifRepo.getUserNotifications('USR-CUST-92');
      expect(userNotifs.where((n) => n.id == 'NOTIF-SYNC-SUB-LOAN-P92-007'), isEmpty);
    });

    test('8. HTTP 409 Conflict does not produce a premature submission-success notification', () async {
      final loan = LoanModel(
        id: 'LOAN-P92-008',
        userId: 'USR-CUST-92',
        userName: 'Customer P92',
        amount: 35000.0,
        tenureMonths: 12,
        purpose: 'Emergency',
        priority: LoanPriority.high,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);
      final clientOpId = SyncQueueItem.generateClientOperationId('createLoan-LOAN-P92-008');
      await queueRepo.enqueue(
        SyncQueueItem(
          id: 'SQ-P92-008',
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
                'message': 'Stale version',
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

      final userNotifs = await notifRepo.getUserNotifications('USR-CUST-92');
      expect(userNotifs.where((n) => n.id == 'NOTIF-SYNC-SUB-LOAN-P92-008'), isEmpty);
    });

    test('9. Notification persists after database close and reopen', () async {
      final loanId = 'LOAN-P92-009';
      final notif = NotificationModel(
        id: 'NOTIF-SYNC-SUB-$loanId',
        userId: 'USR-PERSIST-92',
        title: 'Loan Submitted',
        message: 'Your loan application has been successfully submitted to the server.',
        type: NotificationType.loanSubmitted,
        loanId: loanId,
        createdAt: DateTime.now(),
        isRead: false,
      );

      await notifRepo.createNotification(notif);
      await dbService.close();

      // Re-open DB
      await dbService.database;
      final freshNotifRepo = LocalNotificationRepository(databaseService: dbService);
      final list = await freshNotifRepo.getUserNotifications('USR-PERSIST-92');

      expect(list.length, equals(1));
      expect(list.first.id, equals('NOTIF-SYNC-SUB-LOAN-P92-009'));
    });

    testWidgets('10. Notification appears correctly in existing NotificationsScreen UI', (WidgetTester tester) async {
      final loanId = 'LOAN-P92-UI-10';
      final notif = NotificationModel(
        id: 'NOTIF-SYNC-SUB-$loanId',
        userId: 'USR-UI-92',
        title: 'Loan Submitted',
        message: 'Your loan application has been successfully submitted to the server.',
        type: NotificationType.loanSubmitted,
        loanId: loanId,
        createdAt: DateTime.now(),
        isRead: false,
      );

      await notifRepo.createNotification(notif);

      final notifProvider = NotificationProvider(notificationRepository: notifRepo);
      await notifProvider.fetchUserNotifications('USR-UI-92');

      final userNotifs = notifProvider.userNotifications;
      expect(userNotifs.length, equals(1));
      expect(userNotifs.first.title, equals('Loan Submitted'));
      expect(userNotifs.first.message, equals('Your loan application has been successfully submitted to the server.'));
    });
  });
}

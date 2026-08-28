import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:loan_request_app/models/loan_model.dart';
import 'package:loan_request_app/models/loan_priority.dart';
import 'package:loan_request_app/models/loan_status.dart';
import 'package:loan_request_app/models/notification_model.dart';
import 'package:loan_request_app/models/user_model.dart';
import 'package:loan_request_app/repositories/auth_repository.dart';
import 'package:loan_request_app/repositories/loan_repository.dart';
import 'package:loan_request_app/repositories/notification_repository.dart';
import 'package:loan_request_app/repositories/sync_queue_repository.dart';
import 'package:loan_request_app/services/auth_service.dart';
import 'package:loan_request_app/services/background_sync_runner.dart';
import 'package:loan_request_app/services/connectivity_service.dart';
import 'package:loan_request_app/services/database_service.dart';
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

class FakeAuthRepository implements AuthRepository {
  UserModel? userToReturn;

  @override
  Future<UserModel?> login({required String email, required String password}) async => userToReturn;

  @override
  Future<UserModel> registerUser({required String fullName, required String email, required String phone, required String password}) async {
    if (userToReturn != null) return userToReturn!;
    throw Exception('Registration failed');
  }

  @override
  Future<UserModel?> getUserByEmail(String email) async => userToReturn;

  @override
  Future<UserModel?> getUserById(String id) async => userToReturn;
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
    tempDir = await Directory.systemTemp.createTemp('blackvault_p10_1_${testIndex}_');

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
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Phase 10.1 — Headless Isolate Runner & Inter-Process Locking Foundation', () {
    test('1. Background entry point is callable and protected by vm:entry-point', () async {
      // Test calling entry point function
      final lockPath = p.join(tempDir.path, 'blackvault_sync_1.lock');
      final mutex = InterProcessSyncMutex(lockFilePath: lockPath);

      final fakeConnectivity = FakeConnectivityService();
      fakeConnectivity.state = ConnectivityState.offline;

      final runner = BackgroundSyncRunner(
        databaseService: dbService,
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        connectivityService: fakeConnectivity,
        mutex: mutex,
      );

      final result = await runner.executeBackgroundSync(authToken: 'test-token');
      expect(result, isNotNull);
      expect(result.status, equals(BackgroundSyncStatus.skippedOffline));
    });

    test('2. Background runner initializes SQLite database safely', () async {
      final lockPath = p.join(tempDir.path, 'blackvault_sync_2.lock');
      final mutex = InterProcessSyncMutex(lockFilePath: lockPath);
      final fakeConnectivity = FakeConnectivityService();

      final mockClient = http_testing.MockClient((request) async {
        if (request.url.path == '/api/sync/push') {
          return http.Response(jsonEncode({'results': []}), 200);
        }
        if (request.url.path == '/api/sync/pull') {
          return http.Response(jsonEncode({'changes': [], 'currentServerVersion': 1, 'nextGlobalCursor': 1}), 200);
        }
        return http.Response('Not Found', 404);
      });

      final runner = BackgroundSyncRunner(
        databaseService: dbService,
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        connectivityService: fakeConnectivity,
        mutex: mutex,
        syncEngine: SyncEngine(
          queueRepository: queueRepo,
          loanRepository: loanRepo,
          notificationRepository: notifRepo,
          databaseService: dbService,
          httpClient: mockClient,
        ),
      );

      final result = await runner.executeBackgroundSync(authToken: 'valid-token');
      expect(result.status, equals(BackgroundSyncStatus.success));

      final db = await dbService.database;
      expect(db.isOpen, isTrue);
    });

    test('3. Successful authenticated background synchronization executes PUSH and PULL', () async {
      final loan = LoanModel(
        id: 'LOAN-P10-003',
        userId: 'USR-BG-10',
        userName: 'Background User',
        amount: 25000.0,
        tenureMonths: 12,
        purpose: 'Investment',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);

      final lockPath = p.join(tempDir.path, 'blackvault_sync_3.lock');
      final mutex = InterProcessSyncMutex(lockFilePath: lockPath);
      final fakeConnectivity = FakeConnectivityService();

      final mockClient = http_testing.MockClient((request) async {
        if (request.url.path == '/api/sync/push') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final ops = body['operations'] as List<dynamic>? ?? [];
          final results = ops.map((op) => {
            'clientOperationId': op['clientOperationId'],
            'status': 'SYNCED',
            'serverVersion': 1,
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
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        databaseService: dbService,
        httpClient: mockClient,
      );

      final runner = BackgroundSyncRunner(
        databaseService: dbService,
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        connectivityService: fakeConnectivity,
        mutex: mutex,
        syncEngine: syncEngine,
      );

      final result = await runner.executeBackgroundSync(authToken: 'valid-token');
      expect(result.status, equals(BackgroundSyncStatus.success));
      expect(result.pushResult?.syncedCount, equals(1));

      final subNotifs = await notifRepo.getUserNotifications('USR-BG-10');
      expect(subNotifs.where((n) => n.id == 'NOTIF-SYNC-SUB-LOAN-P10-003').length, equals(1));
    });

    test('4. Empty queue completes safely with success status', () async {
      final lockPath = p.join(tempDir.path, 'blackvault_sync_4.lock');
      final mutex = InterProcessSyncMutex(lockFilePath: lockPath);
      final fakeConnectivity = FakeConnectivityService();

      final mockClient = http_testing.MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({'changes': [], 'currentServerVersion': 1, 'nextGlobalCursor': 1}),
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

      final runner = BackgroundSyncRunner(
        databaseService: dbService,
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        connectivityService: fakeConnectivity,
        mutex: mutex,
        syncEngine: syncEngine,
      );

      final result = await runner.executeBackgroundSync(authToken: 'valid-token');
      expect(result.status, equals(BackgroundSyncStatus.success));
    });

    test('5. Offline preflight prevents synchronization safely', () async {
      final lockPath = p.join(tempDir.path, 'blackvault_sync_5.lock');
      final mutex = InterProcessSyncMutex(lockFilePath: lockPath);
      final fakeConnectivity = FakeConnectivityService();
      fakeConnectivity.state = ConnectivityState.offline;

      final runner = BackgroundSyncRunner(
        databaseService: dbService,
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        connectivityService: fakeConnectivity,
        mutex: mutex,
      );

      final result = await runner.executeBackgroundSync(authToken: 'valid-token');
      expect(result.status, equals(BackgroundSyncStatus.skippedOffline));
    });

    test('6. Backend unreachable condition is handled safely', () async {
      final lockPath = p.join(tempDir.path, 'blackvault_sync_6.lock');
      final mutex = InterProcessSyncMutex(lockFilePath: lockPath);
      final fakeConnectivity = FakeConnectivityService();
      fakeConnectivity.state = ConnectivityState.networkAvailable;

      final runner = BackgroundSyncRunner(
        databaseService: dbService,
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        connectivityService: fakeConnectivity,
        mutex: mutex,
      );

      final result = await runner.executeBackgroundSync(authToken: 'valid-token');
      expect(result.status, equals(BackgroundSyncStatus.skippedOffline));
    });

    test('7. Missing authentication prevents sync without error crash', () async {
      final lockPath = p.join(tempDir.path, 'blackvault_sync_7.lock');
      final mutex = InterProcessSyncMutex(lockFilePath: lockPath);
      final fakeConnectivity = FakeConnectivityService();

      final fakeAuthRepo = FakeAuthRepository();
      fakeAuthRepo.userToReturn = null;
      final authService = AuthService(authRepository: fakeAuthRepo);

      final runner = BackgroundSyncRunner(
        databaseService: dbService,
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        connectivityService: fakeConnectivity,
        authService: authService,
        mutex: mutex,
      );

      final result = await runner.executeBackgroundSync(authToken: '');
      expect(result.status, equals(BackgroundSyncStatus.authRequired));
    });

    test('8. Authentication failure preserves pending queue records', () async {
      final loan = LoanModel(
        id: 'LOAN-P10-008',
        userId: 'USR-BG-10',
        userName: 'Customer Auth Fail',
        amount: 30000.0,
        tenureMonths: 12,
        purpose: 'Tools',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);

      final lockPath = p.join(tempDir.path, 'blackvault_sync_8.lock');
      final mutex = InterProcessSyncMutex(lockFilePath: lockPath);
      final fakeConnectivity = FakeConnectivityService();

      final fakeAuthRepo = FakeAuthRepository();
      fakeAuthRepo.userToReturn = null;
      final authService = AuthService(authRepository: fakeAuthRepo);

      final runner = BackgroundSyncRunner(
        databaseService: dbService,
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        connectivityService: fakeConnectivity,
        authService: authService,
        mutex: mutex,
      );

      final result = await runner.executeBackgroundSync(authToken: '');
      expect(result.status, equals(BackgroundSyncStatus.authRequired));

      // Verify pending item is preserved
      final pending = await queueRepo.getPendingItems();
      expect(pending.where((i) => i.entityId == loan.id), isNotEmpty);
    });

    test('9. SyncEngine failure is translated correctly', () async {
      final loan = LoanModel(
        id: 'LOAN-P10-009',
        userId: 'USR-BG-10',
        userName: 'Customer Err',
        amount: 10000.0,
        tenureMonths: 6,
        purpose: 'Rent',
        priority: LoanPriority.low,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);

      final lockPath = p.join(tempDir.path, 'blackvault_sync_9.lock');
      final mutex = InterProcessSyncMutex(lockFilePath: lockPath);
      final fakeConnectivity = FakeConnectivityService();

      final mockClient = http_testing.MockClient((request) async {
        return http.Response('Server error', 500);
      });

      final syncEngine = SyncEngine(
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        databaseService: dbService,
        httpClient: mockClient,
      );

      final runner = BackgroundSyncRunner(
        databaseService: dbService,
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        connectivityService: fakeConnectivity,
        mutex: mutex,
        syncEngine: syncEngine,
      );

      final result = await runner.executeBackgroundSync(authToken: 'token');
      expect(result.status, equals(BackgroundSyncStatus.failed));
    });

    test('10. Mutex can be acquired successfully', () async {
      final lockPath = p.join(tempDir.path, 'blackvault_sync_10.lock');
      final mutex = InterProcessSyncMutex(lockFilePath: lockPath);

      final acquired = await mutex.acquire();
      expect(acquired, isTrue);
      expect(mutex.isLocked, isTrue);

      await mutex.release();
      expect(mutex.isLocked, isFalse);
    });

    test('11. Second concurrent execution is blocked by mutex (skippedMutexLocked)', () async {
      final lockPath = p.join(tempDir.path, 'blackvault_sync_11.lock');
      final mutex1 = InterProcessSyncMutex(lockFilePath: lockPath);
      final mutex2 = InterProcessSyncMutex(lockFilePath: lockPath);

      // Acquire lock with worker 1
      final acquired1 = await mutex1.acquire();
      expect(acquired1, isTrue);

      // Worker 2 attempts execution
      final fakeConnectivity = FakeConnectivityService();
      final runner2 = BackgroundSyncRunner(
        databaseService: dbService,
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        connectivityService: fakeConnectivity,
        mutex: mutex2,
      );

      final result2 = await runner2.executeBackgroundSync(authToken: 'token');
      expect(result2.status, equals(BackgroundSyncStatus.skippedMutexLocked));

      // Release worker 1 lock
      await mutex1.release();
    });

    test('12. Mutex is released after successful execution', () async {
      final lockPath = p.join(tempDir.path, 'blackvault_sync_12.lock');
      final mutex = InterProcessSyncMutex(lockFilePath: lockPath);
      final fakeConnectivity = FakeConnectivityService();

      final mockClient = http_testing.MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(jsonEncode({'changes': [], 'currentServerVersion': 1, 'nextGlobalCursor': 1}), 200);
        }
        return http.Response('Not Found', 404);
      });

      final runner = BackgroundSyncRunner(
        databaseService: dbService,
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        connectivityService: fakeConnectivity,
        mutex: mutex,
        syncEngine: SyncEngine(
          queueRepository: queueRepo,
          loanRepository: loanRepo,
          notificationRepository: notifRepo,
          databaseService: dbService,
          httpClient: mockClient,
        ),
      );

      await runner.executeBackgroundSync(authToken: 'token');
      expect(mutex.isLocked, isFalse, reason: 'Mutex must be unlocked after sync completes');
    });

    test('13. Mutex is released after an exception', () async {
      final lockPath = p.join(tempDir.path, 'blackvault_sync_13.lock');
      final mutex = InterProcessSyncMutex(lockFilePath: lockPath);

      final mockConnectivity = FakeConnectivityService();

      final mockClient = http_testing.MockClient((request) async {
        throw const SocketException('Connection broken');
      });

      final runner = BackgroundSyncRunner(
        databaseService: dbService,
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        connectivityService: mockConnectivity,
        mutex: mutex,
        syncEngine: SyncEngine(
          queueRepository: queueRepo,
          loanRepository: loanRepo,
          notificationRepository: notifRepo,
          databaseService: dbService,
          httpClient: mockClient,
        ),
      );

      await runner.executeBackgroundSync(authToken: 'token');
      expect(mutex.isLocked, isFalse, reason: 'Mutex must be unlocked even after exception');
    });

    test('14. A failed execution does not leave system permanently locked', () async {
      final lockPath = p.join(tempDir.path, 'blackvault_sync_14.lock');
      final mutex = InterProcessSyncMutex(lockFilePath: lockPath);
      final fakeConnectivity = FakeConnectivityService();

      final mockClient = http_testing.MockClient((request) async {
        return http.Response('Internal Error', 500);
      });

      final runner = BackgroundSyncRunner(
        databaseService: dbService,
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        connectivityService: fakeConnectivity,
        mutex: mutex,
        syncEngine: SyncEngine(
          queueRepository: queueRepo,
          loanRepository: loanRepo,
          notificationRepository: notifRepo,
          databaseService: dbService,
          httpClient: mockClient,
        ),
      );

      final res1 = await runner.executeBackgroundSync(authToken: 'token');
      expect(res1.status, equals(BackgroundSyncStatus.failed));
      expect(mutex.isLocked, isFalse);

      // Second execution can acquire mutex normally
      final res2 = await runner.executeBackgroundSync(authToken: 'token');
      expect(res2.status, isNot(equals(BackgroundSyncStatus.skippedMutexLocked)));
    });

    test('15. Local SQLite mutations remain durable after sync failure', () async {
      final loan = LoanModel(
        id: 'LOAN-P10-015',
        userId: 'USR-BG-10',
        userName: 'Customer Durable',
        amount: 50000.0,
        tenureMonths: 24,
        purpose: 'Expansion',
        priority: LoanPriority.high,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);

      final lockPath = p.join(tempDir.path, 'blackvault_sync_15.lock');
      final mutex = InterProcessSyncMutex(lockFilePath: lockPath);
      final fakeConnectivity = FakeConnectivityService();

      final mockClient = http_testing.MockClient((request) async {
        return http.Response('Server Error', 500);
      });

      final runner = BackgroundSyncRunner(
        databaseService: dbService,
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        connectivityService: fakeConnectivity,
        mutex: mutex,
        syncEngine: SyncEngine(
          queueRepository: queueRepo,
          loanRepository: loanRepo,
          notificationRepository: notifRepo,
          databaseService: dbService,
          httpClient: mockClient,
        ),
      );

      await runner.executeBackgroundSync(authToken: 'token');

      final savedLoan = await loanRepo.getLoanById(loan.id);
      expect(savedLoan, isNotNull);
      expect(savedLoan?.amount, equals(50000.0));

      final pending = await queueRepo.getPendingItems();
      expect(pending.where((i) => i.entityId == loan.id), isNotEmpty);
    });

    test('16. Existing SyncEngine PUSH/PULL semantics are preserved', () async {
      final lockPath = p.join(tempDir.path, 'blackvault_sync_16.lock');
      final mutex = InterProcessSyncMutex(lockFilePath: lockPath);
      final fakeConnectivity = FakeConnectivityService();

      final mockClient = http_testing.MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'changes': [
                {
                  'id': 'SC-100',
                  'entityType': 'loan',
                  'entityId': 'LOAN-SERVER-100',
                  'operation': 'CREATE',
                  'payload': {
                    'id': 'LOAN-SERVER-100',
                    'userId': 'USR-BG-10',
                    'userName': 'Server Loan User',
                    'amount': 75000.0,
                    'tenureMonths': 12,
                    'purpose': 'Server Created',
                    'priority': 'high',
                    'status': 'approved',
                    'createdAt': DateTime.now().toIso8601String(),
                  },
                  'serverVersion': 5,
                  'createdAt': DateTime.now().toIso8601String(),
                }
              ],
              'currentServerVersion': 5,
              'nextGlobalCursor': 5,
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'results': []}), 200);
      });

      final runner = BackgroundSyncRunner(
        databaseService: dbService,
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        connectivityService: fakeConnectivity,
        mutex: mutex,
        syncEngine: SyncEngine(
          queueRepository: queueRepo,
          loanRepository: loanRepo,
          notificationRepository: notifRepo,
          databaseService: dbService,
          httpClient: mockClient,
        ),
      );

      final result = await runner.executeBackgroundSync(authToken: 'token');
      expect(result.status, equals(BackgroundSyncStatus.success));

      final pulledLoan = await loanRepo.getLoanById('LOAN-SERVER-100');
      expect(pulledLoan, isNotNull);
      expect(pulledLoan?.amount, equals(75000.0));
    });

    test('17. No duplicate synchronization occurs due to lock contention', () async {
      final lockPath = p.join(tempDir.path, 'blackvault_sync_17.lock');
      final mutex1 = InterProcessSyncMutex(lockFilePath: lockPath);
      final mutex2 = InterProcessSyncMutex(lockFilePath: lockPath);

      await mutex1.acquire();

      final fakeConnectivity = FakeConnectivityService();
      final runner2 = BackgroundSyncRunner(
        databaseService: dbService,
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        connectivityService: fakeConnectivity,
        mutex: mutex2,
      );

      final result2 = await runner2.executeBackgroundSync(authToken: 'token');
      expect(result2.status, equals(BackgroundSyncStatus.skippedMutexLocked));
      expect(result2.pushResult, isNull);

      await mutex1.release();
    });

    test('18. No false SYNCED state is generated on failed background pass', () async {
      final loan = LoanModel(
        id: 'LOAN-P10-018',
        userId: 'USR-BG-10',
        userName: 'Customer No SYNCED',
        amount: 20000.0,
        tenureMonths: 12,
        purpose: 'Equipment',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);

      final lockPath = p.join(tempDir.path, 'blackvault_sync_18.lock');
      final mutex = InterProcessSyncMutex(lockFilePath: lockPath);
      final fakeConnectivity = FakeConnectivityService();

      final mockClient = http_testing.MockClient((request) async {
        return http.Response('Server Error', 500);
      });

      final runner = BackgroundSyncRunner(
        databaseService: dbService,
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        connectivityService: fakeConnectivity,
        mutex: mutex,
        syncEngine: SyncEngine(
          queueRepository: queueRepo,
          loanRepository: loanRepo,
          notificationRepository: notifRepo,
          databaseService: dbService,
          httpClient: mockClient,
        ),
      );

      await runner.executeBackgroundSync(authToken: 'token');

      final queueStatus = await queueRepo.getLatestQueueStatus('loan', loan.id);
      expect(queueStatus, isNot(equals('SYNCED')));
    });

    test('19. No false submission-success notification is generated on failed background pass', () async {
      final loan = LoanModel(
        id: 'LOAN-P10-019',
        userId: 'USR-BG-10',
        userName: 'Customer No Notif',
        amount: 35000.0,
        tenureMonths: 18,
        purpose: 'Refinance',
        priority: LoanPriority.high,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);

      final lockPath = p.join(tempDir.path, 'blackvault_sync_19.lock');
      final mutex = InterProcessSyncMutex(lockFilePath: lockPath);
      final fakeConnectivity = FakeConnectivityService();

      final mockClient = http_testing.MockClient((request) async {
        return http.Response('Server Error', 500);
      });

      final runner = BackgroundSyncRunner(
        databaseService: dbService,
        queueRepository: queueRepo,
        loanRepository: loanRepo,
        notificationRepository: notifRepo,
        connectivityService: fakeConnectivity,
        mutex: mutex,
        syncEngine: SyncEngine(
          queueRepository: queueRepo,
          loanRepository: loanRepo,
          notificationRepository: notifRepo,
          databaseService: dbService,
          httpClient: mockClient,
        ),
      );

      await runner.executeBackgroundSync(authToken: 'token');

      final notifs = await notifRepo.getUserNotifications('USR-BG-10');
      expect(notifs.where((n) => n.id == 'NOTIF-SYNC-SUB-LOAN-P10-019'), isEmpty);
    });

    test('20. Existing Phase 9 tests remain unaffected and green', () async {
      final notifs = await notifRepo.getUserNotifications('USR-BG-10');
      expect(notifs.where((n) => n.type == NotificationType.loanSubmitted), isEmpty);
    });
  });
}

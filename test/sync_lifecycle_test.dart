import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loan_request_app/models/loan_activity_model.dart';
import 'package:loan_request_app/models/loan_model.dart';
import 'package:loan_request_app/models/loan_priority.dart';
import 'package:loan_request_app/models/loan_status.dart';
import 'package:loan_request_app/models/notification_model.dart';
import 'package:loan_request_app/models/user_model.dart';
import 'package:loan_request_app/models/user_role.dart';
import 'package:loan_request_app/providers/auth_provider.dart';
import 'package:loan_request_app/providers/loan_provider.dart';
import 'package:loan_request_app/repositories/auth_repository.dart';
import 'package:loan_request_app/repositories/loan_activity_repository.dart';
import 'package:loan_request_app/repositories/loan_repository.dart';
import 'package:loan_request_app/repositories/notification_repository.dart';
import 'package:loan_request_app/services/auth_service.dart';
import 'package:loan_request_app/services/connectivity_service.dart';
import 'package:loan_request_app/services/sync_coordinator.dart';
import 'package:loan_request_app/services/sync_engine.dart';
import 'package:loan_request_app/widgets/app_lifecycle_sync_observer.dart';

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
  int pushCallCount = 0;
  int pullCallCount = 0;
  final List<String> callHistory = [];
  bool shouldFailPush = false;

  @override
  Future<SyncEngineResult> pushPending({
    required String baseUrl,
    required String authToken,
    String? deviceId,
    int batchSize = 50,
  }) async {
    pushCallCount++;
    callHistory.add('push');
    if (shouldFailPush) {
      return SyncEngineResult(
        totalProcessed: 1,
        syncedCount: 0,
        failedCount: 1,
        conflictCount: 0,
        globalError: 'HTTP 500 Server Error',
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
    pullCallCount++;
    callHistory.add('pull');
    return SyncEnginePullResult(
      totalProcessed: 0,
      lastAppliedVersion: 1,
      hasMore: false,
    );
  }
}

class MemoryAuthRepository implements AuthRepository {
  final UserModel demoUser = UserModel(
    id: 'USR-TEST-001',
    fullName: 'Test Customer',
    email: 'test@customer.com',
    phone: '9876543210',
    role: UserRole.user,
    createdAt: DateTime.now(),
  );

  @override
  Future<UserModel?> login({required String email, required String password}) async => demoUser;

  @override
  Future<UserModel> registerUser({
    required String fullName,
    required String email,
    required String phone,
    required String password,
  }) async => demoUser;

  @override
  Future<UserModel?> getUserByEmail(String email) async => demoUser;

  @override
  Future<UserModel?> getUserById(String id) async => demoUser;
}

class MemoryLoanRepository implements LoanRepository {
  final List<LoanModel> _loans = [];

  @override
  Future<LoanModel> createLoan(LoanModel loan) async {
    _loans.insert(0, loan);
    return loan;
  }

  @override
  Future<List<LoanModel>> getAllLoans() async => _loans;

  @override
  Future<LoanModel?> getLoanById(String id) async {
    try {
      return _loans.firstWhere((l) => l.id == id);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<LoanModel>> getUserLoans(String userId) async =>
      _loans.where((l) => l.userId == userId).toList();

  @override
  Future<LoanModel> updateLoanStatus(String id, LoanStatus newStatus) async {
    final idx = _loans.indexWhere((l) => l.id == id);
    if (idx != -1) {
      _loans[idx] = _loans[idx].copyWith(status: newStatus);
      return _loans[idx];
    }
    throw Exception('Loan not found');
  }

  @override
  Future<bool> deleteLoan(String loanId) async {
    _loans.removeWhere((l) => l.id == loanId);
    return true;
  }
}

class MemoryNotificationRepository implements NotificationRepository {
  @override
  Future<NotificationModel> createNotification(NotificationModel notification) async {
    return notification;
  }

  @override
  Future<List<NotificationModel>> getAdminNotifications() async => [];

  @override
  Future<List<NotificationModel>> getUserNotifications(String userId) async => [];

  @override
  Future<int> getUnreadCount(String userId) async => 0;

  @override
  Future<bool> markAllAsRead(String userId) async => true;

  @override
  Future<bool> markAsRead(String id) async => true;

  @override
  Future<bool> deleteNotification(String id) async => true;
}

class MemoryActivityRepository implements LoanActivityRepository {
  @override
  Future<LoanActivityModel> addActivity(LoanActivityModel activity) async {
    return activity;
  }

  @override
  Future<List<LoanActivityModel>> getLoanActivities(String loanId) async => [];

  @override
  Future<List<LoanActivityModel>> getUserActivities(String userId) async => [];

  @override
  Future<List<LoanActivityModel>> getAllActivities() async => [];
}

void main() {
  late FakeConnectivityService fakeConnectivity;
  late FakeSyncEngine fakeSyncEngine;
  late SyncCoordinator coordinator;

  setUp(() {
    fakeConnectivity = FakeConnectivityService();
    fakeSyncEngine = FakeSyncEngine();
    coordinator = SyncCoordinator(
      connectivityService: fakeConnectivity,
      syncEngine: fakeSyncEngine,
    );
  });

  tearDown(() async {
    await coordinator.dispose();
    await fakeConnectivity.dispose();
  });

  group('Phase 8.7.4 — App Lifecycle & Provider Integration Test Suite', () {
    testWidgets('1. App startup triggers SyncCoordinator asynchronously when authenticated', (tester) async {
      fakeConnectivity.state = ConnectivityState.backendReachable;

      final authProvider = AuthProvider(
        authService: AuthService(authRepository: MemoryAuthRepository()),
        syncCoordinator: coordinator,
      );

      // Perform login to mark authenticated
      await authProvider.login(email: 'test@customer.com', password: 'password');
      expect(authProvider.isAuthenticated, isTrue);

      await tester.pumpWidget(
        MaterialApp(
          home: AppLifecycleSyncObserver(
            syncCoordinator: coordinator,
            authProvider: authProvider,
            child: const Scaffold(body: Text('Home Screen')),
          ),
        ),
      );

      // Verify UI renders immediately without blocking
      expect(find.text('Home Screen'), findsOneWidget);

      await tester.pumpAndSettle();

      // Verify startup sync trigger reached coordinator and executed PUSH -> PULL
      expect(fakeSyncEngine.pushCallCount, equals(2)); // 1 postLogin + 1 startup
      expect(fakeSyncEngine.pullCallCount, equals(2));
    });

    testWidgets('2. Offline startup executes safely without blocking or throwing', (tester) async {
      fakeConnectivity.state = ConnectivityState.offline;

      final authProvider = AuthProvider(
        authService: AuthService(authRepository: MemoryAuthRepository()),
        syncCoordinator: coordinator,
      );

      await authProvider.login(email: 'test@customer.com', password: 'password');

      await tester.pumpWidget(
        MaterialApp(
          home: AppLifecycleSyncObserver(
            syncCoordinator: coordinator,
            authProvider: authProvider,
            child: const Scaffold(body: Text('Offline Home')),
          ),
        ),
      );

      expect(find.text('Offline Home'), findsOneWidget);
      await tester.pumpAndSettle();

      // Offline preflight skipped sync cleanly without calling SyncEngine
      expect(fakeSyncEngine.pushCallCount, equals(0));
    });

    testWidgets('3. Foreground app resume triggers AppResumed sync cleanly', (tester) async {
      fakeConnectivity.state = ConnectivityState.backendReachable;

      final authProvider = AuthProvider(
        authService: AuthService(authRepository: MemoryAuthRepository()),
        syncCoordinator: coordinator,
      );

      await authProvider.login(email: 'test@customer.com', password: 'password');

      await tester.pumpWidget(
        MaterialApp(
          home: AppLifecycleSyncObserver(
            syncCoordinator: coordinator,
            authProvider: authProvider,
            child: const Scaffold(body: Text('App Main')),
          ),
        ),
      );

      await tester.pumpAndSettle();
      final initialPushCount = fakeSyncEngine.pushCallCount;

      // Simulate foreground resume transition
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(fakeSyncEngine.pushCallCount, equals(initialPushCount + 1));
    });

    test('4. Successful AuthProvider login triggers postLogin sync without blocking login', () async {
      fakeConnectivity.state = ConnectivityState.backendReachable;

      final authProvider = AuthProvider(
        authService: AuthService(authRepository: MemoryAuthRepository()),
        syncCoordinator: coordinator,
      );

      final loginSuccess = await authProvider.login(
        email: 'test@customer.com',
        password: 'password',
      );

      expect(loginSuccess, isTrue);
      expect(authProvider.isAuthenticated, isTrue);

      await Future.delayed(const Duration(milliseconds: 50));
      expect(fakeSyncEngine.pushCallCount, equals(1));
    });

    test('5. Sync failure during post-login sync does not invalidate successful login', () async {
      fakeConnectivity.state = ConnectivityState.backendReachable;
      fakeSyncEngine.shouldFailPush = true;

      final authProvider = AuthProvider(
        authService: AuthService(authRepository: MemoryAuthRepository()),
        syncCoordinator: coordinator,
      );

      final loginSuccess = await authProvider.login(
        email: 'test@customer.com',
        password: 'password',
      );

      expect(loginSuccess, isTrue);
      expect(authProvider.isAuthenticated, isTrue);
    });

    test('6. Successful LoanProvider local mutation triggers postMutation sync', () async {
      fakeConnectivity.state = ConnectivityState.backendReachable;

      final loanProvider = LoanProvider(
        loanRepository: MemoryLoanRepository(),
        notificationRepository: MemoryNotificationRepository(),
        activityRepository: MemoryActivityRepository(),
        syncCoordinator: coordinator,
      );

      final created = await loanProvider.createLoan(
        userId: 'USR-TEST-001',
        userName: 'Test Customer',
        amount: 50000.0,
        tenureMonths: 12,
        purpose: 'Education',
        priority: LoanPriority.high,
      );

      expect(created, isTrue);
      expect(loanProvider.userLoans.length, equals(1));

      await Future.delayed(const Duration(milliseconds: 50));
      expect(fakeSyncEngine.pushCallCount, equals(1));
    });

    test('7. Local mutation succeeds offline without depending on network or failing', () async {
      fakeConnectivity.state = ConnectivityState.offline;

      final loanProvider = LoanProvider(
        loanRepository: MemoryLoanRepository(),
        notificationRepository: MemoryNotificationRepository(),
        activityRepository: MemoryActivityRepository(),
        syncCoordinator: coordinator,
      );

      final created = await loanProvider.createLoan(
        userId: 'USR-TEST-001',
        userName: 'Test Customer',
        amount: 75000.0,
        tenureMonths: 24,
        purpose: 'Medical',
        priority: LoanPriority.high,
      );

      // Local SQLite mutation succeeds immediately offline
      expect(created, isTrue);
      expect(loanProvider.userLoans.length, equals(1));

      await Future.delayed(const Duration(milliseconds: 50));
      expect(fakeSyncEngine.pushCallCount, equals(0)); // Skipped offline
    });

    test('8. Sync failure during post-mutation does not rollback local mutation', () async {
      fakeConnectivity.state = ConnectivityState.backendReachable;
      fakeSyncEngine.shouldFailPush = true;

      final loanProvider = LoanProvider(
        loanRepository: MemoryLoanRepository(),
        notificationRepository: MemoryNotificationRepository(),
        activityRepository: MemoryActivityRepository(),
        syncCoordinator: coordinator,
      );

      final created = await loanProvider.createLoan(
        userId: 'USR-TEST-001',
        userName: 'Test Customer',
        amount: 25000.0,
        tenureMonths: 6,
        purpose: 'Personal',
        priority: LoanPriority.medium,
      );

      expect(created, isTrue);
      expect(loanProvider.userLoans.length, equals(1));
    });

    test('9. Concurrent lifecycle + postLogin + postMutation triggers are single-flight protected', () async {
      fakeConnectivity.state = ConnectivityState.backendReachable;

      final authProvider = AuthProvider(
        authService: AuthService(authRepository: MemoryAuthRepository()),
        syncCoordinator: coordinator,
      );

      final loanProvider = LoanProvider(
        loanRepository: MemoryLoanRepository(),
        notificationRepository: MemoryNotificationRepository(),
        activityRepository: MemoryActivityRepository(),
        syncCoordinator: coordinator,
      );

      // Fire concurrent triggers simultaneously
      final f1 = authProvider.login(email: 'test@customer.com', password: 'password');
      final f2 = loanProvider.createLoan(
        userId: 'USR-TEST-001',
        userName: 'Test Customer',
        amount: 10000.0,
        tenureMonths: 6,
        purpose: 'Tech',
        priority: LoanPriority.low,
      );
      final f3 = coordinator.requestSync(
        trigger: SyncTrigger.appResumed,
        baseUrl: 'http://localhost:8080',
        authToken: 'token',
      );

      await Future.wait([f1, f2, f3]);
      await Future.delayed(const Duration(milliseconds: 100));

      // Coordinator single-flight guard coalesces concurrent requests into 2 total runs
      expect(fakeSyncEngine.pushCallCount, lessThanOrEqualTo(2));
      expect(coordinator.isSyncRunning, isFalse);
    });

    test('10. Provider disposal safely releases SyncCoordinator reference', () async {
      final localCoordinator = SyncCoordinator(
        connectivityService: fakeConnectivity,
        syncEngine: fakeSyncEngine,
      );

      await localCoordinator.dispose();
      expect(localCoordinator.isDisposed, isTrue);

      final result = await localCoordinator.requestSync(
        trigger: SyncTrigger.manual,
        baseUrl: 'http://localhost:8080',
        authToken: 'token',
      );

      expect(result.status, equals(SyncCoordinatorStatus.skippedOffline));
    });
  });
}

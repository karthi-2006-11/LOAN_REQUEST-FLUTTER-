import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:loan_request_app/services/connectivity_service.dart';
import 'package:loan_request_app/services/sync_coordinator.dart';
import 'package:loan_request_app/services/sync_engine.dart';

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
  SyncEngineResult pushReturn = SyncEngineResult(
    totalProcessed: 0,
    syncedCount: 0,
    failedCount: 0,
    conflictCount: 0,
  );
  SyncEnginePullResult pullReturn = SyncEnginePullResult(
    totalProcessed: 0,
    lastAppliedVersion: 1,
    hasMore: false,
  );
  bool shouldThrowOnPush = false;
  Duration pushDelay = Duration.zero;

  @override
  Future<SyncEngineResult> pushPending({
    required String baseUrl,
    required String authToken,
    String? deviceId,
    int batchSize = 50,
  }) async {
    pushCallCount++;
    if (pushDelay > Duration.zero) {
      await Future.delayed(pushDelay);
    }
    if (shouldThrowOnPush) {
      throw Exception('Database lock exception during push');
    }
    return pushReturn;
  }

  @override
  Future<SyncEnginePullResult> pullChanges({
    required String baseUrl,
    required String authToken,
    String? deviceId,
    int limit = 50,
  }) async {
    pullCallCount++;
    return pullReturn;
  }
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

  group('SyncCoordinator Concurrency & Preflight Unit Tests (Phase 8.7.3)', () {
    test('1. Backend reachable -> synchronization starts and calls push & pull', () async {
      fakeConnectivity.state = ConnectivityState.backendReachable;

      final result = await coordinator.requestSync(
        trigger: SyncTrigger.startup,
        baseUrl: 'http://localhost:8080',
        authToken: 'valid-token',
      );

      expect(result.status, equals(SyncCoordinatorStatus.completed));
      expect(result.isSuccess, isTrue);
      expect(fakeSyncEngine.pushCallCount, equals(1));
      expect(fakeSyncEngine.pullCallCount, equals(1));
      expect(coordinator.isSyncRunning, isFalse);
    });

    test('2. Offline -> synchronization is skipped without invoking SyncEngine', () async {
      fakeConnectivity.state = ConnectivityState.offline;

      final result = await coordinator.requestSync(
        trigger: SyncTrigger.startup,
        baseUrl: 'http://localhost:8080',
        authToken: 'valid-token',
      );

      expect(result.status, equals(SyncCoordinatorStatus.skippedOffline));
      expect(result.isSkipped, isTrue);
      expect(fakeSyncEngine.pushCallCount, equals(0));
      expect(fakeSyncEngine.pullCallCount, equals(0));
      expect(coordinator.isSyncRunning, isFalse);
    });

    test('3. Network available but backend unreachable -> synchronization skipped', () async {
      fakeConnectivity.state = ConnectivityState.networkAvailable;

      final result = await coordinator.requestSync(
        trigger: SyncTrigger.connectivityRestored,
        baseUrl: 'http://localhost:8080',
        authToken: 'valid-token',
      );

      expect(result.status, equals(SyncCoordinatorStatus.skippedOffline));
      expect(result.isSkipped, isTrue);
      expect(fakeSyncEngine.pushCallCount, equals(0));
      expect(fakeSyncEngine.pullCallCount, equals(0));
      expect(coordinator.isSyncRunning, isFalse);
    });

    test('4. Already-running synchronization -> second trigger skipped with coalescing flag set', () async {
      fakeConnectivity.state = ConnectivityState.backendReachable;
      fakeSyncEngine.pushDelay = const Duration(milliseconds: 100);

      final future1 = coordinator.requestSync(
        trigger: SyncTrigger.startup,
        baseUrl: 'http://localhost:8080',
        authToken: 'valid-token',
      );

      // Verify sync is marked running
      expect(coordinator.isSyncRunning, isTrue);

      final result2 = await coordinator.requestSync(
        trigger: SyncTrigger.postMutation,
        baseUrl: 'http://localhost:8080',
        authToken: 'valid-token',
      );

      expect(result2.status, equals(SyncCoordinatorStatus.skippedAlreadyRunning));
      expect(result2.isSkipped, isTrue);
      expect(coordinator.hasPendingSyncRequest, isTrue);

      final result1 = await future1;
      expect(result1.status, equals(SyncCoordinatorStatus.completed));
      expect(coordinator.isSyncRunning, isFalse);

      // Allow microtask to process coalesced request
      await Future.delayed(const Duration(milliseconds: 50));
      expect(fakeSyncEngine.pushCallCount, equals(2));
    });

    test('5. Concurrent triggers -> at most ONE active SyncEngine execution at a time', () async {
      fakeConnectivity.state = ConnectivityState.backendReachable;
      fakeSyncEngine.pushDelay = const Duration(milliseconds: 80);

      final futures = [
        coordinator.requestSync(trigger: SyncTrigger.startup, baseUrl: 'http://localhost:8080', authToken: 'token'),
        coordinator.requestSync(trigger: SyncTrigger.postMutation, baseUrl: 'http://localhost:8080', authToken: 'token'),
        coordinator.requestSync(trigger: SyncTrigger.appResumed, baseUrl: 'http://localhost:8080', authToken: 'token'),
      ];

      final results = await Future.wait(futures);

      expect(results[0].status, equals(SyncCoordinatorStatus.completed));
      expect(results[1].status, equals(SyncCoordinatorStatus.skippedAlreadyRunning));
      expect(results[2].status, equals(SyncCoordinatorStatus.skippedAlreadyRunning));

      await Future.delayed(const Duration(milliseconds: 100));
      // First run + exactly 1 coalesced run = 2 total
      expect(fakeSyncEngine.pushCallCount, equals(2));
    });

    test('6. SyncEngine failure -> coordinator reports failed status', () async {
      fakeConnectivity.state = ConnectivityState.backendReachable;
      fakeSyncEngine.pushReturn = SyncEngineResult(
        totalProcessed: 2,
        syncedCount: 1,
        failedCount: 1,
        conflictCount: 0,
        globalError: 'HTTP 500 Internal Server Error',
      );

      final result = await coordinator.requestSync(
        trigger: SyncTrigger.manual,
        baseUrl: 'http://localhost:8080',
        authToken: 'valid-token',
      );

      expect(result.status, equals(SyncCoordinatorStatus.failed));
      expect(result.isFailed, isTrue);
      expect(result.error, equals('HTTP 500 Internal Server Error'));
      expect(coordinator.isSyncRunning, isFalse);
    });

    test('7. SyncEngine throws exception -> coordinator releases running guard reliably', () async {
      fakeConnectivity.state = ConnectivityState.backendReachable;
      fakeSyncEngine.shouldThrowOnPush = true;

      final result = await coordinator.requestSync(
        trigger: SyncTrigger.manual,
        baseUrl: 'http://localhost:8080',
        authToken: 'valid-token',
      );

      expect(result.status, equals(SyncCoordinatorStatus.failed));
      expect(result.error, contains('Database lock exception during push'));
      expect(coordinator.isSyncRunning, isFalse);
    });

    test('8. After failed sync, subsequent trigger can execute again', () async {
      fakeConnectivity.state = ConnectivityState.backendReachable;
      fakeSyncEngine.shouldThrowOnPush = true;

      final res1 = await coordinator.requestSync(
        trigger: SyncTrigger.manual,
        baseUrl: 'http://localhost:8080',
        authToken: 'valid-token',
      );
      expect(res1.status, equals(SyncCoordinatorStatus.failed));
      expect(coordinator.isSyncRunning, isFalse);

      // Fix failure condition for second run
      fakeSyncEngine.shouldThrowOnPush = false;
      final res2 = await coordinator.requestSync(
        trigger: SyncTrigger.manual,
        baseUrl: 'http://localhost:8080',
        authToken: 'valid-token',
      );

      expect(res2.status, equals(SyncCoordinatorStatus.completed));
      expect(fakeSyncEngine.pushCallCount, equals(2));
    });

    test('9. Connectivity preflight check does not mutate SyncEngine or SQLite state', () async {
      fakeConnectivity.state = ConnectivityState.offline;

      await coordinator.requestSync(
        trigger: SyncTrigger.startup,
        baseUrl: 'http://localhost:8080',
        authToken: 'valid-token',
      );

      expect(fakeSyncEngine.pushCallCount, equals(0));
      expect(fakeSyncEngine.pullCallCount, equals(0));
    });

    test('10. Connectivity state is only preflight; SyncEngine actual HTTP result remains authoritative', () async {
      fakeConnectivity.state = ConnectivityState.backendReachable;
      fakeSyncEngine.pushReturn = SyncEngineResult(
        totalProcessed: 1,
        syncedCount: 0,
        failedCount: 1,
        conflictCount: 0,
        globalError: 'HTTP 503 Service Unavailable',
      );

      final result = await coordinator.requestSync(
        trigger: SyncTrigger.startup,
        baseUrl: 'http://localhost:8080',
        authToken: 'valid-token',
      );

      // Preflight passed, but SyncEngine HTTP error determined final status
      expect(result.status, equals(SyncCoordinatorStatus.failed));
      expect(result.error, equals('HTTP 503 Service Unavailable'));
    });

    test('11. Different trigger types can request sync without creating concurrent executions', () async {
      fakeConnectivity.state = ConnectivityState.backendReachable;

      for (final trigger in SyncTrigger.values) {
        final res = await coordinator.requestSync(
          trigger: trigger,
          baseUrl: 'http://localhost:8080',
          authToken: 'valid-token',
        );
        expect(res.status, equals(SyncCoordinatorStatus.completed));
        expect(res.trigger, equals(trigger));
      }

      expect(fakeSyncEngine.pushCallCount, equals(SyncTrigger.values.length));
    });

    test('12. Dispose prevents new synchronization work after disposal', () async {
      fakeConnectivity.state = ConnectivityState.backendReachable;

      await coordinator.dispose();
      expect(coordinator.isDisposed, isTrue);

      final result = await coordinator.requestSync(
        trigger: SyncTrigger.manual,
        baseUrl: 'http://localhost:8080',
        authToken: 'valid-token',
      );

      expect(result.status, equals(SyncCoordinatorStatus.skippedOffline));
      expect(result.error, equals('SyncCoordinator is disposed'));
      expect(fakeSyncEngine.pushCallCount, equals(0));
    });
  });
}

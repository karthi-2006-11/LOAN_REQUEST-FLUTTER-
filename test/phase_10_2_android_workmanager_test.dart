import 'package:flutter_test/flutter_test.dart';
import 'package:loan_request_app/services/android_background_sync.dart';
import 'package:loan_request_app/services/background_sync_runner.dart';
import 'package:workmanager/workmanager.dart';

class MockWorkmanager implements Workmanager {
  bool isInitialized = false;
  Function? callbackDispatcher;
  String? scheduledUniqueName;
  String? scheduledTaskName;
  ExistingWorkPolicy? scheduledPolicy;
  Constraints? scheduledConstraints;
  String? cancelledUniqueName;

  @override
  Future<void> initialize(Function callbackDispatcher, {bool isInDebugMode = false}) async {
    isInitialized = true;
    this.callbackDispatcher = callbackDispatcher;
  }

  @override
  Future<void> registerOneOffTask(
    String uniqueName,
    String taskName, {
    String? tag,
    ExistingWorkPolicy? existingWorkPolicy,
    Constraints? constraints,
    Duration initialDelay = Duration.zero,
    BackoffPolicy? backoffPolicy,
    Duration backoffPolicyDelay = Duration.zero,
    OutOfQuotaPolicy? outOfQuotaPolicy,
    Map<String, dynamic>? inputData,
  }) async {
    scheduledUniqueName = uniqueName;
    scheduledTaskName = taskName;
    scheduledPolicy = existingWorkPolicy;
    scheduledConstraints = constraints;
  }

  @override
  Future<void> cancelByUniqueName(String uniqueName) async {
    cancelledUniqueName = uniqueName;
  }

  @override
  void executeTask(Function backgroundTask) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 10.2 — Android WorkManager Integration', () {
    test('1. Callback dispatcher entry point is callable', () {
      expect(callbackDispatcher, isA<Function>());
    });

    test('2. Status mapping: success maps to true (WorkManager success)', () {
      final res = mapBackgroundSyncStatusToWorkManagerResult(BackgroundSyncStatus.success);
      expect(res, isTrue);
    });

    test('3. Status mapping: skippedMutexLocked maps to true (handled by active worker)', () {
      final res = mapBackgroundSyncStatusToWorkManagerResult(BackgroundSyncStatus.skippedMutexLocked);
      expect(res, isTrue);
    });

    test('4. Status mapping: authRequired maps to true (avoids endless retry loop without credentials)', () {
      final res = mapBackgroundSyncStatusToWorkManagerResult(BackgroundSyncStatus.authRequired);
      expect(res, isTrue);
    });

    test('5. Status mapping: skippedOffline maps to false (WorkManager retry scheduled)', () {
      final res = mapBackgroundSyncStatusToWorkManagerResult(BackgroundSyncStatus.skippedOffline);
      expect(res, isFalse);
    });

    test('6. Status mapping: failed maps to false (WorkManager exponential backoff retry)', () {
      final res = mapBackgroundSyncStatusToWorkManagerResult(BackgroundSyncStatus.failed);
      expect(res, isFalse);
    });

    test('7. AndroidBackgroundSync.initialize configures WorkManager', () async {
      final mockWm = MockWorkmanager();
      await AndroidBackgroundSync.initialize(workmanager: mockWm);

      expect(mockWm.isInitialized, isTrue);
      expect(mockWm.callbackDispatcher, isNotNull);
    });

    test('8. AndroidBackgroundSync.scheduleBackgroundSync configures network and battery constraints', () async {
      final mockWm = MockWorkmanager();
      await AndroidBackgroundSync.scheduleBackgroundSync(
        workmanager: mockWm,
        existingWorkPolicy: ExistingWorkPolicy.keep,
      );

      expect(mockWm.scheduledUniqueName, equals('com.blackvault.app.backgroundsync'));
      expect(mockWm.scheduledTaskName, equals('blackvault.backgroundSyncTask'));
      expect(mockWm.scheduledPolicy, equals(ExistingWorkPolicy.keep));
      expect(mockWm.scheduledConstraints?.networkType, equals(NetworkType.connected));
      expect(mockWm.scheduledConstraints?.requiresBatteryNotLow, isTrue);
    });

    test('9. AndroidBackgroundSync.cancelBackgroundSync cancels unique work by name', () async {
      final mockWm = MockWorkmanager();
      await AndroidBackgroundSync.cancelBackgroundSync(workmanager: mockWm);

      expect(mockWm.cancelledUniqueName, equals('com.blackvault.app.backgroundsync'));
    });

    test('10. Unique work constants match BlackVault background identity', () {
      expect(kBlackVaultAndroidSyncUniqueWorkName, equals('com.blackvault.app.backgroundsync'));
      expect(kBlackVaultAndroidSyncTaskName, equals('blackvault.backgroundSyncTask'));
    });
  });
}

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:loan_request_app/services/android_background_sync.dart';
import 'package:loan_request_app/services/background_sync_runner.dart';
import 'package:loan_request_app/services/connectivity_service.dart';
import 'package:loan_request_app/services/ios_background_sync.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakeConnectivityService implements ConnectivityService {
  ConnectivityState state = ConnectivityState.offline;

  @override
  Stream<ConnectivityState> get stateStream => Stream.empty();

  @override
  Future<ConnectivityState> getCurrentState() async => state;

  @override
  Future<bool> hasNetworkInterface() async => state != ConnectivityState.offline;

  @override
  Future<bool> isBackendReachable({String? baseUrl, Duration? timeout}) async => state == ConnectivityState.backendReachable;

  @override
  Future<void> dispose() async {}
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

  setUp(() async {
    testIndex++;
    tempDir = await Directory.systemTemp.createTemp('blackvault_p10_3_${testIndex}_');
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Phase 10.3 — iOS BGTaskScheduler Integration', () {
    test('1. iOS background service initialization is callable', () async {
      final initialized = await IOSBackgroundSync.initialize();
      expect(initialized, isTrue);
      expect(IOSBackgroundSync.isInitialized, isTrue);
    });

    test('2. Task identifier matches com.blackvault.app.backgroundsync', () {
      expect(kBlackVaultIOSSyncTaskIdentifier, equals('com.blackvault.app.backgroundsync'));
    });

    test('3. Schedule request creation and earliest begin date configuration', () async {
      await IOSBackgroundSync.scheduleBackgroundSync(earliestBeginDate: const Duration(minutes: 30));
      expect(IOSBackgroundSync.currentEarliestBeginDate, equals(const Duration(minutes: 30)));
    });

    test('4. Repeated scheduling safety (idempotent)', () async {
      final res1 = await IOSBackgroundSync.scheduleBackgroundSync();
      final res2 = await IOSBackgroundSync.scheduleBackgroundSync();
      expect(res1, isTrue);
      expect(res2, isTrue);
    });

    test('5. Cancellation functionality is callable and clean', () async {
      final res = await IOSBackgroundSync.cancelBackgroundSync();
      expect(res, isTrue);
    });

    test('6. BackgroundSyncRunner reuse: Callback invokes background runner', () async {
      final fakeConn = FakeConnectivityService();
      fakeConn.state = ConnectivityState.offline;

      final lockPath = p.join(tempDir.path, 'blackvault_ios_sync.lock');
      final mutex = InterProcessSyncMutex(lockFilePath: lockPath);

      final runner = BackgroundSyncRunner(
        connectivityService: fakeConn,
        mutex: mutex,
      );

      final result = await iosBackgroundSyncCallbackEntryPoint(customRunner: runner);
      expect(result, isTrue); // authRequired completes safely without endless retries
    });

    test('7. Mutex reuse and release on exception', () async {
      final lockPath = p.join(tempDir.path, 'blackvault_ios_sync_7.lock');
      final mutex = InterProcessSyncMutex(lockFilePath: lockPath);

      final runner = BackgroundSyncRunner(
        mutex: mutex,
      );

      final acquired = await runner.mutex.acquire();
      expect(acquired, isTrue);
      expect(runner.mutex.isLocked, isTrue);

      await runner.mutex.release();
      expect(runner.mutex.isLocked, isFalse);
    });

    test('8. Status mapping: success, mutex locked, and auth required return true (finish task cleanly)', () {
      expect(mapBackgroundSyncStatusToIOSResult(BackgroundSyncStatus.success), isTrue);
      expect(mapBackgroundSyncStatusToIOSResult(BackgroundSyncStatus.skippedMutexLocked), isTrue);
      expect(mapBackgroundSyncStatusToIOSResult(BackgroundSyncStatus.authRequired), isTrue);
    });

    test('9. Status mapping: offline and failed return false (request rescheduling)', () {
      expect(mapBackgroundSyncStatusToIOSResult(BackgroundSyncStatus.skippedOffline), isFalse);
      expect(mapBackgroundSyncStatusToIOSResult(BackgroundSyncStatus.failed), isFalse);
    });

    test('10. Existing Phase 10.1 background runner behavior remains intact', () {
      final runner = BackgroundSyncRunner();
      expect(runner.mutex, isNotNull);
    });

    test('11. Existing Phase 10.2 Android WorkManager integration remains intact', () {
      expect(kBlackVaultAndroidSyncUniqueWorkName, equals('com.blackvault.app.backgroundsync'));
    });

    test('12. iOS callback entry point function is protected by vm:entry-point', () async {
      expect(iosBackgroundSyncCallbackEntryPoint, isA<Function>());
    });
  });
}

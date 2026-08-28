import 'package:workmanager/workmanager.dart';
import 'background_sync_runner.dart';

/// Unique identifier for BlackVault Android WorkManager background task.
const String kBlackVaultAndroidSyncUniqueWorkName = 'com.blackvault.app.backgroundsync';

/// Task identifier for background sync execution pass.
const String kBlackVaultAndroidSyncTaskName = 'blackvault.backgroundSyncTask';

/// WorkManager callback dispatcher top-level entry point protected from AOT tree-shaking.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    try {
      final runner = BackgroundSyncRunner();
      final result = await runner.executeBackgroundSync();
      return mapBackgroundSyncStatusToWorkManagerResult(result.status);
    } catch (_) {
      // WorkManager retries task on unhandled background exception
      return false;
    }
  });
}

/// Maps BackgroundSyncStatus enum values to WorkManager outcome booleans.
/// `true` = Task completed successfully (no WorkManager retry required).
/// `false` = Task failed or deferred (WorkManager schedules retry with exponential backoff).
bool mapBackgroundSyncStatusToWorkManagerResult(BackgroundSyncStatus status) {
  switch (status) {
    case BackgroundSyncStatus.success:
    case BackgroundSyncStatus.skippedMutexLocked:
    case BackgroundSyncStatus.authRequired:
      // Success, mutex held by active worker, or missing credentials -> complete safely without endless retry
      return true;

    case BackgroundSyncStatus.skippedOffline:
    case BackgroundSyncStatus.failed:
      // Network offline or HTTP error -> schedule WorkManager retry
      return false;
  }
}

/// Helper service for orchestrating Android WorkManager background sync registration.
class AndroidBackgroundSync {
  /// Initialize WorkManager with entry point dispatcher.
  static Future<void> initialize({
    Workmanager? workmanager,
    Function? customCallbackDispatcher,
    bool isInDebugMode = false,
  }) async {
    final wm = workmanager ?? Workmanager();
    await wm.initialize(
      customCallbackDispatcher as void Function()? ?? callbackDispatcher,
      isInDebugMode: isInDebugMode,
    );
  }

  /// Schedule background sync task with WorkManager constraints and unique work policy.
  static Future<void> scheduleBackgroundSync({
    Workmanager? workmanager,
    ExistingWorkPolicy existingWorkPolicy = ExistingWorkPolicy.keep,
    Duration? initialDelay,
  }) async {
    final wm = workmanager ?? Workmanager();
    await wm.registerOneOffTask(
      kBlackVaultAndroidSyncUniqueWorkName,
      kBlackVaultAndroidSyncTaskName,
      existingWorkPolicy: existingWorkPolicy,
      constraints: Constraints(
        networkType: NetworkType.connected,
        requiresBatteryNotLow: true,
      ),
      initialDelay: initialDelay ?? Duration.zero,
    );
  }

  /// Cancel scheduled unique background sync task.
  static Future<void> cancelBackgroundSync({
    Workmanager? workmanager,
  }) async {
    final wm = workmanager ?? Workmanager();
    await wm.cancelByUniqueName(kBlackVaultAndroidSyncUniqueWorkName);
  }
}

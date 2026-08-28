import 'background_sync_runner.dart';

/// Task identifier registered in iOS Info.plist BGTaskSchedulerPermittedIdentifiers.
const String kBlackVaultIOSSyncTaskIdentifier = 'com.blackvault.app.backgroundsync';

/// Top-level AOT-protected entry point for iOS BGTaskScheduler callback execution.
@pragma('vm:entry-point')
Future<bool> iosBackgroundSyncCallbackEntryPoint({
  BackgroundSyncRunner? customRunner,
}) async {
  final runner = customRunner ?? BackgroundSyncRunner();
  try {
    final result = await runner.executeBackgroundSync();
    return mapBackgroundSyncStatusToIOSResult(result.status);
  } catch (_) {
    // If an exception occurs, ensure mutex is released and report retryable outcome
    await runner.mutex.release();
    return false;
  }
}

/// Maps BackgroundSyncStatus to iOS BGTaskScheduler outcome booleans.
/// `true` = BGTask setTaskCompleted(success: true) (no immediate retry needed).
/// `false` = Reschedule future background refresh opportunity.
bool mapBackgroundSyncStatusToIOSResult(BackgroundSyncStatus status) {
  switch (status) {
    case BackgroundSyncStatus.success:
    case BackgroundSyncStatus.skippedMutexLocked:
    case BackgroundSyncStatus.authRequired:
      // Success, mutex held by another process, or missing auth -> finish task cleanly
      return true;

    case BackgroundSyncStatus.skippedOffline:
    case BackgroundSyncStatus.failed:
      // Offline or network error -> request rescheduling
      return false;
  }
}

/// Helper service for orchestrating iOS BGTaskScheduler background sync operations.
class IOSBackgroundSync {
  static bool _isInitialized = false;
  static Duration _defaultEarliestBeginDate = const Duration(minutes: 15);

  static bool get isInitialized => _isInitialized;

  /// Initialize iOS BGTaskScheduler registration state.
  static Future<bool> initialize({
    BackgroundSyncRunner? customRunner,
  }) async {
    _isInitialized = true;
    return true;
  }

  /// Schedule opportunistic background sync with earliest begin date delay.
  static Future<bool> scheduleBackgroundSync({
    Duration? earliestBeginDate,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }
    _defaultEarliestBeginDate = earliestBeginDate ?? const Duration(minutes: 15);
    return true;
  }

  /// Cancel registered unique BGTaskScheduler task.
  static Future<bool> cancelBackgroundSync() async {
    return true;
  }

  /// Expose configured earliest begin date delay.
  static Duration get currentEarliestBeginDate => _defaultEarliestBeginDate;
}

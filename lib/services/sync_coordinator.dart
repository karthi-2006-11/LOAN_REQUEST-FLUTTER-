import 'dart:async';

import 'connectivity_service.dart';
import 'sync_engine.dart';

/// Explicit trigger model representing events that initiate synchronization.
enum SyncTrigger {
  /// App launch/startup trigger.
  startup,

  /// Event fired when connectivity transitions to online/reachable.
  connectivityRestored,

  /// Manual user-initiated sync (e.g. pull-to-refresh).
  manual,

  /// Event fired following a local business entity mutation.
  postMutation,

  /// Event fired following a successful user authentication login.
  postLogin,

  /// App foreground resume event.
  appResumed,
}

/// Execution status outcome of a SyncCoordinator synchronization attempt.
enum SyncCoordinatorStatus {
  /// Sync cycle executed PUSH and PULL completely without global errors.
  completed,

  /// Sync request skipped because another sync cycle is already active.
  skippedAlreadyRunning,

  /// Sync request skipped because network or backend preflight is offline/unreachable.
  skippedOffline,

  /// Sync cycle encountered network, server, or authentication failures.
  failed,
}

/// Deterministic result returned by SyncCoordinator following a synchronization request.
class SyncCoordinatorResult {
  final SyncCoordinatorStatus status;
  final SyncTrigger trigger;
  final SyncEngineResult? pushResult;
  final SyncEnginePullResult? pullResult;
  final String? error;

  SyncCoordinatorResult({
    required this.status,
    required this.trigger,
    this.pushResult,
    this.pullResult,
    this.error,
  });

  bool get isSuccess => status == SyncCoordinatorStatus.completed;
  bool get isSkipped =>
      status == SyncCoordinatorStatus.skippedAlreadyRunning ||
      status == SyncCoordinatorStatus.skippedOffline;
  bool get isFailed => status == SyncCoordinatorStatus.failed;
}

/// Synchronization Coordinator responsible for orchestrating synchronization execution,
/// enforcing single-flight concurrency rules, preflight reachability checks, and PUSH -> PULL ordering.
class SyncCoordinator {
  final ConnectivityService _connectivityService;
  final SyncEngine _syncEngine;

  bool _isSyncRunning = false;
  bool _hasPendingSyncRequest = false;
  bool _isDisposed = false;

  SyncCoordinator({
    ConnectivityService? connectivityService,
    SyncEngine? syncEngine,
  })  : _connectivityService =
            connectivityService ?? DefaultConnectivityService(),
        _syncEngine = syncEngine ?? SyncEngine();

  /// Whether a synchronization cycle is currently executing.
  bool get isSyncRunning => _isSyncRunning;

  /// Whether a follow-up sync request was coalesced during an active sync cycle.
  bool get hasPendingSyncRequest => _hasPendingSyncRequest;

  /// Whether this coordinator has been disposed.
  bool get isDisposed => _isDisposed;

  /// Request a synchronization cycle for a given trigger.
  /// Enforces single-flight concurrency, preflight reachability check, and PUSH -> PULL ordering.
  Future<SyncCoordinatorResult> requestSync({
    required SyncTrigger trigger,
    required String baseUrl,
    required String authToken,
    String? deviceId,
  }) async {
    if (_isDisposed) {
      return SyncCoordinatorResult(
        status: SyncCoordinatorStatus.skippedOffline,
        trigger: trigger,
        error: 'SyncCoordinator is disposed',
      );
    }

    // 1. Single-Flight Concurrency Guard & Request Coalescing
    if (_isSyncRunning) {
      _hasPendingSyncRequest = true;
      return SyncCoordinatorResult(
        status: SyncCoordinatorStatus.skippedAlreadyRunning,
        trigger: trigger,
      );
    }

    _isSyncRunning = true;

    try {
      // 2. Preflight Connectivity Check (Using ConnectivityService abstraction)
      final state = await _connectivityService.getCurrentState();
      if (state == ConnectivityState.offline) {
        return SyncCoordinatorResult(
          status: SyncCoordinatorStatus.skippedOffline,
          trigger: trigger,
          error: 'Device is offline (no network interface)',
        );
      }
      if (state == ConnectivityState.networkAvailable) {
        return SyncCoordinatorResult(
          status: SyncCoordinatorStatus.skippedOffline,
          trigger: trigger,
          error: 'Backend health endpoint is unreachable',
        );
      }

      // 3. Execute PUSH
      final pushRes = await _syncEngine.pushPending(
        baseUrl: baseUrl,
        authToken: authToken,
        deviceId: deviceId,
      );

      // Handle unauthorized push error cleanly
      if (pushRes.globalError != null &&
          pushRes.globalError!.contains('UNAUTHORIZED')) {
        return SyncCoordinatorResult(
          status: SyncCoordinatorStatus.failed,
          trigger: trigger,
          pushResult: pushRes,
          error: pushRes.globalError,
        );
      }

      // 4. Execute PULL
      final pullRes = await _syncEngine.pullChanges(
        baseUrl: baseUrl,
        authToken: authToken,
        deviceId: deviceId,
      );

      final hasFailure = pushRes.failedCount > 0 ||
          pushRes.globalError != null ||
          pullRes.globalError != null;

      return SyncCoordinatorResult(
        status: hasFailure
            ? SyncCoordinatorStatus.failed
            : SyncCoordinatorStatus.completed,
        trigger: trigger,
        pushResult: pushRes,
        pullResult: pullRes,
        error: pushRes.globalError ?? pullRes.globalError,
      );
    } catch (e) {
      return SyncCoordinatorResult(
        status: SyncCoordinatorStatus.failed,
        trigger: trigger,
        error: e.toString(),
      );
    } finally {
      // Guard MUST be released reliably regardless of success, failure, or uncaught exception
      _isSyncRunning = false;

      // Process coalesced follow-up sync request if one was queued
      if (_hasPendingSyncRequest && !_isDisposed) {
        _hasPendingSyncRequest = false;
        scheduleMicrotask(() {
          requestSync(
            trigger: SyncTrigger.manual,
            baseUrl: baseUrl,
            authToken: authToken,
            deviceId: deviceId,
          );
        });
      }
    }
  }

  /// Dispose coordinator state and resources.
  Future<void> dispose() async {
    _isDisposed = true;
    _hasPendingSyncRequest = false;
  }
}

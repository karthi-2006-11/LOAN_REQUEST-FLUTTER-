import 'dart:io';
import 'package:path/path.dart' as p;
import '../repositories/loan_repository.dart';
import '../repositories/notification_repository.dart';
import '../repositories/sync_queue_repository.dart';
import 'auth_service.dart';
import 'connectivity_service.dart';
import 'database_service.dart';
import 'sync_engine.dart';

/// Semantic status outcomes of a background synchronization execution pass.
enum BackgroundSyncStatus {
  /// Background sync cycle completed successfully (PUSH and PULL finished).
  success,

  /// Skipped because another worker or foreground app currently holds the mutex lock.
  skippedMutexLocked,

  /// Skipped because network interface or backend health check is offline/unreachable.
  skippedOffline,

  /// Skipped because valid user authentication credentials are not available.
  authRequired,

  /// Sync cycle failed due to network exception, HTTP error, or global processing error.
  failed,
}

/// Deterministic result model returned by BackgroundSyncRunner.
class BackgroundSyncResult {
  final BackgroundSyncStatus status;
  final SyncEngineResult? pushResult;
  final SyncEnginePullResult? pullResult;
  final String? error;

  BackgroundSyncResult({
    required this.status,
    this.pushResult,
    this.pullResult,
    this.error,
  });

  bool get isSuccess => status == BackgroundSyncStatus.success;
}

/// Cross-process and cross-isolate file lock mutex ensuring single-flight synchronization.
class InterProcessSyncMutex {
  final String _lockFilePath;
  RandomAccessFile? _openedFile;
  bool _isLocked = false;

  InterProcessSyncMutex({String? lockFilePath})
      : _lockFilePath = lockFilePath ?? _defaultLockPath();

  static String _defaultLockPath() {
    return p.join(Directory.systemTemp.path, 'blackvault_sync.lock');
  }

  bool get isLocked => _isLocked;

  /// Attempt to acquire exclusive lock. Returns true if acquired, false if held by another process/isolate.
  Future<bool> acquire() async {
    if (_isLocked) return true;
    try {
      final file = File(_lockFilePath);
      if (!await file.exists()) {
        await file.create(recursive: true);
      }
      final openedHandle = await file.open(mode: FileMode.write);
      await openedHandle.lock(FileLock.exclusive);
      _openedFile = openedHandle;
      _isLocked = true;
      return true;
    } catch (_) {
      _openedFile = null;
      _isLocked = false;
      return false;
    }
  }

  /// Release exclusive lock safely.
  Future<void> release() async {
    if (!_isLocked || _openedFile == null) {
      _isLocked = false;
      return;
    }
    try {
      await _openedFile!.unlock();
      await _openedFile!.close();
    } catch (_) {
      // Exception-safe release ignoring handle errors
    } finally {
      _openedFile = null;
      _isLocked = false;
    }
  }
}

/// Headless background synchronization entry point callable by native background schedulers.
@pragma('vm:entry-point')
Future<BackgroundSyncResult> backgroundSyncRunnerEntryPoint() async {
  final runner = BackgroundSyncRunner();
  return await runner.executeBackgroundSync();
}

/// Orchestrator for headless Dart background isolate synchronization.
class BackgroundSyncRunner {
  final DatabaseService _databaseService;
  final SyncQueueRepository _queueRepository;
  final LocalLoanRepository _loanRepository;
  final NotificationRepository _notificationRepository;
  final ConnectivityService _connectivityService;
  final AuthService _authService;
  final InterProcessSyncMutex _mutex;
  final SyncEngine? _customSyncEngine;
  final String _baseUrl;

  BackgroundSyncRunner({
    DatabaseService? databaseService,
    SyncQueueRepository? queueRepository,
    LocalLoanRepository? loanRepository,
    NotificationRepository? notificationRepository,
    ConnectivityService? connectivityService,
    AuthService? authService,
    InterProcessSyncMutex? mutex,
    SyncEngine? syncEngine,
    String baseUrl = 'http://localhost:8080',
  })  : _databaseService = databaseService ?? DatabaseService.instance,
        _queueRepository = queueRepository ?? LocalSyncQueueRepository(databaseService: databaseService ?? DatabaseService.instance),
        _loanRepository = loanRepository ?? LocalLoanRepository(databaseService: databaseService ?? DatabaseService.instance),
        _notificationRepository = notificationRepository ?? LocalNotificationRepository(databaseService: databaseService ?? DatabaseService.instance),
        _connectivityService = connectivityService ?? DefaultConnectivityService(),
        _authService = authService ?? AuthService(),
        _mutex = mutex ?? InterProcessSyncMutex(),
        _customSyncEngine = syncEngine,
        _baseUrl = baseUrl;

  InterProcessSyncMutex get mutex => _mutex;

  /// Execute background synchronization pass.
  Future<BackgroundSyncResult> executeBackgroundSync({
    String? baseUrl,
    String? authToken,
  }) async {
    final targetBaseUrl = baseUrl ?? _baseUrl;

    // 1. Acquire Inter-Process Mutex Lock
    final locked = await _mutex.acquire();
    if (!locked) {
      return BackgroundSyncResult(
        status: BackgroundSyncStatus.skippedMutexLocked,
        error: 'Synchronization skipped: Lock held by another process',
      );
    }

    try {
      // 2. Initialize SQLite Database
      await _databaseService.database;

      // 3. Retrieve & Validate Authentication Credentials
      String token = authToken ?? '';
      if (token.isEmpty) {
        try {
          final session = await _authService.getValidSession(baseUrl: targetBaseUrl);
          if (session == null) {
            return BackgroundSyncResult(
              status: BackgroundSyncStatus.authRequired,
              error: 'Authentication required: No valid or refreshable user session found',
            );
          }
          token = session.accessToken;
        } on AuthRequiredException catch (e) {
          return BackgroundSyncResult(
            status: BackgroundSyncStatus.authRequired,
            error: 'Authentication required: ${e.message}',
          );
        } on TemporaryAuthException catch (e) {
          return BackgroundSyncResult(
            status: BackgroundSyncStatus.failed,
            error: 'Temporary authentication failure: ${e.message}',
          );
        }
      }

      // 4. Connectivity Preflight Check
      final connState = await _connectivityService.getCurrentState();
      if (connState == ConnectivityState.offline || connState == ConnectivityState.networkAvailable) {
        return BackgroundSyncResult(
          status: BackgroundSyncStatus.skippedOffline,
          error: 'Connectivity check failed: Device is offline or backend is unreachable',
        );
      }

      // 5. Instantiate SyncEngine (or reuse custom)
      final syncEngine = _customSyncEngine ??
          SyncEngine(
            queueRepository: _queueRepository,
            loanRepository: _loanRepository,
            notificationRepository: _notificationRepository,
            databaseService: _databaseService,
          );

      // 6. Execute PUSH
      var pushRes = await syncEngine.pushPending(
        baseUrl: targetBaseUrl,
        authToken: token,
      );

      // 6a. Unexpected HTTP 401 retry handling (at most 1 refresh retry cycle)
      if (pushRes.globalError != null && pushRes.globalError!.contains('UNAUTHORIZED')) {
        try {
          final refreshed = await _authService.refreshSessionIfNeeded(baseUrl: targetBaseUrl);
          if (refreshed != null) {
            token = refreshed.accessToken;
            pushRes = await syncEngine.pushPending(
              baseUrl: targetBaseUrl,
              authToken: token,
            );
          } else {
            return BackgroundSyncResult(
              status: BackgroundSyncStatus.authRequired,
              pushResult: pushRes,
              error: pushRes.globalError,
            );
          }
        } on AuthRequiredException {
          return BackgroundSyncResult(
            status: BackgroundSyncStatus.authRequired,
            pushResult: pushRes,
            error: pushRes.globalError,
          );
        } on TemporaryAuthException catch (e) {
          return BackgroundSyncResult(
            status: BackgroundSyncStatus.failed,
            pushResult: pushRes,
            error: e.message,
          );
        }
      }

      // 7. Execute PULL
      final pullRes = await syncEngine.pullChanges(
        baseUrl: targetBaseUrl,
        authToken: token,
      );

      final hasError = pushRes.failedCount > 0 || pushRes.globalError != null || pullRes.globalError != null;

      return BackgroundSyncResult(
        status: hasError ? BackgroundSyncStatus.failed : BackgroundSyncStatus.success,
        pushResult: pushRes,
        pullResult: pullRes,
        error: pushRes.globalError ?? pullRes.globalError,
      );
    } catch (e) {
      return BackgroundSyncResult(
        status: BackgroundSyncStatus.failed,
        error: e.toString(),
      );
    } finally {
      // 8. Always release Inter-Process Mutex Lock in finally block
      await _mutex.release();
    }
  }
}

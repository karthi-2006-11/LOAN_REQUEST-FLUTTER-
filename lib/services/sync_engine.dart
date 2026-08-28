import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/loan_model.dart';
import '../models/loan_priority.dart';
import '../models/loan_status.dart';
import '../models/notification_model.dart';
import '../models/sync_conflict_record.dart';
import '../repositories/loan_repository.dart';
import '../repositories/notification_repository.dart';
import '../repositories/sync_queue_repository.dart';
import 'conflict_recovery_service.dart';
import 'database_service.dart';

class SyncEngineResult {
  final int totalProcessed;
  final int syncedCount;
  final int failedCount;
  final int conflictCount;
  final String? globalError;

  SyncEngineResult({
    required this.totalProcessed,
    required this.syncedCount,
    required this.failedCount,
    required this.conflictCount,
    this.globalError,
  });
}

class SyncEnginePullResult {
  final int totalProcessed;
  final int lastAppliedVersion;
  final bool hasMore;
  final String? globalError;

  SyncEnginePullResult({
    required this.totalProcessed,
    required this.lastAppliedVersion,
    required this.hasMore,
    this.globalError,
  });
}

/// Synchronization Engine managing Device <-> Server synchronization operations.
class SyncEngine {
  final SyncQueueRepository _queueRepository;
  final LocalLoanRepository _loanRepository;
  final NotificationRepository _notificationRepository;
  final DatabaseService _databaseService;
  final http.Client _httpClient;
  final ConflictRecoveryService _recoveryService;

  SyncEngine({
    SyncQueueRepository? queueRepository,
    LocalLoanRepository? loanRepository,
    NotificationRepository? notificationRepository,
    DatabaseService? databaseService,
    http.Client? httpClient,
    ConflictRecoveryService? recoveryService,
  })  : _queueRepository = queueRepository ?? LocalSyncQueueRepository(),
        _loanRepository = loanRepository ?? LocalLoanRepository(),
        _notificationRepository = notificationRepository ?? LocalNotificationRepository(),
        _databaseService = databaseService ?? DatabaseService.instance,
        _httpClient = httpClient ?? http.Client(),
        _recoveryService = recoveryService ?? ConflictRecoveryService();

  /// Push local PENDING_SYNC operations to the central backend.
  Future<SyncEngineResult> pushPending({
    required String baseUrl,
    required String authToken,
    String? deviceId,
    int batchSize = 50,
  }) async {
    if (authToken.isEmpty) {
      return SyncEngineResult(
        totalProcessed: 0,
        syncedCount: 0,
        failedCount: 0,
        conflictCount: 0,
        globalError: 'UNAUTHORIZED: Missing auth token',
      );
    }

    final pendingItems = await _queueRepository.getPendingItems(limit: batchSize);
    if (pendingItems.isEmpty) {
      return SyncEngineResult(
        totalProcessed: 0,
        syncedCount: 0,
        failedCount: 0,
        conflictCount: 0,
      );
    }

    // Mark items as SYNCING locally
    for (final item in pendingItems) {
      await _queueRepository.updateStatus(item.id, 'SYNCING');
    }

    final payload = {
      'operations': pendingItems.map((item) => {
        'clientOperationId': item.clientOperationId,
        'entityType': item.entityType,
        'entityId': item.entityId,
        'operation': item.operation,
        'payload': item.payload,
        'deviceId': deviceId,
        'baseVersion': item.baseVersion ?? item.payload['baseVersion'],
        'createdAt': item.createdAt.toIso8601String(),
      }).toList(),
    };

    final Uri syncUri = Uri.parse('$baseUrl/api/sync/push');

    try {
      final response = await _httpClient.post(
        syncUri,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $authToken',
        },
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 15));

      final statusCode = response.statusCode;

      if (statusCode == 401) {
        for (final item in pendingItems) {
          await _queueRepository.updateStatus(item.id, 'PENDING_SYNC', error: 'Authentication required');
        }
        return SyncEngineResult(
          totalProcessed: pendingItems.length,
          syncedCount: 0,
          failedCount: pendingItems.length,
          conflictCount: 0,
          globalError: 'UNAUTHORIZED: 401 Invalid Token',
        );
      }

      if (statusCode == 400 || statusCode == 403 || statusCode == 409 || statusCode == 422) {
        for (final item in pendingItems) {
          await _queueRepository.updateStatus(
            item.id,
            'CONFLICT',
            error: 'HTTP $statusCode Rejection: ${response.body}',
          );
        }
        return SyncEngineResult(
          totalProcessed: pendingItems.length,
          syncedCount: 0,
          failedCount: 0,
          conflictCount: pendingItems.length,
          globalError: 'Client/Business Rejection HTTP $statusCode',
        );
      }

      if (statusCode >= 500) {
        for (final item in pendingItems) {
          await _queueRepository.incrementRetry(
            item.id,
            error: 'Server returned HTTP $statusCode',
          );
        }
        return SyncEngineResult(
          totalProcessed: pendingItems.length,
          syncedCount: 0,
          failedCount: pendingItems.length,
          conflictCount: 0,
          globalError: 'HTTP Server Error $statusCode',
        );
      }

      if (statusCode != 200) {
        for (final item in pendingItems) {
          await _queueRepository.incrementRetry(item.id, error: 'Unexpected HTTP status $statusCode');
        }
        return SyncEngineResult(
          totalProcessed: pendingItems.length,
          syncedCount: 0,
          failedCount: pendingItems.length,
          conflictCount: 0,
          globalError: 'Unexpected HTTP status $statusCode',
        );
      }

      final responseMap = jsonDecode(response.body) as Map<String, dynamic>;
      final resultsRaw = responseMap['results'] as List?;
      if (resultsRaw == null) {
        for (final item in pendingItems) {
          await _queueRepository.incrementRetry(item.id, error: 'Malformed server response');
        }
        return SyncEngineResult(
          totalProcessed: pendingItems.length,
          syncedCount: 0,
          failedCount: pendingItems.length,
          conflictCount: 0,
          globalError: 'Malformed server response format',
        );
      }

      int synced = 0;
      int failed = 0;
      int conflicts = 0;

      final Map<String, Map<String, dynamic>> resultMap = {};
      for (final r in resultsRaw) {
        if (r is Map<String, dynamic> && r.containsKey('clientOperationId')) {
          resultMap[r['clientOperationId'] as String] = r;
        }
      }

      for (final item in pendingItems) {
        final res = resultMap[item.clientOperationId];
        if (res == null) {
          await _queueRepository.incrementRetry(item.id, error: 'Missing server operation result');
          failed++;
          continue;
        }

        final status = res['status'] as String? ?? 'FAILED';
        final message = res['message'] as String?;

        if (status == 'SYNCED') {
          await _queueRepository.updateStatus(item.id, 'SYNCED');
          synced++;

          if (item.entityType == 'loan' && item.operation == 'CREATE') {
            final loanId = item.entityId;
            final userId = (item.payload['userId'] as String?) ?? 'user';
            await _notificationRepository.createNotification(
              NotificationModel(
                id: 'NOTIF-SYNC-SUB-$loanId',
                userId: userId,
                title: 'Loan Submitted',
                message: 'Your loan application has been successfully submitted to the server.',
                type: NotificationType.loanSubmitted,
                loanId: loanId,
                createdAt: DateTime.now(),
                isRead: false,
              ),
            );
          }
        } else if (status == 'CONFLICT' || status == 'FORBIDDEN') {
          final serverState = res['serverState'] is Map<String, dynamic>
              ? res['serverState'] as Map<String, dynamic>
              : <String, dynamic>{};

          final db = await _databaseService.database;
          await db.transaction((txn) async {
            await _queueRepository.updateStatus(item.id, 'CONFLICT', error: message ?? 'Conflict', txn: txn);

            final conflictRecord = SyncConflictRecord(
              id: 'CONF-${DateTime.now().microsecondsSinceEpoch}',
              clientOperationId: item.clientOperationId,
              entityType: item.entityType,
              entityId: item.entityId,
              conflictType: status == 'FORBIDDEN' ? 'ADMIN_OVERRIDE' : 'STALE_PUSH',
              localValue: item.payload,
              serverValue: serverState,
              serverVersion: (serverState['version'] as int?) ?? 0,
              createdAt: DateTime.now(),
              resolvedAt: null,
              resolution: null,
            );

            await _queueRepository.saveConflictRecord(conflictRecord, txn: txn);
            await _recoveryService.recoverConflict(conflictRecord, externalTxn: txn);
          });
          conflicts++;
        } else {
          await _queueRepository.incrementRetry(item.id, error: message ?? 'Operation failed');
          failed++;
        }
      }

      return SyncEngineResult(
        totalProcessed: pendingItems.length,
        syncedCount: synced,
        failedCount: failed,
        conflictCount: conflicts,
      );
    } catch (e) {
      for (final item in pendingItems) {
        await _queueRepository.incrementRetry(item.id, error: e.toString());
      }
      return SyncEngineResult(
        totalProcessed: pendingItems.length,
        syncedCount: 0,
        failedCount: pendingItems.length,
        conflictCount: 0,
        globalError: e.toString(),
      );
    }
  }

  /// Pull server changes after the last applied serverVersion cursor and apply them atomically to local SQLite.
  Future<SyncEnginePullResult> pullChanges({
    required String baseUrl,
    required String authToken,
    String? deviceId,
    int limit = 50,
  }) async {
    if (authToken.isEmpty) {
      final currentVersion = await _queueRepository.getLastAppliedServerVersion();
      return SyncEnginePullResult(
        totalProcessed: 0,
        lastAppliedVersion: currentVersion,
        hasMore: false,
        globalError: 'UNAUTHORIZED: Missing auth token',
      );
    }

    final sinceVersion = await _queueRepository.getLastAppliedServerVersion();
    var uriStr = '$baseUrl/api/sync/pull?since=$sinceVersion&limit=$limit';
    if (deviceId != null && deviceId.isNotEmpty) {
      uriStr += '&deviceId=$deviceId';
    }
    final Uri pullUri = Uri.parse(uriStr);

    try {
      final response = await _httpClient.get(
        pullUri,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $authToken',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 401) {
        return SyncEnginePullResult(
          totalProcessed: 0,
          lastAppliedVersion: sinceVersion,
          hasMore: false,
          globalError: 'UNAUTHORIZED: 401 Invalid Token',
        );
      }

      if (response.statusCode != 200) {
        return SyncEnginePullResult(
          totalProcessed: 0,
          lastAppliedVersion: sinceVersion,
          hasMore: false,
          globalError: 'HTTP Error ${response.statusCode}',
        );
      }

      final responseMap = jsonDecode(response.body) as Map<String, dynamic>;
      final changesRaw = responseMap['changes'] as List?;
      final nextVersion = (responseMap['nextVersion'] as int?) ?? sinceVersion;
      final hasMore = (responseMap['hasMore'] as bool?) ?? false;

      if (changesRaw == null || changesRaw.isEmpty) {
        if (nextVersion > sinceVersion) {
          await _queueRepository.updateLastAppliedServerVersion(nextVersion);
        }
        return SyncEnginePullResult(
          totalProcessed: 0,
          lastAppliedVersion: nextVersion,
          hasMore: hasMore,
        );
      }

      final db = await _databaseService.database;

      // Apply pulled changes & advance cursor atomically in a single SQLite transaction
      await db.transaction((txn) async {
        for (final change in changesRaw) {
          if (change is! Map<String, dynamic>) continue;

          final entityType = change['entityType'] as String?;
          final entityId = change['entityId'] as String?;
          final operation = change['operation'] as String?;
          final originDeviceId = change['originDeviceId'] as String?;
          final payload = change['payload'] is Map<String, dynamic>
              ? change['payload'] as Map<String, dynamic>
              : <String, dynamic>{};

          if (entityType == null || entityId == null || operation == null) continue;

          // Own-Device Echo Check: Skip reapplying changes pushed by THIS device
          if (originDeviceId != null && deviceId != null && originDeviceId == deviceId) {
            continue;
          }

          // Check if local pending mutation exists for this entity
          final hasPending = await _queueRepository.hasPendingLocalMutation(entityType, entityId, txn: txn);
          if (hasPending) {
            // Preserving local unsynced pending edits for Phase 8.6 Conflict Resolution.
            // Admin status updates are applied to loan status field cleanly.
            if (entityType == 'loan' && payload.containsKey('status')) {
              await txn.update(
                'loans',
                {'status': payload['status']},
                where: 'id = ?',
                whereArgs: [entityId],
              );
            }
            continue;
          }

          if (entityType == 'loan') {
            final statusStr = payload['status'] as String? ?? 'pending';
            final priorityStr = payload['priority'] as String? ?? 'medium';

            final loan = LoanModel(
              id: entityId,
              userId: payload['userId'] as String? ?? '',
              userName: payload['userName'] as String? ?? 'User',
              amount: (payload['amount'] as num?)?.toDouble() ?? 0.0,
              tenureMonths: (payload['tenureMonths'] as int?) ?? 12,
              purpose: payload['purpose'] as String? ?? '',
              priority: LoanPriority.values.firstWhere(
                (p) => p.name == priorityStr,
                orElse: () => LoanPriority.medium,
              ),
              status: LoanStatus.values.firstWhere(
                (s) => s.name == statusStr,
                orElse: () => LoanStatus.pending,
              ),
              createdAt: payload['createdAt'] != null
                  ? DateTime.parse(payload['createdAt'] as String)
                  : DateTime.now(),
            );

            await _loanRepository.applyServerLoan(loan, operation, txn: txn);
          } else if (entityType == 'loan_activity') {
            if (operation == 'CREATE' || operation == 'UPDATE') {
              await txn.insert(
                'loan_activities',
                {
                  'id': entityId,
                  'loanId': payload['loanId'] ?? 'UNKNOWN',
                  'userId': payload['userId'] ?? '',
                  'userName': payload['userName'] ?? 'User',
                  'type': payload['type'] ?? 'system',
                  'message': payload['message'] ?? '',
                  'createdAt': payload['createdAt'] ?? DateTime.now().toIso8601String(),
                },
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
            } else if (operation == 'DELETE') {
              await txn.delete('loan_activities', where: 'id = ?', whereArgs: [entityId]);
            }
          } else if (entityType == 'notification') {
            if (operation == 'CREATE' || operation == 'UPDATE') {
              await txn.insert(
                'notifications',
                {
                  'id': entityId,
                  'userId': payload['userId'] ?? '',
                  'title': payload['title'] ?? '',
                  'message': payload['message'] ?? '',
                  'type': payload['type'] ?? 'system',
                  'loanId': payload['loanId'],
                  'createdAt': payload['createdAt'] ?? DateTime.now().toIso8601String(),
                  'isRead': (payload['isRead'] == true || payload['isRead'] == 1) ? 1 : 0,
                },
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
            } else if (operation == 'DELETE') {
              await txn.delete('notifications', where: 'id = ?', whereArgs: [entityId]);
            }
          }
        }

        // Update local cursor in the SAME transaction
        await _queueRepository.updateLastAppliedServerVersion(nextVersion, txn: txn);
      });

      return SyncEnginePullResult(
        totalProcessed: changesRaw.length,
        lastAppliedVersion: nextVersion,
        hasMore: hasMore,
      );
    } catch (e) {
      return SyncEnginePullResult(
        totalProcessed: 0,
        lastAppliedVersion: sinceVersion,
        hasMore: false,
        globalError: e.toString(),
      );
    }
  }
}

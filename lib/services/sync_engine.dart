import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../repositories/sync_queue_repository.dart';

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

/// Synchronization Engine managing Device -> Server push sync operations.
class SyncEngine {
  final SyncQueueRepository _queueRepository;
  final http.Client _httpClient;

  SyncEngine({
    SyncQueueRepository? queueRepository,
    http.Client? httpClient,
  })  : _queueRepository = queueRepository ?? LocalSyncQueueRepository(),
        _httpClient = httpClient ?? http.Client();

  /// Push local PENDING_SYNC operations to the central backend.
  Future<SyncEngineResult> pushPending({
    required String baseUrl,
    required String authToken,
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
        // Authentication error: Revert items to PENDING_SYNC without extra retry penalty
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
        // Authorization / Business rejection: Mark items as CONFLICT to prevent infinite retries
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
        // Transient server errors (500, 502, 503, 504): Increment retry count and preserve queue items
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
        } else if (status == 'CONFLICT' || status == 'FORBIDDEN') {
          await _queueRepository.updateStatus(item.id, 'CONFLICT', error: message ?? 'Conflict');
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
      // Catch SocketException, TimeoutException, etc.
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
}

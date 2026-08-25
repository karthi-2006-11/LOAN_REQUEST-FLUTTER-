import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Represents a queued local business mutation waiting to be synchronized with the central backend.
class SyncQueueItem {
  final String id;
  final String entityType; // 'loan', 'loan_activity', 'notification'
  final String entityId;
  final String operation; // 'CREATE', 'UPDATE', 'DELETE'
  final Map<String, dynamic> payload;
  final String clientOperationId;
  final DateTime createdAt;
  final int retryCount;
  final DateTime? lastAttemptAt;
  final String status; // 'PENDING_SYNC', 'SYNCING', 'SYNCED', 'SYNC_FAILED', 'CONFLICT'
  final String? error;

  SyncQueueItem({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.payload,
    required this.clientOperationId,
    required this.createdAt,
    this.retryCount = 0,
    this.lastAttemptAt,
    this.status = 'PENDING_SYNC',
    this.error,
  });

  SyncQueueItem copyWith({
    int? retryCount,
    DateTime? lastAttemptAt,
    String? status,
    String? error,
  }) {
    return SyncQueueItem(
      id: id,
      entityType: entityType,
      entityId: entityId,
      operation: operation,
      payload: payload,
      clientOperationId: clientOperationId,
      createdAt: createdAt,
      retryCount: retryCount ?? this.retryCount,
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
      status: status ?? this.status,
      error: error ?? this.error,
    );
  }

  Map<String, dynamic> toSqlMap() {
    return {
      'id': id,
      'entityType': entityType,
      'entityId': entityId,
      'operation': operation,
      'payload': jsonEncode(payload),
      'clientOperationId': clientOperationId,
      'createdAt': createdAt.toIso8601String(),
      'retryCount': retryCount,
      'lastAttemptAt': lastAttemptAt?.toIso8601String(),
      'status': status,
      'error': error,
    };
  }

  factory SyncQueueItem.fromSqlMap(Map<String, dynamic> map) {
    return SyncQueueItem(
      id: map['id'] as String,
      entityType: map['entityType'] as String,
      entityId: map['entityId'] as String,
      operation: map['operation'] as String,
      payload: jsonDecode(map['payload'] as String) as Map<String, dynamic>,
      clientOperationId: map['clientOperationId'] as String,
      createdAt: DateTime.parse(map['createdAt'] as String),
      retryCount: (map['retryCount'] as int?) ?? 0,
      lastAttemptAt: map['lastAttemptAt'] != null
          ? DateTime.parse(map['lastAttemptAt'] as String)
          : null,
      status: map['status'] as String? ?? 'PENDING_SYNC',
      error: map['error'] as String?,
    );
  }

  /// Generate a deterministic UUID v4 string for client operations
  static String generateClientOperationId(String prefix) {
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final random = sha256.convert(utf8.encode('$prefix-$timestamp')).toString().substring(0, 16);
    return 'OP-$prefix-$timestamp-$random';
  }
}

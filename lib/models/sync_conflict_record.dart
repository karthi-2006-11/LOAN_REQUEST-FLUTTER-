import 'dart:convert';

/// Model representing a persistent local conflict record in sync_conflicts table.
class SyncConflictRecord {
  final String id;
  final String clientOperationId;
  final String entityType;
  final String entityId;
  final String conflictType;
  final Map<String, dynamic> localValue;
  final Map<String, dynamic> serverValue;
  final int serverVersion;
  final DateTime createdAt;
  final DateTime? resolvedAt;
  final String? resolution;

  SyncConflictRecord({
    required this.id,
    required this.clientOperationId,
    required this.entityType,
    required this.entityId,
    required this.conflictType,
    required this.localValue,
    required this.serverValue,
    required this.serverVersion,
    required this.createdAt,
    this.resolvedAt,
    this.resolution,
  });

  Map<String, dynamic> toSqlMap() {
    return {
      'id': id,
      'clientOperationId': clientOperationId,
      'entityType': entityType,
      'entityId': entityId,
      'conflictType': conflictType,
      'localValue': jsonEncode(localValue),
      'serverValue': jsonEncode(serverValue),
      'serverVersion': serverVersion,
      'createdAt': createdAt.toIso8601String(),
      'resolvedAt': resolvedAt?.toIso8601String(),
      'resolution': resolution,
    };
  }

  factory SyncConflictRecord.fromSqlMap(Map<String, dynamic> map) {
    return SyncConflictRecord(
      id: map['id'] as String,
      clientOperationId: map['clientOperationId'] as String,
      entityType: map['entityType'] as String,
      entityId: map['entityId'] as String,
      conflictType: map['conflictType'] as String,
      localValue: jsonDecode(map['localValue'] as String) as Map<String, dynamic>,
      serverValue: jsonDecode(map['serverValue'] as String) as Map<String, dynamic>,
      serverVersion: (map['serverVersion'] as int?) ?? 0,
      createdAt: DateTime.parse(map['createdAt'] as String),
      resolvedAt: map['resolvedAt'] != null ? DateTime.parse(map['resolvedAt'] as String) : null,
      resolution: map['resolution'] as String?,
    );
  }
}

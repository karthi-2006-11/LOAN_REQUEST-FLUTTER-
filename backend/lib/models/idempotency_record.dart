class IdempotencyRecord {
  final String clientOperationId;
  final String entityId;
  final String operationType;
  final int responseCode;
  final String responsePayload;
  final DateTime createdAt;

  IdempotencyRecord({
    required this.clientOperationId,
    required this.entityId,
    required this.operationType,
    required this.responseCode,
    required this.responsePayload,
    required this.createdAt,
  });

  Map<String, dynamic> toSqlMap() => {
        'clientOperationId': clientOperationId,
        'entityId': entityId,
        'operationType': operationType,
        'responseCode': responseCode,
        'responsePayload': responsePayload,
        'createdAt': createdAt.toIso8601String(),
      };

  factory IdempotencyRecord.fromSqlMap(Map<String, dynamic> map) {
    return IdempotencyRecord(
      clientOperationId: map['clientOperationId'] as String,
      entityId: map['entityId'] as String,
      operationType: map['operationType'] as String,
      responseCode: map['responseCode'] as int,
      responsePayload: map['responsePayload'] as String,
      createdAt: DateTime.parse(map['createdAt'] as String),
    );
  }
}

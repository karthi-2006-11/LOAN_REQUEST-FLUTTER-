/// The 9 established conflict categories for BlackVault synchronization.
enum ConflictCategory {
  noConflict,
  alreadyApplied,
  ownDeviceEcho,
  customerFieldConflict,
  adminStatusOverride,
  splitOwnershipMerge,
  stalePush,
  updateDeleteConflict,
  invalidMutation,
}

/// Authority assignment for a classified synchronization situation.
enum ConflictAuthority {
  customer,
  admin,
  split,
  server,
  none,
}

/// Input DTO for the pure ConflictClassifier decision engine.
class ConflictClassificationInput {
  final String entityType;
  final String entityId;
  final String operation; // 'CREATE', 'UPDATE', 'DELETE'
  final Map<String, dynamic> localPayload;
  final Map<String, dynamic>? serverState;
  final int? baseVersion;
  final int? serverVersion;
  final String? originDeviceId;
  final String? clientDeviceId;
  final bool isProcessedIdempotent;
  final String? userRole; // 'CUSTOMER', 'ADMIN'

  ConflictClassificationInput({
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.localPayload,
    this.serverState,
    this.baseVersion,
    this.serverVersion,
    this.originDeviceId,
    this.clientDeviceId,
    this.isProcessedIdempotent = false,
    this.userRole,
  });
}

/// Output DTO returned by ConflictClassifier.
class ConflictClassificationResult {
  final ConflictCategory category;
  final String reason;
  final bool isRealConflict;
  final ConflictAuthority authority;
  final bool requiresResolutionEngine;

  ConflictClassificationResult({
    required this.category,
    required this.reason,
    required this.isRealConflict,
    required this.authority,
    required this.requiresResolutionEngine,
  });
}

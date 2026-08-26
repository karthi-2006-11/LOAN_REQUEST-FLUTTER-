import 'conflict_classification_models.dart';

/// Established resolution strategies for BlackVault conflict handling.
enum ResolutionOutcome {
  noAction,
  customerWins,
  serverWins,
  fieldMerge,
  unresolved,
  rejected,
}

/// Input DTO for the pure ConflictResolver decision service.
class ConflictResolutionInput {
  final ConflictCategory category;
  final String entityType;
  final String entityId;
  final String operation;
  final Map<String, dynamic> localPayload;
  final Map<String, dynamic>? serverState;
  final int? baseVersion;
  final int? serverVersion;
  final String? userRole;
  final int retryCount;

  ConflictResolutionInput({
    required this.category,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.localPayload,
    this.serverState,
    this.baseVersion,
    this.serverVersion,
    this.userRole,
    this.retryCount = 0,
  });
}

/// Immutable result model produced by ConflictResolver.
class ConflictResolutionResult {
  final ResolutionOutcome resolution;
  final Map<String, dynamic>? resolvedPayload;
  final String reason;
  final ConflictAuthority authority;
  final int? recommendedBaseVersion;
  final bool requiresNewClientOperationId;
  final bool requiresRequeue;
  final bool requiresManualReview;

  ConflictResolutionResult({
    required this.resolution,
    this.resolvedPayload,
    required this.reason,
    required this.authority,
    this.recommendedBaseVersion,
    this.requiresNewClientOperationId = false,
    this.requiresRequeue = false,
    this.requiresManualReview = false,
  });
}

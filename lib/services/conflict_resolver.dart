import '../models/conflict_classification_models.dart';
import '../models/conflict_resolution_models.dart';
import '../models/loan_field_ownership.dart';

/// Pure, side-effect-free Conflict Resolver service for BlackVault.
class ConflictResolver {
  /// Resolves a classified conflict situation into a deterministic resolution strategy.
  ///
  /// This function performs NO database writes, NO HTTP calls, NO queue mutations,
  /// and NO side effects. Same input always produces identical output.
  ConflictResolutionResult resolve(ConflictResolutionInput input) {
    // 1. Conflict Loop Prevention: Check max retries (>= 3)
    if (input.retryCount >= 3) {
      return ConflictResolutionResult(
        resolution: ResolutionOutcome.unresolved,
        resolvedPayload: input.serverState,
        reason: 'Max retries (${input.retryCount}) exceeded; requires human manual review',
        authority: ConflictAuthority.none,
        requiresManualReview: true,
        requiresRequeue: false,
      );
    }

    // 2. No Action Categories
    if (input.category == ConflictCategory.noConflict ||
        input.category == ConflictCategory.alreadyApplied ||
        input.category == ConflictCategory.ownDeviceEcho) {
      return ConflictResolutionResult(
        resolution: ResolutionOutcome.noAction,
        reason: 'No resolution required for ${input.category.name}',
        authority: ConflictAuthority.none,
        requiresRequeue: false,
      );
    }

    // 3. Invalid Mutation / Illegal Status Edit / Identity Tampering
    if (input.category == ConflictCategory.invalidMutation) {
      return ConflictResolutionResult(
        resolution: ResolutionOutcome.rejected,
        reason: 'Invalid mutation rejected: Unauthorized or malformed operation',
        authority: ConflictAuthority.server,
        requiresRequeue: false,
      );
    }

    final serverState = input.serverState ?? {};
    final serverStatus = (serverState['status'] as String?) ?? 'pending';
    final targetServerVersion = input.serverVersion ?? (serverState['version'] as int?) ?? 1;

    // Security Check: Explicit Identity Tampering (local payload attempting to change id, userId, or createdAt)
    if (input.localPayload.containsKey('id') &&
        serverState.containsKey('id') &&
        input.localPayload['id'] != serverState['id']) {
      return ConflictResolutionResult(
        resolution: ResolutionOutcome.rejected,
        reason: 'Forbidden: Cannot alter immutable entity id',
        authority: ConflictAuthority.server,
        requiresRequeue: false,
      );
    }

    if (input.localPayload.containsKey('userId') &&
        serverState.containsKey('userId') &&
        input.localPayload['userId'] != serverState['userId']) {
      return ConflictResolutionResult(
        resolution: ResolutionOutcome.rejected,
        reason: 'Forbidden: Cannot alter immutable entity userId',
        authority: ConflictAuthority.server,
        requiresRequeue: false,
      );
    }

    if (input.localPayload.containsKey('createdAt') &&
        serverState.containsKey('createdAt') &&
        input.localPayload['createdAt'] != serverState['createdAt']) {
      return ConflictResolutionResult(
        resolution: ResolutionOutcome.rejected,
        reason: 'Forbidden: Cannot alter immutable entity createdAt timestamp',
        authority: ConflictAuthority.server,
        requiresRequeue: false,
      );
    }

    // 4. Update / Delete Conflict
    // Note: BlackVault data model does NOT support entity deletion.
    if (input.category == ConflictCategory.updateDeleteConflict) {
      return ConflictResolutionResult(
        resolution: ResolutionOutcome.unresolved,
        resolvedPayload: input.serverState,
        reason: 'Entity deletion is not supported by current BlackVault data model',
        authority: ConflictAuthority.server,
        requiresManualReview: true,
        requiresRequeue: false,
      );
    }

    // 5. Admin Status Override
    if (input.category == ConflictCategory.adminStatusOverride) {
      return ConflictResolutionResult(
        resolution: ResolutionOutcome.serverWins,
        resolvedPayload: serverState,
        reason: 'Server loan status is final ($serverStatus); customer edit rejected',
        authority: ConflictAuthority.admin,
        recommendedBaseVersion: targetServerVersion,
        requiresRequeue: false,
      );
    }

    // 6. Customer Field Conflict while loan is pending
    if (input.category == ConflictCategory.customerFieldConflict) {
      if (serverStatus != 'pending') {
        // Safety rule: Never allow old customer edits to overwrite finalized server state
        return ConflictResolutionResult(
          resolution: ResolutionOutcome.serverWins,
          resolvedPayload: serverState,
          reason: 'Server loan is no longer pending ($serverStatus); customer edit discarded',
          authority: ConflictAuthority.admin,
          recommendedBaseVersion: targetServerVersion,
          requiresRequeue: false,
        );
      }

      // Customer payload wins for customer-owned fields
      final resolvedPayload = Map<String, dynamic>.from(serverState);
      for (final key in input.localPayload.keys) {
        if (LoanFieldOwnership.isCustomerOwned(key)) {
          resolvedPayload[key] = input.localPayload[key];
        }
      }

      // Security Check: Enforce server identity immutability
      if (serverState.containsKey('id')) resolvedPayload['id'] = serverState['id'];
      if (serverState.containsKey('userId')) resolvedPayload['userId'] = serverState['userId'];
      if (serverState.containsKey('createdAt')) resolvedPayload['createdAt'] = serverState['createdAt'];

      return ConflictResolutionResult(
        resolution: ResolutionOutcome.customerWins,
        resolvedPayload: resolvedPayload,
        reason: 'Customer-owned fields applied over pending server loan',
        authority: ConflictAuthority.customer,
        recommendedBaseVersion: targetServerVersion,
        requiresNewClientOperationId: true,
        requiresRequeue: true,
      );
    }

    // 7. Split Ownership Merge
    if (input.category == ConflictCategory.splitOwnershipMerge) {
      final mergedPayload = Map<String, dynamic>.from(serverState);

      if (serverStatus == 'pending') {
        for (final key in input.localPayload.keys) {
          if (LoanFieldOwnership.isCustomerOwned(key)) {
            mergedPayload[key] = input.localPayload[key];
          }
        }
      }

      // Security Check: Enforce server identity immutability & admin status authority
      if (serverState.containsKey('id')) mergedPayload['id'] = serverState['id'];
      if (serverState.containsKey('userId')) mergedPayload['userId'] = serverState['userId'];
      if (serverState.containsKey('createdAt')) mergedPayload['createdAt'] = serverState['createdAt'];
      if (serverState.containsKey('status')) mergedPayload['status'] = serverState['status'];

      return ConflictResolutionResult(
        resolution: ResolutionOutcome.fieldMerge,
        resolvedPayload: mergedPayload,
        reason: 'Field-level merge: Preserved customer application fields + server admin status',
        authority: ConflictAuthority.split,
        recommendedBaseVersion: targetServerVersion,
        requiresNewClientOperationId: true,
        requiresRequeue: serverStatus == 'pending',
      );
    }

    // 8. Stale Push
    if (input.category == ConflictCategory.stalePush) {
      if (serverStatus != 'pending') {
        return ConflictResolutionResult(
          resolution: ResolutionOutcome.serverWins,
          resolvedPayload: serverState,
          reason: 'Stale push against finalized server loan ($serverStatus); server state wins',
          authority: ConflictAuthority.server,
          recommendedBaseVersion: targetServerVersion,
          requiresRequeue: false,
        );
      }

      final mergedPayload = Map<String, dynamic>.from(serverState);
      for (final key in input.localPayload.keys) {
        if (LoanFieldOwnership.isCustomerOwned(key)) {
          mergedPayload[key] = input.localPayload[key];
        }
      }

      // Security Check: Enforce server identity immutability
      if (serverState.containsKey('id')) mergedPayload['id'] = serverState['id'];
      if (serverState.containsKey('userId')) mergedPayload['userId'] = serverState['userId'];
      if (serverState.containsKey('createdAt')) mergedPayload['createdAt'] = serverState['createdAt'];

      return ConflictResolutionResult(
        resolution: ResolutionOutcome.fieldMerge,
        resolvedPayload: mergedPayload,
        reason: 'Stale push resolved via field-level merge against pending server state (v$targetServerVersion)',
        authority: ConflictAuthority.split,
        recommendedBaseVersion: targetServerVersion,
        requiresNewClientOperationId: true,
        requiresRequeue: true,
      );
    }

    // 9. Fallback Unresolved
    return ConflictResolutionResult(
      resolution: ResolutionOutcome.unresolved,
      resolvedPayload: input.serverState,
      reason: 'Unhandled conflict situation requires manual review',
      authority: ConflictAuthority.none,
      requiresManualReview: true,
      requiresRequeue: false,
    );
  }
}

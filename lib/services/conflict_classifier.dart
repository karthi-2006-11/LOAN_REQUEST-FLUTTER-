import '../models/conflict_classification_models.dart';
import '../models/loan_field_ownership.dart';

/// Pure, side-effect-free Conflict Classifier decision service for BlackVault.
class ConflictClassifier {
  /// Classifies a synchronization situation into exactly one primary ConflictCategory
  /// according to strict, deterministic precedence rules.
  ///
  /// This function performs NO database writes, NO HTTP calls, and NO side effects.
  ConflictClassificationResult classify(ConflictClassificationInput input) {
    // 1. Idempotency Replay (Precedence 1)
    if (input.isProcessedIdempotent) {
      return ConflictClassificationResult(
        category: ConflictCategory.alreadyApplied,
        reason: 'Operation already processed on backend via idempotency record',
        isRealConflict: false,
        authority: ConflictAuthority.server,
        requiresResolutionEngine: false,
      );
    }

    // 2. Own-Device Echo (Precedence 2)
    if (input.originDeviceId != null &&
        input.clientDeviceId != null &&
        input.originDeviceId == input.clientDeviceId) {
      return ConflictClassificationResult(
        category: ConflictCategory.ownDeviceEcho,
        reason: 'Pulled mutation originated from this device',
        isRealConflict: false,
        authority: ConflictAuthority.customer,
        requiresResolutionEngine: false,
      );
    }

    // 3. Invalid Mutation / Business Rule Violation (Precedence 3)
    final supportedEntities = {'loan', 'loan_activity', 'notification'};
    final supportedOps = {'CREATE', 'UPDATE', 'DELETE'};

    if (!supportedEntities.contains(input.entityType) ||
        !supportedOps.contains(input.operation)) {
      return ConflictClassificationResult(
        category: ConflictCategory.invalidMutation,
        reason: 'Unsupported entity type (${input.entityType}) or operation (${input.operation})',
        isRealConflict: true,
        authority: ConflictAuthority.server,
        requiresResolutionEngine: false,
      );
    }

    if (input.entityType == 'loan' &&
        input.userRole != 'ADMIN' &&
        input.localPayload.containsKey('status')) {
      return ConflictClassificationResult(
        category: ConflictCategory.invalidMutation,
        reason: 'Forbidden: Customers cannot alter loan status',
        isRealConflict: true,
        authority: ConflictAuthority.admin,
        requiresResolutionEngine: false,
      );
    }

    // 4. Update/Delete Conflict (Precedence 4)
    // Note: Customer loan deletion is unsupported in BlackVault.
    if (input.entityType == 'loan' && input.operation == 'DELETE') {
      return ConflictClassificationResult(
        category: ConflictCategory.updateDeleteConflict,
        reason: 'Unsupported deletion mutation on loan entity',
        isRealConflict: true,
        authority: ConflictAuthority.server,
        requiresResolutionEngine: true,
      );
    }

    if (input.serverState != null && input.serverState!['isDeleted'] == true) {
      return ConflictClassificationResult(
        category: ConflictCategory.updateDeleteConflict,
        reason: 'Local operation targets an entity marked deleted on server',
        isRealConflict: true,
        authority: ConflictAuthority.server,
        requiresResolutionEngine: true,
      );
    }

    // Server State & Field Collision Inspections for Loans
    if (input.entityType == 'loan' && input.serverState != null) {
      final serverStatus = (input.serverState!['status'] as String?) ?? 'pending';
      final hasCustomerLocalFields = LoanFieldOwnership.hasCustomerFields(input.localPayload);

      if (hasCustomerLocalFields) {
        // Check if customer-owned fields differ between local payload and server state
        bool customerFieldsDiffer = false;
        for (final key in input.localPayload.keys) {
          if (LoanFieldOwnership.isCustomerOwned(key)) {
            final localVal = input.localPayload[key];
            final serverVal = input.serverState![key];
            if (serverVal != null && localVal != serverVal) {
              customerFieldsDiffer = true;
              break;
            }
          }
        }

        // A. Same Customer Field Conflict (Precedence 5A)
        // Both customer local edit and server state modified customer fields differently while loan is pending
        if (customerFieldsDiffer && serverStatus == 'pending') {
          return ConflictClassificationResult(
            category: ConflictCategory.customerFieldConflict,
            reason: 'Customer-owned fields differ between local payload and pending server loan',
            isRealConflict: true,
            authority: ConflictAuthority.customer,
            requiresResolutionEngine: true,
          );
        }

        // B. Admin Status Override (Precedence 5B)
        // Customer edited customer fields differently, but server status is finalized (approved/rejected)
        if (customerFieldsDiffer && serverStatus != 'pending') {
          return ConflictClassificationResult(
            category: ConflictCategory.adminStatusOverride,
            reason: 'Server loan status is final ($serverStatus); customer edit overrides admin decision',
            isRealConflict: true,
            authority: ConflictAuthority.admin,
            requiresResolutionEngine: true,
          );
        }

        // C. Split Ownership Merge (Precedence 5C)
        // Customer edited customer fields (amount/purpose), while server state updated admin status (approved/rejected)
        // and customer fields themselves do not collide (or reflect independent ownership edits)
        if (!customerFieldsDiffer && serverStatus != 'pending') {
          return ConflictClassificationResult(
            category: ConflictCategory.splitOwnershipMerge,
            reason: 'Customer updated application fields while server updated loan status to $serverStatus',
            isRealConflict: true,
            authority: ConflictAuthority.split,
            requiresResolutionEngine: true,
          );
        }
      }
    }

    // 8. Stale Push (Precedence 8)
    // Version mismatch where local payload values do not directly collide on fields
    if (input.baseVersion != null &&
        input.serverVersion != null &&
        input.baseVersion! < input.serverVersion!) {
      return ConflictClassificationResult(
        category: ConflictCategory.stalePush,
        reason: 'Local baseVersion (${input.baseVersion}) is behind server version (${input.serverVersion})',
        isRealConflict: true,
        authority: ConflictAuthority.server,
        requiresResolutionEngine: true,
      );
    }

    // 9. Clean Sync / No Conflict (Precedence 9)
    return ConflictClassificationResult(
      category: ConflictCategory.noConflict,
      reason: 'No overlapping mutation or version conflict detected',
      isRealConflict: false,
      authority: ConflictAuthority.none,
      requiresResolutionEngine: false,
    );
  }
}

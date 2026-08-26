import 'package:flutter_test/flutter_test.dart';
import 'package:loan_request_app/models/conflict_classification_models.dart';
import 'package:loan_request_app/models/conflict_resolution_models.dart';
import 'package:loan_request_app/services/conflict_resolver.dart';

void main() {
  late ConflictResolver resolver;

  setUp(() {
    resolver = ConflictResolver();
  });

  group('ConflictResolver Surgical Unit Tests & Security Verification', () {
    test('1. NO_CONFLICT returns NO_ACTION', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.noConflict,
        entityType: 'loan',
        entityId: 'LOAN-1',
        operation: 'CREATE',
        localPayload: {'amount': 10000.0},
      );

      final result = resolver.resolve(input);
      expect(result.resolution, equals(ResolutionOutcome.noAction));
      expect(result.requiresRequeue, isFalse);
    });

    test('2. ALREADY_APPLIED returns NO_ACTION', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.alreadyApplied,
        entityType: 'loan',
        entityId: 'LOAN-1',
        operation: 'UPDATE',
        localPayload: {'amount': 10000.0},
      );

      final result = resolver.resolve(input);
      expect(result.resolution, equals(ResolutionOutcome.noAction));
      expect(result.requiresRequeue, isFalse);
    });

    test('3. OWN_DEVICE_ECHO returns NO_ACTION', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.ownDeviceEcho,
        entityType: 'loan',
        entityId: 'LOAN-1',
        operation: 'UPDATE',
        localPayload: {'amount': 10000.0},
      );

      final result = resolver.resolve(input);
      expect(result.resolution, equals(ResolutionOutcome.noAction));
      expect(result.requiresRequeue, isFalse);
    });

    test('4. Customer status=approved mutation returns REJECTED', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.invalidMutation,
        entityType: 'loan',
        entityId: 'LOAN-1',
        operation: 'UPDATE',
        localPayload: {'status': 'approved'},
        userRole: 'CUSTOMER',
      );

      final result = resolver.resolve(input);
      expect(result.resolution, equals(ResolutionOutcome.rejected));
      expect(result.requiresRequeue, isFalse);
      expect(result.requiresManualReview, isFalse);
    });

    test('5. Customer status=rejected mutation returns REJECTED', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.invalidMutation,
        entityType: 'loan',
        entityId: 'LOAN-1',
        operation: 'UPDATE',
        localPayload: {'status': 'rejected'},
        userRole: 'CUSTOMER',
      );

      final result = resolver.resolve(input);
      expect(result.resolution, equals(ResolutionOutcome.rejected));
      expect(result.requiresRequeue, isFalse);
    });

    test('6. Explicit id tampering attempt returns REJECTED', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.customerFieldConflict,
        entityType: 'loan',
        entityId: 'LOAN-SERVER-ID',
        operation: 'UPDATE',
        localPayload: {'id': 'LOAN-TAMPERED-ID', 'amount': 20000.0},
        serverState: {'id': 'LOAN-SERVER-ID', 'status': 'pending', 'version': 2},
        serverVersion: 2,
      );

      final result = resolver.resolve(input);
      expect(result.resolution, equals(ResolutionOutcome.rejected));
      expect(result.requiresRequeue, isFalse);
    });

    test('7. Explicit userId tampering attempt returns REJECTED', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.customerFieldConflict,
        entityType: 'loan',
        entityId: 'LOAN-1',
        operation: 'UPDATE',
        localPayload: {'userId': 'USER-ATTACKER', 'amount': 20000.0},
        serverState: {'id': 'LOAN-1', 'userId': 'USER-VICTIM', 'status': 'pending', 'version': 2},
        serverVersion: 2,
      );

      final result = resolver.resolve(input);
      expect(result.resolution, equals(ResolutionOutcome.rejected));
      expect(result.requiresRequeue, isFalse);
    });

    test('8. Explicit createdAt tampering attempt returns REJECTED', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.customerFieldConflict,
        entityType: 'loan',
        entityId: 'LOAN-1',
        operation: 'UPDATE',
        localPayload: {'createdAt': '2099-01-01T00:00:00Z', 'amount': 20000.0},
        serverState: {'id': 'LOAN-1', 'createdAt': '2026-01-01T00:00:00Z', 'status': 'pending', 'version': 2},
        serverVersion: 2,
      );

      final result = resolver.resolve(input);
      expect(result.resolution, equals(ResolutionOutcome.rejected));
      expect(result.requiresRequeue, isFalse);
    });

    test('9. Legitimate field merge preserves immutable server fields', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.splitOwnershipMerge,
        entityType: 'loan',
        entityId: 'LOAN-1',
        operation: 'UPDATE',
        localPayload: {'amount': 20000.0},
        serverState: {
          'id': 'LOAN-1',
          'userId': 'USER-100',
          'createdAt': '2026-01-01T00:00:00Z',
          'amount': 15000.0,
          'status': 'pending',
          'version': 3
        },
        serverVersion: 3,
      );

      final result = resolver.resolve(input);
      expect(result.resolution, equals(ResolutionOutcome.fieldMerge));
      expect(result.resolvedPayload!['id'], equals('LOAN-1'));
      expect(result.resolvedPayload!['userId'], equals('USER-100'));
      expect(result.resolvedPayload!['createdAt'], equals('2026-01-01T00:00:00Z'));
      expect(result.resolvedPayload!['amount'], equals(20000.0));
    });

    test('10. UPDATE_DELETE_CONFLICT with unsupported deletion returns UNRESOLVED with manual review', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.updateDeleteConflict,
        entityType: 'loan',
        entityId: 'LOAN-1',
        operation: 'DELETE',
        localPayload: {},
      );

      final result = resolver.resolve(input);
      expect(result.resolution, equals(ResolutionOutcome.unresolved));
      expect(result.requiresManualReview, isTrue);
      expect(result.requiresRequeue, isFalse);
    });

    test('11. CUSTOMER_FIELD_CONFLICT amount + pending returns CUSTOMER_WINS', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.customerFieldConflict,
        entityType: 'loan',
        entityId: 'LOAN-1',
        operation: 'UPDATE',
        localPayload: {'amount': 20000.0},
        serverState: {'id': 'LOAN-1', 'amount': 15000.0, 'status': 'pending', 'version': 2},
        serverVersion: 2,
      );

      final result = resolver.resolve(input);
      expect(result.resolution, equals(ResolutionOutcome.customerWins));
      expect(result.resolvedPayload!['amount'], equals(20000.0));
      expect(result.recommendedBaseVersion, equals(2));
      expect(result.requiresNewClientOperationId, isTrue);
      expect(result.requiresRequeue, isTrue);
    });

    test('12. CUSTOMER_FIELD_CONFLICT + approved loan returns SERVER_WINS (Safety rule)', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.customerFieldConflict,
        entityType: 'loan',
        entityId: 'LOAN-1',
        operation: 'UPDATE',
        localPayload: {'amount': 20000.0},
        serverState: {'id': 'LOAN-1', 'amount': 15000.0, 'status': 'approved', 'version': 2},
        serverVersion: 2,
      );

      final result = resolver.resolve(input);
      expect(result.resolution, equals(ResolutionOutcome.serverWins));
      expect(result.resolvedPayload!['status'], equals('approved'));
      expect(result.requiresRequeue, isFalse);
    });

    test('13. CUSTOMER_FIELD_CONFLICT + rejected loan returns SERVER_WINS (Safety rule)', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.customerFieldConflict,
        entityType: 'loan',
        entityId: 'LOAN-1',
        operation: 'UPDATE',
        localPayload: {'amount': 20000.0},
        serverState: {'id': 'LOAN-1', 'amount': 15000.0, 'status': 'rejected', 'version': 2},
        serverVersion: 2,
      );

      final result = resolver.resolve(input);
      expect(result.resolution, equals(ResolutionOutcome.serverWins));
      expect(result.resolvedPayload!['status'], equals('rejected'));
      expect(result.requiresRequeue, isFalse);
    });

    test('14. SPLIT_OWNERSHIP_MERGE returns FIELD_MERGE', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.splitOwnershipMerge,
        entityType: 'loan',
        entityId: 'LOAN-1',
        operation: 'UPDATE',
        localPayload: {'amount': 20000.0, 'purpose': 'Expansion'},
        serverState: {'id': 'LOAN-1', 'amount': 15000.0, 'status': 'pending', 'version': 3},
        serverVersion: 3,
      );

      final result = resolver.resolve(input);
      expect(result.resolution, equals(ResolutionOutcome.fieldMerge));
      expect(result.authority, equals(ConflictAuthority.split));
      expect(result.recommendedBaseVersion, equals(3));
      expect(result.requiresNewClientOperationId, isTrue);
    });

    test('15. STALE_PUSH with pending loan returns FIELD_MERGE and requiresNewClientOperationId', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.stalePush,
        entityType: 'loan',
        entityId: 'LOAN-1',
        operation: 'UPDATE',
        localPayload: {'amount': 20000.0},
        serverState: {'id': 'LOAN-1', 'amount': 15000.0, 'status': 'pending', 'version': 2},
        baseVersion: 1,
        serverVersion: 2,
      );

      final result = resolver.resolve(input);
      expect(result.resolution, equals(ResolutionOutcome.fieldMerge));
      expect(result.recommendedBaseVersion, equals(2));
      expect(result.requiresNewClientOperationId, isTrue);
      expect(result.requiresRequeue, isTrue);
    });

    test('16. STALE_PUSH with finalized server status returns SERVER_WINS', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.stalePush,
        entityType: 'loan',
        entityId: 'LOAN-1',
        operation: 'UPDATE',
        localPayload: {'amount': 20000.0},
        serverState: {'id': 'LOAN-1', 'amount': 15000.0, 'status': 'approved', 'version': 2},
        baseVersion: 1,
        serverVersion: 2,
      );

      final result = resolver.resolve(input);
      expect(result.resolution, equals(ResolutionOutcome.serverWins));
      expect(result.requiresRequeue, isFalse);
    });

    test('17. Conflict Loop Prevention: retryCount >= 3 returns unresolved with requiresManualReview', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.customerFieldConflict,
        entityType: 'loan',
        entityId: 'LOAN-1',
        operation: 'UPDATE',
        localPayload: {'amount': 20000.0},
        serverState: {'id': 'LOAN-1', 'amount': 15000.0, 'status': 'pending', 'version': 5},
        serverVersion: 5,
        retryCount: 3,
      );

      final result = resolver.resolve(input);
      expect(result.resolution, equals(ResolutionOutcome.unresolved));
      expect(result.requiresManualReview, isTrue);
      expect(result.requiresRequeue, isFalse);
    });

    test('18. Determinism & Purity: Repeated calls with same input produce identical results without side effects', () {
      final input = ConflictResolutionInput(
        category: ConflictCategory.customerFieldConflict,
        entityType: 'loan',
        entityId: 'LOAN-1',
        operation: 'UPDATE',
        localPayload: {'amount': 20000.0},
        serverState: {'id': 'LOAN-1', 'amount': 15000.0, 'status': 'pending', 'version': 2},
        serverVersion: 2,
      );

      final res1 = resolver.resolve(input);
      final res2 = resolver.resolve(input);

      expect(res1.resolution, equals(res2.resolution));
      expect(res1.reason, equals(res2.reason));
      expect(res1.authority, equals(res2.authority));
      expect(res1.recommendedBaseVersion, equals(res2.recommendedBaseVersion));
      expect(res1.requiresNewClientOperationId, equals(res2.requiresNewClientOperationId));
      expect(res1.requiresRequeue, equals(res2.requiresRequeue));
    });
  });
}

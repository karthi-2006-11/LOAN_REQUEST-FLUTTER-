import 'package:flutter_test/flutter_test.dart';
import 'package:loan_request_app/models/conflict_classification_models.dart';
import 'package:loan_request_app/models/loan_field_ownership.dart';
import 'package:loan_request_app/services/conflict_classifier.dart';

void main() {
  late ConflictClassifier classifier;

  setUp(() {
    classifier = ConflictClassifier();
  });

  group('ConflictClassifier Reachability & Taxonomy Precedence Verification', () {
    test('1. LoanFieldOwnership helper correctly identifies field ownership categories', () {
      expect(LoanFieldOwnership.isCustomerOwned('amount'), isTrue);
      expect(LoanFieldOwnership.isCustomerOwned('tenureMonths'), isTrue);
      expect(LoanFieldOwnership.isCustomerOwned('purpose'), isTrue);
      expect(LoanFieldOwnership.isCustomerOwned('priority'), isTrue);

      expect(LoanFieldOwnership.isAdminOwned('status'), isTrue);

      expect(LoanFieldOwnership.isImmutable('id'), isTrue);
      expect(LoanFieldOwnership.isImmutable('userId'), isTrue);
      expect(LoanFieldOwnership.isImmutable('createdAt'), isTrue);
    });

    test('2. Reachability NO_CONFLICT: Disjoint entities or clean operation returns noConflict', () {
      final input = ConflictClassificationInput(
        entityType: 'loan',
        entityId: 'LOAN-CLEAN-001',
        operation: 'CREATE',
        localPayload: {'amount': 10000.0, 'purpose': 'Tools'},
        baseVersion: 1,
        serverVersion: 1,
      );

      final result = classifier.classify(input);
      expect(result.category, equals(ConflictCategory.noConflict));
      expect(result.isRealConflict, isFalse);
      expect(result.requiresResolutionEngine, isFalse);
    });

    test('3. Reachability ALREADY_APPLIED: Idempotency flag true returns alreadyApplied', () {
      final input = ConflictClassificationInput(
        entityType: 'loan',
        entityId: 'LOAN-IDEMP-001',
        operation: 'UPDATE',
        localPayload: {'amount': 5000.0},
        isProcessedIdempotent: true,
      );

      final result = classifier.classify(input);
      expect(result.category, equals(ConflictCategory.alreadyApplied));
      expect(result.isRealConflict, isFalse);
      expect(result.requiresResolutionEngine, isFalse);
    });

    test('4. Reachability OWN_DEVICE_ECHO: Matching originDeviceId and clientDeviceId returns ownDeviceEcho', () {
      final input = ConflictClassificationInput(
        entityType: 'loan',
        entityId: 'LOAN-ECHO-001',
        operation: 'UPDATE',
        localPayload: {'amount': 5000.0},
        originDeviceId: 'DEV-ALPHA-1',
        clientDeviceId: 'DEV-ALPHA-1',
      );

      final result = classifier.classify(input);
      expect(result.category, equals(ConflictCategory.ownDeviceEcho));
      expect(result.isRealConflict, isFalse);
      expect(result.requiresResolutionEngine, isFalse);
    });

    test('5. Reachability CUSTOMER_FIELD_CONFLICT: Amount differs while server loan status is pending', () {
      final input = ConflictClassificationInput(
        entityType: 'loan',
        entityId: 'LOAN-CUST-AMT',
        operation: 'UPDATE',
        localPayload: {'amount': 20000.0},
        serverState: {
          'id': 'LOAN-CUST-AMT',
          'amount': 15000.0,
          'status': 'pending',
        },
      );

      final result = classifier.classify(input);
      expect(result.category, equals(ConflictCategory.customerFieldConflict));
      expect(result.isRealConflict, isTrue);
      expect(result.authority, equals(ConflictAuthority.customer));
      expect(result.requiresResolutionEngine, isTrue);
    });

    test('6. Reachability CUSTOMER_FIELD_CONFLICT: TenureMonths differs while server loan status is pending', () {
      final input = ConflictClassificationInput(
        entityType: 'loan',
        entityId: 'LOAN-CUST-TENURE',
        operation: 'UPDATE',
        localPayload: {'tenureMonths': 24},
        serverState: {
          'id': 'LOAN-CUST-TENURE',
          'tenureMonths': 12,
          'status': 'pending',
        },
      );

      final result = classifier.classify(input);
      expect(result.category, equals(ConflictCategory.customerFieldConflict));
      expect(result.isRealConflict, isTrue);
    });

    test('7. Reachability CUSTOMER_FIELD_CONFLICT: Purpose differs while server loan status is pending', () {
      final input = ConflictClassificationInput(
        entityType: 'loan',
        entityId: 'LOAN-CUST-PURP',
        operation: 'UPDATE',
        localPayload: {'purpose': 'New Equipment'},
        serverState: {
          'id': 'LOAN-CUST-PURP',
          'purpose': 'Old Equipment',
          'status': 'pending',
        },
      );

      final result = classifier.classify(input);
      expect(result.category, equals(ConflictCategory.customerFieldConflict));
      expect(result.isRealConflict, isTrue);
    });

    test('8. Reachability CUSTOMER_FIELD_CONFLICT: Priority differs while server loan status is pending', () {
      final input = ConflictClassificationInput(
        entityType: 'loan',
        entityId: 'LOAN-CUST-PRIO',
        operation: 'UPDATE',
        localPayload: {'priority': 'high'},
        serverState: {
          'id': 'LOAN-CUST-PRIO',
          'priority': 'medium',
          'status': 'pending',
        },
      );

      final result = classifier.classify(input);
      expect(result.category, equals(ConflictCategory.customerFieldConflict));
      expect(result.isRealConflict, isTrue);
    });

    test('9. Reachability ADMIN_STATUS_OVERRIDE: Customer edit differs on approved server loan', () {
      final input = ConflictClassificationInput(
        entityType: 'loan',
        entityId: 'LOAN-FINAL-APP',
        operation: 'UPDATE',
        localPayload: {'amount': 25000.0},
        serverState: {
          'id': 'LOAN-FINAL-APP',
          'amount': 15000.0,
          'status': 'approved',
        },
      );

      final result = classifier.classify(input);
      expect(result.category, equals(ConflictCategory.adminStatusOverride));
      expect(result.isRealConflict, isTrue);
      expect(result.authority, equals(ConflictAuthority.admin));
      expect(result.requiresResolutionEngine, isTrue);
    });

    test('10. Reachability ADMIN_STATUS_OVERRIDE: Customer edit differs on rejected server loan', () {
      final input = ConflictClassificationInput(
        entityType: 'loan',
        entityId: 'LOAN-FINAL-REJ',
        operation: 'UPDATE',
        localPayload: {'amount': 25000.0},
        serverState: {
          'id': 'LOAN-FINAL-REJ',
          'amount': 15000.0,
          'status': 'rejected',
        },
      );

      final result = classifier.classify(input);
      expect(result.category, equals(ConflictCategory.adminStatusOverride));
      expect(result.isRealConflict, isTrue);
      expect(result.authority, equals(ConflictAuthority.admin));
    });

    test('11. Reachability SPLIT_OWNERSHIP_MERGE: Customer field edit with matching customer value and approved server status', () {
      final input = ConflictClassificationInput(
        entityType: 'loan',
        entityId: 'LOAN-SPLIT-001',
        operation: 'UPDATE',
        localPayload: {'amount': 20000.0, 'purpose': 'Expansion'},
        serverState: {
          'id': 'LOAN-SPLIT-001',
          'amount': 20000.0,
          'purpose': 'Expansion',
          'status': 'approved',
        },
      );

      final result = classifier.classify(input);
      expect(result.category, equals(ConflictCategory.splitOwnershipMerge));
      expect(result.isRealConflict, isTrue);
      expect(result.authority, equals(ConflictAuthority.split));
      expect(result.requiresResolutionEngine, isTrue);
    });

    test('12. Reachability STALE_PUSH: baseVersion < serverVersion with matching field values', () {
      final input = ConflictClassificationInput(
        entityType: 'loan',
        entityId: 'LOAN-STALE-001',
        operation: 'UPDATE',
        localPayload: {'amount': 18000.0},
        serverState: {
          'id': 'LOAN-STALE-001',
          'amount': 18000.0,
          'status': 'pending',
        },
        baseVersion: 1,
        serverVersion: 2,
      );

      final result = classifier.classify(input);
      expect(result.category, equals(ConflictCategory.stalePush));
      expect(result.isRealConflict, isTrue);
      expect(result.requiresResolutionEngine, isTrue);
    });

    test('13. Reachability INVALID_MUTATION: Customer attempting status mutation returns invalidMutation', () {
      final input = ConflictClassificationInput(
        entityType: 'loan',
        entityId: 'LOAN-ILLEGAL-STAT',
        operation: 'UPDATE',
        localPayload: {'status': 'approved'},
        userRole: 'CUSTOMER',
      );

      final result = classifier.classify(input);
      expect(result.category, equals(ConflictCategory.invalidMutation));
      expect(result.isRealConflict, isTrue);
      expect(result.authority, equals(ConflictAuthority.admin));
      expect(result.requiresResolutionEngine, isFalse);
    });

    test('14. Reachability INVALID_MUTATION: Unknown entity type or operation returns invalidMutation', () {
      final input = ConflictClassificationInput(
        entityType: 'unknown_entity',
        entityId: 'UNKNOWN-1',
        operation: 'INVALID_OP',
        localPayload: {},
      );

      final result = classifier.classify(input);
      expect(result.category, equals(ConflictCategory.invalidMutation));
      expect(result.isRealConflict, isTrue);
    });

    test('15. Reachability UPDATE_DELETE_CONFLICT: Deletion mutation on loan entity returns updateDeleteConflict', () {
      final input = ConflictClassificationInput(
        entityType: 'loan',
        entityId: 'LOAN-DEL-001',
        operation: 'DELETE',
        localPayload: {},
      );

      final result = classifier.classify(input);
      expect(result.category, equals(ConflictCategory.updateDeleteConflict));
      expect(result.isRealConflict, isTrue);
    });

    test('16. Ambiguous Edge Case: Stale baseVersion + Customer Field Collision evaluates to CUSTOMER_FIELD_CONFLICT', () {
      final input = ConflictClassificationInput(
        entityType: 'loan',
        entityId: 'LOAN-AMBIG-1',
        operation: 'UPDATE',
        localPayload: {'amount': 20000.0},
        serverState: {
          'id': 'LOAN-AMBIG-1',
          'amount': 15000.0,
          'status': 'pending',
        },
        baseVersion: 1,
        serverVersion: 3,
      );

      final result = classifier.classify(input);
      expect(result.category, equals(ConflictCategory.customerFieldConflict));
      expect(result.authority, equals(ConflictAuthority.customer));
    });

    test('17. Ambiguous Edge Case: Split Ownership with version mismatch evaluates to SPLIT_OWNERSHIP_MERGE', () {
      final input = ConflictClassificationInput(
        entityType: 'loan',
        entityId: 'LOAN-AMBIG-2',
        operation: 'UPDATE',
        localPayload: {'amount': 20000.0},
        serverState: {
          'id': 'LOAN-AMBIG-2',
          'amount': 20000.0,
          'status': 'approved',
        },
        baseVersion: 1,
        serverVersion: 3,
      );

      final result = classifier.classify(input);
      expect(result.category, equals(ConflictCategory.splitOwnershipMerge));
      expect(result.authority, equals(ConflictAuthority.split));
    });

    test('18. Classification Purity: Repeated calls with same input produce identical results without side effects', () {
      final input = ConflictClassificationInput(
        entityType: 'loan',
        entityId: 'LOAN-PURE-001',
        operation: 'UPDATE',
        localPayload: {'amount': 999.0},
        baseVersion: 1,
        serverVersion: 3,
      );

      final res1 = classifier.classify(input);
      final res2 = classifier.classify(input);

      expect(res1.category, equals(res2.category));
      expect(res1.reason, equals(res2.reason));
      expect(res1.isRealConflict, equals(res2.isRealConflict));
      expect(res1.requiresResolutionEngine, equals(res2.requiresResolutionEngine));
    });
  });
}

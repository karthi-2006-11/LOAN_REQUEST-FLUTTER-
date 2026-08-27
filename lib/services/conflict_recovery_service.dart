import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/conflict_classification_models.dart';
import '../models/conflict_resolution_models.dart';
import '../models/loan_model.dart';
import '../models/loan_priority.dart';
import '../models/loan_status.dart';
import '../models/sync_conflict_record.dart';
import '../models/sync_queue_item.dart';
import '../repositories/loan_repository.dart';
import '../repositories/sync_queue_repository.dart';
import 'conflict_classifier.dart';
import 'conflict_resolver.dart';
import 'database_service.dart';

/// Result DTO summarizing the outcome of a ConflictRecoveryService operation.
class ConflictRecoveryResult {
  final bool isRecovered;
  final String resolution; // 'CUSTOMER_WINS', 'MERGED', 'SERVER_WINS', 'DISCARDED', 'MANUAL', 'NO_ACTION'
  final String? newClientOperationId;
  final int? recommendedBaseVersion;
  final String reason;

  ConflictRecoveryResult({
    required this.isRecovered,
    required this.resolution,
    this.newClientOperationId,
    this.recommendedBaseVersion,
    required this.reason,
  });
}

/// Service managing persistent offline-first conflict recovery lifecycle in BlackVault.
class ConflictRecoveryService {
  final SyncQueueRepository _queueRepository;
  final LocalLoanRepository _loanRepository;
  final DatabaseService _databaseService;
  final ConflictClassifier _classifier;
  final ConflictResolver _resolver;

  ConflictRecoveryService({
    SyncQueueRepository? queueRepository,
    LocalLoanRepository? loanRepository,
    DatabaseService? databaseService,
    ConflictClassifier? classifier,
    ConflictResolver? resolver,
  })  : _queueRepository = queueRepository ?? LocalSyncQueueRepository(),
        _loanRepository = loanRepository ?? LocalLoanRepository(),
        _databaseService = databaseService ?? DatabaseService.instance,
        _classifier = classifier ?? ConflictClassifier(),
        _resolver = resolver ?? ConflictResolver();

  /// Atomically recovers a persistent conflict record by classifying, resolving,
  /// and applying the resolution state transitions to SQLite tables.
  Future<ConflictRecoveryResult> recoverConflict(
    SyncConflictRecord conflictRecord, {
    DatabaseExecutor? externalTxn,
  }) async {
    // Helper executing the entire recovery sequence under a single database executor/transaction context
    Future<ConflictRecoveryResult> applyRecoveryInExecutor(DatabaseExecutor executor) async {
      final txn = executor is Transaction ? executor : null;

      // 1. Idempotency Check: Skip if already resolved (resolution != null and != 'MANUAL')
      if (conflictRecord.resolution != null && conflictRecord.resolution != 'MANUAL') {
        return ConflictRecoveryResult(
          isRecovered: false,
          resolution: conflictRecord.resolution!,
          reason: 'Conflict record has already been resolved (${conflictRecord.resolution})',
        );
      }

      // 2. Fetch original queue item using the active transaction executor
      final item = await _queueRepository.getByClientOperationId(conflictRecord.clientOperationId, txn: executor);
      if (item == null) {
        return ConflictRecoveryResult(
          isRecovered: false,
          resolution: 'MANUAL',
          reason: 'Original sync_queue item not found for operation ${conflictRecord.clientOperationId}',
        );
      }

      // Terminal State Idempotency Check
      if (item.status == 'RESOLVED_CONFLICT' || item.status == 'REJECTED') {
        return ConflictRecoveryResult(
          isRecovered: false,
          resolution: conflictRecord.resolution ?? 'RESOLVED',
          reason: 'sync_queue item is already in terminal state (${item.status})',
        );
      }

      // 3. Classify & Resolve Conflict (Pure Decision Steps)
      final classificationInput = ConflictClassificationInput(
        entityType: conflictRecord.entityType,
        entityId: conflictRecord.entityId,
        operation: item.operation,
        localPayload: item.payload,
        serverState: conflictRecord.serverValue,
        baseVersion: item.baseVersion,
        serverVersion: conflictRecord.serverVersion,
        userRole: 'CUSTOMER',
      );

      final classificationResult = _classifier.classify(classificationInput);

      final resolutionInput = ConflictResolutionInput(
        category: classificationResult.category,
        entityType: conflictRecord.entityType,
        entityId: conflictRecord.entityId,
        operation: item.operation,
        localPayload: item.payload,
        serverState: conflictRecord.serverValue,
        baseVersion: item.baseVersion,
        serverVersion: conflictRecord.serverVersion,
        userRole: 'CUSTOMER',
        retryCount: item.retryCount,
      );

      final resolutionResult = _resolver.resolve(resolutionInput);

      // 4. Apply State Transitions
      switch (resolutionResult.resolution) {
        case ResolutionOutcome.noAction:
          return ConflictRecoveryResult(
            isRecovered: false,
            resolution: 'NO_ACTION',
            reason: resolutionResult.reason,
          );

        case ResolutionOutcome.customerWins:
          final newClientOpId = SyncQueueItem.generateClientOperationId();
          final targetBaseVersion = resolutionResult.recommendedBaseVersion ?? conflictRecord.serverVersion;

          // Mark old queue item terminal/resolved
          await _queueRepository.updateStatus(
            item.id,
            'RESOLVED_CONFLICT',
            error: 'Resolved: Customer Wins',
            txn: txn,
          );

          // Update sync_conflicts record
          final updatedConflict = SyncConflictRecord(
            id: conflictRecord.id,
            clientOperationId: conflictRecord.clientOperationId,
            entityType: conflictRecord.entityType,
            entityId: conflictRecord.entityId,
            conflictType: conflictRecord.conflictType,
            localValue: conflictRecord.localValue,
            serverValue: conflictRecord.serverValue,
            serverVersion: conflictRecord.serverVersion,
            createdAt: conflictRecord.createdAt,
            resolvedAt: DateTime.now(),
            resolution: 'CUSTOMER_WINS',
          );
          await _queueRepository.saveConflictRecord(updatedConflict, txn: executor);

          // Insert new SyncQueueItem with NEW clientOperationId and fresh retryCount (0)
          final newItem = SyncQueueItem(
            id: 'QUEUE-${DateTime.now().microsecondsSinceEpoch}',
            entityType: conflictRecord.entityType,
            entityId: conflictRecord.entityId,
            operation: item.operation,
            payload: resolutionResult.resolvedPayload!,
            clientOperationId: newClientOpId,
            createdAt: DateTime.now(),
            retryCount: 0,
            status: 'PENDING_SYNC',
            baseVersion: targetBaseVersion,
          );
          await _queueRepository.enqueue(newItem, txn: txn);

          // Apply local loan update if entity is loan
          if (conflictRecord.entityType == 'loan') {
            await _applyLoanUpdate(conflictRecord.entityId, resolutionResult.resolvedPayload!, executor);
          }

          return ConflictRecoveryResult(
            isRecovered: true,
            resolution: 'CUSTOMER_WINS',
            newClientOperationId: newClientOpId,
            recommendedBaseVersion: targetBaseVersion,
            reason: resolutionResult.reason,
          );

        case ResolutionOutcome.fieldMerge:
          final newClientOpId = SyncQueueItem.generateClientOperationId();
          final targetBaseVersion = resolutionResult.recommendedBaseVersion ?? conflictRecord.serverVersion;

          // Mark old queue item terminal/resolved
          await _queueRepository.updateStatus(
            item.id,
            'RESOLVED_CONFLICT',
            error: 'Resolved: Field Merge',
            txn: txn,
          );

          // Update sync_conflicts record
          final updatedConflict = SyncConflictRecord(
            id: conflictRecord.id,
            clientOperationId: conflictRecord.clientOperationId,
            entityType: conflictRecord.entityType,
            entityId: conflictRecord.entityId,
            conflictType: conflictRecord.conflictType,
            localValue: conflictRecord.localValue,
            serverValue: conflictRecord.serverValue,
            serverVersion: conflictRecord.serverVersion,
            createdAt: conflictRecord.createdAt,
            resolvedAt: DateTime.now(),
            resolution: 'MERGED',
          );
          await _queueRepository.saveConflictRecord(updatedConflict, txn: executor);

          // Insert new SyncQueueItem with NEW clientOperationId
          if (resolutionResult.requiresRequeue) {
            final newItem = SyncQueueItem(
              id: 'QUEUE-${DateTime.now().microsecondsSinceEpoch}',
              entityType: conflictRecord.entityType,
              entityId: conflictRecord.entityId,
              operation: item.operation,
              payload: resolutionResult.resolvedPayload!,
              clientOperationId: newClientOpId,
              createdAt: DateTime.now(),
              retryCount: 0,
              status: 'PENDING_SYNC',
              baseVersion: targetBaseVersion,
            );
            await _queueRepository.enqueue(newItem, txn: txn);
          }

          // Apply local loan update with merged payload
          if (conflictRecord.entityType == 'loan') {
            await _applyLoanUpdate(conflictRecord.entityId, resolutionResult.resolvedPayload!, executor);
          }

          return ConflictRecoveryResult(
            isRecovered: true,
            resolution: 'MERGED',
            newClientOperationId: resolutionResult.requiresRequeue ? newClientOpId : null,
            recommendedBaseVersion: targetBaseVersion,
            reason: resolutionResult.reason,
          );

        case ResolutionOutcome.serverWins:
          // Mark old queue item terminal/rejected
          await _queueRepository.updateStatus(
            item.id,
            'REJECTED',
            error: 'Discarded: Server Wins',
            txn: txn,
          );

          // Update sync_conflicts record
          final updatedConflict = SyncConflictRecord(
            id: conflictRecord.id,
            clientOperationId: conflictRecord.clientOperationId,
            entityType: conflictRecord.entityType,
            entityId: conflictRecord.entityId,
            conflictType: conflictRecord.conflictType,
            localValue: conflictRecord.localValue,
            serverValue: conflictRecord.serverValue,
            serverVersion: conflictRecord.serverVersion,
            createdAt: conflictRecord.createdAt,
            resolvedAt: DateTime.now(),
            resolution: 'SERVER_WINS',
          );
          await _queueRepository.saveConflictRecord(updatedConflict, txn: executor);

          // Apply authoritative server state locally
          if (conflictRecord.entityType == 'loan') {
            final serverPayload = resolutionResult.resolvedPayload ?? conflictRecord.serverValue;
            await _applyLoanUpdate(conflictRecord.entityId, serverPayload, executor);
          }

          return ConflictRecoveryResult(
            isRecovered: true,
            resolution: 'SERVER_WINS',
            reason: resolutionResult.reason,
          );

        case ResolutionOutcome.rejected:
          // Mark old queue item terminal/rejected
          await _queueRepository.updateStatus(
            item.id,
            'REJECTED',
            error: 'Rejected: Invalid Mutation',
            txn: txn,
          );

          // Update sync_conflicts record
          final updatedConflict = SyncConflictRecord(
            id: conflictRecord.id,
            clientOperationId: conflictRecord.clientOperationId,
            entityType: conflictRecord.entityType,
            entityId: conflictRecord.entityId,
            conflictType: conflictRecord.conflictType,
            localValue: conflictRecord.localValue,
            serverValue: conflictRecord.serverValue,
            serverVersion: conflictRecord.serverVersion,
            createdAt: conflictRecord.createdAt,
            resolvedAt: DateTime.now(),
            resolution: 'DISCARDED',
          );
          await _queueRepository.saveConflictRecord(updatedConflict, txn: executor);

          return ConflictRecoveryResult(
            isRecovered: false,
            resolution: 'DISCARDED',
            reason: resolutionResult.reason,
          );

        case ResolutionOutcome.unresolved:
          // Mark old queue item status CONFLICT requiring manual review
          await _queueRepository.updateStatus(
            item.id,
            'CONFLICT',
            error: resolutionResult.reason,
            txn: txn,
          );

          // Update sync_conflicts record
          final updatedConflict = SyncConflictRecord(
            id: conflictRecord.id,
            clientOperationId: conflictRecord.clientOperationId,
            entityType: conflictRecord.entityType,
            entityId: conflictRecord.entityId,
            conflictType: conflictRecord.conflictType,
            localValue: conflictRecord.localValue,
            serverValue: conflictRecord.serverValue,
            serverVersion: conflictRecord.serverVersion,
            createdAt: conflictRecord.createdAt,
            resolvedAt: DateTime.now(),
            resolution: 'MANUAL',
          );
          await _queueRepository.saveConflictRecord(updatedConflict, txn: executor);

          return ConflictRecoveryResult(
            isRecovered: false,
            resolution: 'MANUAL',
            reason: resolutionResult.reason,
          );
      }
    }

    // 5. Execute atomically inside a single SQLite transaction
    if (externalTxn != null) {
      return await applyRecoveryInExecutor(externalTxn);
    } else {
      final db = await _databaseService.database;
      return await db.transaction((txn) async {
        return await applyRecoveryInExecutor(txn);
      });
    }
  }

  /// Helper to apply updated entity values to the local loans table.
  /// Uses server application mechanics without creating new sync queue mutations.
  Future<void> _applyLoanUpdate(
    String entityId,
    Map<String, dynamic> payload,
    DatabaseExecutor executor,
  ) async {
    final statusStr = payload['status'] as String? ?? 'pending';
    final priorityStr = payload['priority'] as String? ?? 'medium';

    final loan = LoanModel(
      id: entityId,
      userId: payload['userId'] as String? ?? '',
      userName: payload['userName'] as String? ?? 'User',
      amount: (payload['amount'] as num?)?.toDouble() ?? 0.0,
      tenureMonths: (payload['tenureMonths'] as int?) ?? 12,
      purpose: payload['purpose'] as String? ?? '',
      priority: LoanPriority.values.firstWhere(
        (p) => p.name == priorityStr,
        orElse: () => LoanPriority.medium,
      ),
      status: LoanStatus.values.firstWhere(
        (s) => s.name == statusStr,
        orElse: () => LoanStatus.pending,
      ),
      createdAt: payload['createdAt'] != null
          ? DateTime.parse(payload['createdAt'] as String)
          : DateTime.now(),
    );

    final txn = executor is Transaction ? executor : null;
    await _loanRepository.applyServerLoan(loan, 'UPDATE', txn: txn);
  }
}

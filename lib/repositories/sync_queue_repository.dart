import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/sync_conflict_record.dart';
import '../models/sync_queue_item.dart';
import '../services/database_service.dart';

abstract class SyncQueueRepository {
  Future<SyncQueueItem> enqueue(SyncQueueItem item, {Transaction? txn});
  Future<List<SyncQueueItem>> getPendingItems({int limit = 50});
  Future<SyncQueueItem?> getByClientOperationId(String clientOperationId);
  Future<bool> updateStatus(String id, String status, {String? error, Transaction? txn});
  Future<bool> incrementRetry(String id, {String? error, Transaction? txn});
  Future<bool> deleteQueueItem(String id, {Transaction? txn});
  Future<int> getLastAppliedServerVersion();
  Future<void> updateLastAppliedServerVersion(int version, {DatabaseExecutor? txn});
  Future<bool> hasPendingLocalMutation(String entityType, String entityId, {DatabaseExecutor? txn});
  Future<void> saveConflictRecord(SyncConflictRecord conflict, {DatabaseExecutor? txn});
  Future<SyncConflictRecord?> getConflictRecordByClientOperationId(String clientOperationId);
}

class LocalSyncQueueRepository implements SyncQueueRepository {
  final DatabaseService _databaseService;

  LocalSyncQueueRepository({DatabaseService? databaseService})
      : _databaseService = databaseService ?? DatabaseService.instance;

  @override
  Future<SyncQueueItem> enqueue(SyncQueueItem item, {Transaction? txn}) async {
    final executor = txn ?? await _databaseService.database;
    await executor.insert(
      'sync_queue',
      item.toSqlMap(),
      conflictAlgorithm: ConflictAlgorithm.fail,
    );
    return item;
  }

  @override
  Future<List<SyncQueueItem>> getPendingItems({int limit = 50}) async {
    final db = await _databaseService.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'sync_queue',
      where: "status IN ('PENDING_SYNC', 'SYNC_FAILED')",
      orderBy: 'createdAt ASC',
      limit: limit,
    );
    return maps.map((map) => SyncQueueItem.fromSqlMap(map)).toList();
  }

  @override
  Future<SyncQueueItem?> getByClientOperationId(String clientOperationId) async {
    final db = await _databaseService.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'sync_queue',
      where: 'clientOperationId = ?',
      whereArgs: [clientOperationId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return SyncQueueItem.fromSqlMap(maps.first);
  }

  @override
  Future<bool> updateStatus(String id, String status, {String? error, Transaction? txn}) async {
    final executor = txn ?? await _databaseService.database;
    final count = await executor.update(
      'sync_queue',
      {
        'status': status,
        'error': error,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    return count > 0;
  }

  @override
  Future<bool> incrementRetry(String id, {String? error, Transaction? txn}) async {
    final executor = txn ?? await _databaseService.database;
    final maps = await executor.query(
      'sync_queue',
      columns: ['retryCount'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return false;
    final currentRetry = (maps.first['retryCount'] as int?) ?? 0;

    final count = await executor.update(
      'sync_queue',
      {
        'retryCount': currentRetry + 1,
        'lastAttemptAt': DateTime.now().toIso8601String(),
        'status': 'SYNC_FAILED',
        'error': error,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    return count > 0;
  }

  @override
  Future<bool> deleteQueueItem(String id, {Transaction? txn}) async {
    final executor = txn ?? await _databaseService.database;
    final count = await executor.delete(
      'sync_queue',
      where: 'id = ?',
      whereArgs: [id],
    );
    return count > 0;
  }

  @override
  Future<int> getLastAppliedServerVersion() async {
    final db = await _databaseService.database;
    final maps = await db.query(
      'sync_metadata',
      where: "key = 'lastAppliedServerVersion'",
      limit: 1,
    );
    if (maps.isEmpty) return 0;
    return int.tryParse(maps.first['value'] as String) ?? 0;
  }

  @override
  Future<void> updateLastAppliedServerVersion(int version, {DatabaseExecutor? txn}) async {
    final executor = txn ?? await _databaseService.database;
    await executor.insert(
      'sync_metadata',
      {
        'key': 'lastAppliedServerVersion',
        'value': version.toString(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<bool> hasPendingLocalMutation(String entityType, String entityId, {DatabaseExecutor? txn}) async {
    final executor = txn ?? await _databaseService.database;
    final maps = await executor.query(
      'sync_queue',
      where: "entityType = ? AND entityId = ? AND status IN ('PENDING_SYNC', 'SYNCING')",
      whereArgs: [entityType, entityId],
      limit: 1,
    );
    return maps.isNotEmpty;
  }

  @override
  Future<void> saveConflictRecord(SyncConflictRecord conflict, {DatabaseExecutor? txn}) async {
    final executor = txn ?? await _databaseService.database;
    await executor.insert(
      'sync_conflicts',
      conflict.toSqlMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<SyncConflictRecord?> getConflictRecordByClientOperationId(String clientOperationId) async {
    final db = await _databaseService.database;
    final maps = await db.query(
      'sync_conflicts',
      where: 'clientOperationId = ?',
      whereArgs: [clientOperationId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return SyncConflictRecord.fromSqlMap(maps.first);
  }
}

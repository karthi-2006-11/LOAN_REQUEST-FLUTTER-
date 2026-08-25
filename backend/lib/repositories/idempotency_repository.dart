import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../database/backend_database.dart';
import '../models/idempotency_record.dart';

class IdempotencyRepository {
  final BackendDatabase database;

  IdempotencyRepository({required this.database});

  Future<IdempotencyRecord?> findByClientOperationId(String clientOperationId) async {
    final db = await database.db;
    final maps = await db.query(
      'idempotency_records',
      where: 'clientOperationId = ?',
      whereArgs: [clientOperationId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return IdempotencyRecord.fromSqlMap(maps.first);
  }

  Future<void> saveRecord(IdempotencyRecord record, {Transaction? txn}) async {
    final db = txn ?? await database.db;
    await db.insert(
      'idempotency_records',
      record.toSqlMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }
}

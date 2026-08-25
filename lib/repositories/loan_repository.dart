import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/loan_model.dart';
import '../models/loan_priority.dart';
import '../models/loan_status.dart';
import '../models/sync_queue_item.dart';
import '../services/database_service.dart';

/// Abstract interface for Loan Repository operations.
abstract class LoanRepository {
  Future<List<LoanModel>> getAllLoans();
  Future<List<LoanModel>> getUserLoans(String userId);
  Future<LoanModel?> getLoanById(String id);
  Future<LoanModel> createLoan(LoanModel loan);
  Future<LoanModel> updateLoanStatus(String id, LoanStatus newStatus);
  Future<bool> deleteLoan(String id);
}

/// SQLite implementation of LoanRepository using DatabaseService persistence
/// and atomic sync_queue mutation tracking.
class LocalLoanRepository implements LoanRepository {
  final DatabaseService _databaseService;

  LocalLoanRepository({DatabaseService? databaseService})
      : _databaseService = databaseService ?? DatabaseService.instance;

  // Seed data for the default user account (`USR-DEMO-101`)
  static final List<LoanModel> _seedLoans = [
    LoanModel(
      id: 'LOAN-1001',
      userId: 'USR-DEMO-101',
      userName: 'Alex Morgan',
      amount: 5000.00,
      tenureMonths: 12,
      purpose: 'Personal',
      priority: LoanPriority.medium,
      status: LoanStatus.approved,
      createdAt: DateTime.now().subtract(const Duration(days: 14)),
    ),
    LoanModel(
      id: 'LOAN-1002',
      userId: 'USR-DEMO-101',
      userName: 'Alex Morgan',
      amount: 15000.00,
      tenureMonths: 24,
      purpose: 'Business Expansion',
      priority: LoanPriority.high,
      status: LoanStatus.pending,
      createdAt: DateTime.now().subtract(const Duration(days: 2)),
    ),
  ];

  Future<Database> _getDb() async {
    final db = await _databaseService.database;
    await _ensureSeedData(db);
    return db;
  }

  Future<void> _ensureSeedData(Database db) async {
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM loans');
    final count = result.first['count'] as int?;
    if (count == 0 || count == null) {
      final batch = db.batch();
      for (final seed in _seedLoans) {
        batch.insert(
          'loans',
          seed.toJson(),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      await batch.commit(noResult: true);
    }
  }

  @override
  Future<List<LoanModel>> getAllLoans() async {
    final db = await _getDb();
    final List<Map<String, dynamic>> maps = await db.query(
      'loans',
      orderBy: 'createdAt DESC',
    );
    return maps.map((map) => LoanModel.fromJson(map)).toList();
  }

  @override
  Future<List<LoanModel>> getUserLoans(String userId) async {
    final db = await _getDb();
    final List<Map<String, dynamic>> maps = await db.query(
      'loans',
      where: 'userId = ?',
      whereArgs: [userId],
      orderBy: 'createdAt DESC',
    );
    return maps.map((map) => LoanModel.fromJson(map)).toList();
  }

  @override
  Future<LoanModel?> getLoanById(String id) async {
    final db = await _getDb();
    final List<Map<String, dynamic>> maps = await db.query(
      'loans',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) {
      return null;
    }
    return LoanModel.fromJson(maps.first);
  }

  @override
  Future<LoanModel> createLoan(LoanModel loan) async {
    final db = await _getDb();
    final clientOpId = SyncQueueItem.generateClientOperationId('createLoan-${loan.id}');
    final now = DateTime.now();

    await db.transaction((txn) async {
      await txn.insert(
        'loans',
        loan.toJson(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      await txn.insert(
        'sync_queue',
        SyncQueueItem(
          id: 'SQ-${now.microsecondsSinceEpoch}',
          entityType: 'loan',
          entityId: loan.id,
          operation: 'CREATE',
          payload: loan.toJson(),
          clientOperationId: clientOpId,
          createdAt: now,
        ).toSqlMap(),
        conflictAlgorithm: ConflictAlgorithm.fail,
      );
    });

    return loan;
  }

  @override
  Future<LoanModel> updateLoanStatus(String id, LoanStatus newStatus) async {
    final db = await _getDb();
    final existing = await getLoanById(id);
    if (existing == null) {
      throw Exception('Loan request not found');
    }
    final updated = existing.copyWith(status: newStatus);
    final clientOpId = SyncQueueItem.generateClientOperationId('updateStatus-$id');
    final now = DateTime.now();

    await db.transaction((txn) async {
      await txn.update(
        'loans',
        {'status': newStatus.toJson()},
        where: 'id = ?',
        whereArgs: [id],
      );

      await txn.insert(
        'sync_queue',
        SyncQueueItem(
          id: 'SQ-${now.microsecondsSinceEpoch}',
          entityType: 'loan',
          entityId: id,
          operation: 'UPDATE',
          payload: {'status': newStatus.toJson()},
          clientOperationId: clientOpId,
          createdAt: now,
        ).toSqlMap(),
        conflictAlgorithm: ConflictAlgorithm.fail,
      );
    });

    return updated;
  }

  @override
  Future<bool> deleteLoan(String id) async {
    final db = await _getDb();
    final clientOpId = SyncQueueItem.generateClientOperationId('deleteLoan-$id');
    final now = DateTime.now();
    int count = 0;

    await db.transaction((txn) async {
      count = await txn.delete(
        'loans',
        where: 'id = ?',
        whereArgs: [id],
      );

      if (count > 0) {
        await txn.insert(
          'sync_queue',
          SyncQueueItem(
            id: 'SQ-${now.microsecondsSinceEpoch}',
            entityType: 'loan',
            entityId: id,
            operation: 'DELETE',
            payload: {'id': id},
            clientOperationId: clientOpId,
            createdAt: now,
          ).toSqlMap(),
          conflictAlgorithm: ConflictAlgorithm.fail,
        );
      }
    });

    return count > 0;
  }

  /// Apply a pulled server-originated loan change directly to local SQLite without enqueueing sync_queue items.
  Future<void> applyServerLoan(LoanModel loan, String operation, {DatabaseExecutor? txn}) async {
    final executor = txn ?? await _getDb();
    if (operation == 'CREATE' || operation == 'UPDATE') {
      final existing = await executor.query('loans', where: 'id = ?', whereArgs: [loan.id], limit: 1);
      if (existing.isEmpty) {
        await executor.insert('loans', loan.toJson(), conflictAlgorithm: ConflictAlgorithm.replace);
      } else {
        await executor.update('loans', loan.toJson(), where: 'id = ?', whereArgs: [loan.id]);
      }
    } else if (operation == 'DELETE') {
      await executor.delete('loans', where: 'id = ?', whereArgs: [loan.id]);
    }
  }
}

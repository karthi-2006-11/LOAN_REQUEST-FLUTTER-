import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../database/backend_database.dart';
import '../models/loan_server_model.dart';

class LoanBackendRepository {
  final BackendDatabase database;

  LoanBackendRepository({required this.database});

  Future<List<LoanServerModel>> getAllLoans() async {
    final db = await database.db;
    final maps = await db.query(
      'loans',
      orderBy: 'createdAt DESC',
    );
    return maps.map((m) => LoanServerModel.fromSqlMap(m)).toList();
  }

  Future<List<LoanServerModel>> getCustomerLoans(String userId) async {
    final db = await database.db;
    final maps = await db.query(
      'loans',
      where: 'userId = ?',
      whereArgs: [userId],
      orderBy: 'createdAt DESC',
    );
    return maps.map((m) => LoanServerModel.fromSqlMap(m)).toList();
  }

  Future<LoanServerModel?> getLoanById(String id) async {
    final db = await database.db;
    final maps = await db.query(
      'loans',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return LoanServerModel.fromSqlMap(maps.first);
  }

  Future<LoanServerModel> createLoan(LoanServerModel loan) async {
    final db = await database.db;
    await db.insert(
      'loans',
      loan.toSqlMap(),
      conflictAlgorithm: ConflictAlgorithm.fail,
    );
    return loan;
  }

  Future<LoanServerModel> updateLoan(LoanServerModel loan) async {
    final db = await database.db;
    await db.update(
      'loans',
      loan.toSqlMap(),
      where: 'id = ?',
      whereArgs: [loan.id],
    );
    return loan;
  }
}

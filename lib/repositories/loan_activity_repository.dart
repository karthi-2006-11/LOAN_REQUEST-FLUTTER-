import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/loan_activity_model.dart';
import '../services/database_service.dart';

abstract class LoanActivityRepository {
  Future<LoanActivityModel> addActivity(LoanActivityModel activity);
  Future<List<LoanActivityModel>> getLoanActivities(String loanId);
  Future<List<LoanActivityModel>> getUserActivities(String userId);
  Future<List<LoanActivityModel>> getAllActivities();
}

class LocalLoanActivityRepository implements LoanActivityRepository {
  final DatabaseService _databaseService;

  LocalLoanActivityRepository({DatabaseService? databaseService})
      : _databaseService = databaseService ?? DatabaseService.instance;

  @override
  Future<LoanActivityModel> addActivity(LoanActivityModel activity) async {
    final db = await _databaseService.database;
    await db.insert(
      'loan_activities',
      activity.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return activity;
  }

  @override
  Future<List<LoanActivityModel>> getLoanActivities(String loanId) async {
    final db = await _databaseService.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'loan_activities',
      where: 'loanId = ?',
      whereArgs: [loanId],
      orderBy: 'createdAt ASC', // Chronological order
    );
    return maps.map((map) => LoanActivityModel.fromJson(map)).toList();
  }

  @override
  Future<List<LoanActivityModel>> getUserActivities(String userId) async {
    final db = await _databaseService.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'loan_activities',
      where: 'userId = ?',
      whereArgs: [userId],
      orderBy: 'createdAt DESC',
    );
    return maps.map((map) => LoanActivityModel.fromJson(map)).toList();
  }

  @override
  Future<List<LoanActivityModel>> getAllActivities() async {
    final db = await _databaseService.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'loan_activities',
      orderBy: 'createdAt DESC',
    );
    return maps.map((map) => LoanActivityModel.fromJson(map)).toList();
  }
}

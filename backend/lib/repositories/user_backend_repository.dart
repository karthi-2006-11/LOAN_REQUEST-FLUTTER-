import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../database/backend_database.dart';
import '../models/user_server_model.dart';

class UserBackendRepository {
  final BackendDatabase database;

  UserBackendRepository({required this.database});

  Future<UserServerModel?> findByEmail(String email) async {
    final db = await database.db;
    final maps = await db.query(
      'users',
      where: 'email = ?',
      whereArgs: [email.toLowerCase().trim()],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return UserServerModel.fromSqlMap(maps.first);
  }

  Future<UserServerModel?> findById(String id) async {
    final db = await database.db;
    final maps = await db.query(
      'users',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return UserServerModel.fromSqlMap(maps.first);
  }

  Future<UserServerModel> createUser(UserServerModel user) async {
    final db = await database.db;
    await db.insert(
      'users',
      user.toSqlMap(),
      conflictAlgorithm: ConflictAlgorithm.fail,
    );
    return user;
  }
}

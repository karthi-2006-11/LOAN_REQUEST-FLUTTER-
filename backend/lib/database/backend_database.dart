import 'dart:io';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../config/env_config.dart';

/// Central server database initialization and management service.
class BackendDatabase {
  final EnvConfig config;
  Database? _db;

  BackendDatabase({required this.config});

  Future<Database> get db async {
    if (_db != null && _db!.isOpen) {
      return _db!;
    }
    _db = await _initDatabase();
    return _db!;
  }

  Future<Database> _initDatabase() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final dbPath = config.dbPath.startsWith('/') || config.dbPath.contains(':')
        ? config.dbPath
        : join(Directory.current.path, config.dbPath);

    return await openDatabase(
      dbPath,
      version: 1,
      onConfigure: (database) async {
        await database.execute('PRAGMA foreign_keys = ON;');
      },
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database database, int version) async {
    // 1. users table
    await database.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY,
        email TEXT NOT NULL UNIQUE,
        fullName TEXT NOT NULL,
        phone TEXT NOT NULL,
        role TEXT NOT NULL,
        passwordHash TEXT NOT NULL,
        salt TEXT,
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL
      )
    ''');

    // 2. loans table
    await database.execute('''
      CREATE TABLE IF NOT EXISTS loans (
        id TEXT PRIMARY KEY,
        userId TEXT NOT NULL,
        userName TEXT NOT NULL,
        amount REAL NOT NULL,
        tenureMonths INTEGER NOT NULL,
        purpose TEXT NOT NULL,
        priority TEXT NOT NULL,
        status TEXT NOT NULL,
        deviceId TEXT,
        version INTEGER NOT NULL DEFAULT 1,
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL,
        FOREIGN KEY (userId) REFERENCES users(id) ON DELETE CASCADE
      )
    ''');

    // 3. loan_activities table
    await database.execute('''
      CREATE TABLE IF NOT EXISTS loan_activities (
        id TEXT PRIMARY KEY,
        loanId TEXT NOT NULL,
        userId TEXT NOT NULL,
        userName TEXT NOT NULL,
        type TEXT NOT NULL,
        message TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        FOREIGN KEY (loanId) REFERENCES loans(id) ON DELETE CASCADE
      )
    ''');

    // 4. notifications table
    await database.execute('''
      CREATE TABLE IF NOT EXISTS notifications (
        id TEXT PRIMARY KEY,
        userId TEXT NOT NULL,
        title TEXT NOT NULL,
        message TEXT NOT NULL,
        type TEXT NOT NULL,
        loanId TEXT,
        createdAt TEXT NOT NULL,
        isRead INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // 5. idempotency_records table
    await database.execute('''
      CREATE TABLE IF NOT EXISTS idempotency_records (
        clientOperationId TEXT PRIMARY KEY,
        entityId TEXT NOT NULL,
        operationType TEXT NOT NULL,
        responseCode INTEGER NOT NULL,
        responsePayload TEXT NOT NULL,
        createdAt TEXT NOT NULL
      )
    ''');

    // 6. sync_changes table (Monotonically increasing serverVersion log)
    await database.execute('''
      CREATE TABLE IF NOT EXISTS sync_changes (
        serverVersion INTEGER PRIMARY KEY AUTOINCREMENT,
        entityType TEXT NOT NULL,
        entityId TEXT NOT NULL,
        operation TEXT NOT NULL,
        payload TEXT NOT NULL,
        userId TEXT NOT NULL,
        originDeviceId TEXT,
        createdAt TEXT NOT NULL
      )
    ''');

    // Indexes
    await database.execute('CREATE INDEX IF NOT EXISTS idx_backend_users_email ON users(email);');
    await database.execute('CREATE INDEX IF NOT EXISTS idx_backend_loans_userId ON loans(userId);');
    await database.execute('CREATE INDEX IF NOT EXISTS idx_backend_loans_status ON loans(status);');
    await database.execute('CREATE INDEX IF NOT EXISTS idx_backend_idempotency_createdAt ON idempotency_records(createdAt);');
    await database.execute('CREATE INDEX IF NOT EXISTS idx_sync_changes_version ON sync_changes(serverVersion);');
    await database.execute('CREATE INDEX IF NOT EXISTS idx_sync_changes_user ON sync_changes(userId);');
  }

  Future<void> close() async {
    if (_db != null && _db!.isOpen) {
      await _db!.close();
      _db = null;
    }
  }
}

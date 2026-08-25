import 'dart:io';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Singleton service managing SQLite database initialization, schemas, and lifecycle.
class DatabaseService {
  static final DatabaseService instance = DatabaseService._internal();
  factory DatabaseService() => instance;
  DatabaseService._internal();

  static const String _dbName = 'blackvault.db';
  static const int _dbVersion = 1;

  Database? _database;

  /// Expose database instance, initializing if not already open
  Future<Database> get database async {
    if (_database != null && _database!.isOpen) {
      return _database!;
    }
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    // Cross-platform support: initialize FFI factory on Desktop platforms
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);

    return await openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onConfigure: _onConfigure,
    );
  }

  Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON;');
  }

  Future<void> _onCreate(Database db, int version) async {
    // 1. users table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY,
        fullName TEXT NOT NULL,
        email TEXT NOT NULL UNIQUE,
        phone TEXT NOT NULL,
        role TEXT NOT NULL,
        passwordHash TEXT,
        createdAt TEXT NOT NULL
      )
    ''');

    // 2. loans table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS loans (
        id TEXT PRIMARY KEY,
        userId TEXT NOT NULL,
        userName TEXT NOT NULL,
        amount REAL NOT NULL,
        tenureMonths INTEGER NOT NULL,
        purpose TEXT NOT NULL,
        priority TEXT NOT NULL,
        status TEXT NOT NULL,
        createdAt TEXT NOT NULL
      )
    ''');

    // 3. loan_activities table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS loan_activities (
        id TEXT PRIMARY KEY,
        loanId TEXT NOT NULL,
        userId TEXT NOT NULL,
        userName TEXT NOT NULL,
        type TEXT NOT NULL,
        message TEXT NOT NULL,
        createdAt TEXT NOT NULL
      )
    ''');

    // 4. notifications table
    await db.execute('''
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

    // 5. Indexes for query optimization
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_loans_userId ON loans(userId);');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_loans_status ON loans(status);');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_loan_activities_loanId ON loan_activities(loanId);');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_loan_activities_userId ON loan_activities(userId);');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_notifications_userId ON notifications(userId);');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_notifications_loanId ON notifications(loanId);');
  }

  /// Close database connection
  Future<void> close() async {
    if (_database != null && _database!.isOpen) {
      await _database!.close();
      _database = null;
    }
  }
}

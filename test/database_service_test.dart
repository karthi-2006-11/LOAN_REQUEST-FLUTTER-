import 'package:flutter_test/flutter_test.dart';
import 'package:loan_request_app/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    await DatabaseService.instance.close();
  });

  test('DatabaseService initializes tables and indexes correctly', () async {
    final db = await DatabaseService.instance.database;
    expect(db.isOpen, isTrue);

    // Verify all 4 tables exist
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('users', 'loans', 'loan_activities', 'notifications')",
    );
    final tableNames = tables.map((t) => t['name'] as String).toSet();
    expect(tableNames, containsAll({'users', 'loans', 'loan_activities', 'notifications'}));

    // Verify indexes exist
    final indexes = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'",
    );
    final indexNames = indexes.map((i) => i['name'] as String).toSet();
    expect(
      indexNames,
      containsAll({
        'idx_loans_userId',
        'idx_loans_status',
        'idx_loan_activities_loanId',
        'idx_loan_activities_userId',
        'idx_notifications_userId',
        'idx_notifications_loanId',
      }),
    );
  });
}

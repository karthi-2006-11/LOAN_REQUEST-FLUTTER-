import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loan_request_app/models/loan_model.dart';
import 'package:loan_request_app/models/loan_priority.dart';
import 'package:loan_request_app/models/loan_status.dart';
import 'package:loan_request_app/models/loan_sync_status.dart';
import 'package:loan_request_app/models/sync_queue_item.dart';
import 'package:loan_request_app/providers/loan_provider.dart';
import 'package:loan_request_app/repositories/loan_repository.dart';
import 'package:loan_request_app/repositories/sync_queue_repository.dart';
import 'package:loan_request_app/services/database_service.dart';
import 'package:loan_request_app/widgets/loan_card.dart';
import 'package:loan_request_app/widgets/sync_status_badge.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDir;
  late int testIndex;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    testIndex = 0;
  });

  late DatabaseService dbService;
  late SyncQueueRepository queueRepo;
  late LocalLoanRepository loanRepo;
  late LoanProvider loanProvider;

  setUp(() async {
    testIndex++;
    tempDir = await Directory.systemTemp.createTemp('blackvault_p91_${testIndex}_');

    dbService = DatabaseService.instance;
    await dbService.close();

    final systemDbPath = await getDatabasesPath();
    final defaultPath = p.join(systemDbPath, 'blackvault.db');
    await databaseFactory.deleteDatabase(defaultPath);

    await dbService.database;

    queueRepo = LocalSyncQueueRepository(databaseService: dbService);
    loanRepo = LocalLoanRepository(databaseService: dbService);

    loanProvider = LoanProvider(
      loanRepository: loanRepo,
      queueRepository: queueRepo,
    );
  });

  tearDown(() async {
    await dbService.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Phase 9.1 — Loan Sync State Model & UI Status Badges', () {
    test('1. Offline-created loan displays PENDING_SYNC status', () async {
      final loan = LoanModel(
        id: 'LOAN-P91-001',
        userId: 'USR-CUST-91',
        userName: 'Customer P91',
        amount: 25000.0,
        tenureMonths: 12,
        purpose: 'Equipment Purchase',
        priority: LoanPriority.high,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);
      await loanProvider.fetchUserLoans('USR-CUST-91');

      final syncStatus = loanProvider.getSyncStatus('LOAN-P91-001');
      expect(syncStatus, equals(LoanSyncStatus.pendingSync));
      expect(syncStatus.label, equals('Saved Offline'));
    });

    test('2. Backend-accepted loan displays SYNCED status', () async {
      final loan = LoanModel(
        id: 'LOAN-P91-002',
        userId: 'USR-CUST-91',
        userName: 'Customer P91',
        amount: 15000.0,
        tenureMonths: 6,
        purpose: 'Medical',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);

      // Simulate SyncEngine push completion marking queue item SYNCED
      final pendingList = await queueRepo.getPendingItems();
      final itemToUpdate = pendingList.firstWhere((i) => i.entityId == 'LOAN-P91-002');
      await queueRepo.updateStatus(itemToUpdate.id, 'SYNCED');

      await loanProvider.fetchUserLoans('USR-CUST-91');
      final syncStatus = loanProvider.getSyncStatus('LOAN-P91-002');

      expect(syncStatus, equals(LoanSyncStatus.synced));
      expect(syncStatus.label, equals('Server Verified'));
    });

    test('3. Failed synchronization displays SYNC_FAILED status', () async {
      final loan = LoanModel(
        id: 'LOAN-P91-003',
        userId: 'USR-CUST-91',
        userName: 'Customer P91',
        amount: 50000.0,
        tenureMonths: 24,
        purpose: 'Home Improvement',
        priority: LoanPriority.low,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);

      final pendingList = await queueRepo.getPendingItems();
      final itemToUpdate = pendingList.firstWhere((i) => i.entityId == 'LOAN-P91-003');
      await queueRepo.incrementRetry(itemToUpdate.id, error: 'HTTP 500 Server Error');

      await loanProvider.fetchUserLoans('USR-CUST-91');
      final syncStatus = loanProvider.getSyncStatus('LOAN-P91-003');

      expect(syncStatus, equals(LoanSyncStatus.syncFailed));
      expect(syncStatus.label, equals('Sync Failed'));
    });

    test('4. Local SQLite persistence remains intact during sync status checks', () async {
      final loan = LoanModel(
        id: 'LOAN-P91-004',
        userId: 'USR-CUST-91',
        userName: 'Customer P91',
        amount: 35000.0,
        tenureMonths: 18,
        purpose: 'Tools',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);
      final retrievedLoan = await loanRepo.getLoanById('LOAN-P91-004');

      expect(retrievedLoan, isNotNull);
      expect(retrievedLoan?.id, equals('LOAN-P91-004'));
      expect(retrievedLoan?.amount, equals(35000.0));
    });

    test('5. Sync status survives database re-query / app reload', () async {
      final loan = LoanModel(
        id: 'LOAN-P91-005',
        userId: 'USR-CUST-91',
        userName: 'Customer P91',
        amount: 10000.0,
        tenureMonths: 12,
        purpose: 'Electronics',
        priority: LoanPriority.low,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);

      // Re-create provider simulating app restart
      final freshProvider = LoanProvider(
        loanRepository: loanRepo,
        queueRepository: queueRepo,
      );

      await freshProvider.fetchUserLoans('USR-CUST-91');
      expect(freshProvider.getSyncStatus('LOAN-P91-005'), equals(LoanSyncStatus.pendingSync));
    });

    test('6. Status does NOT falsely become SYNCED before backend acceptance', () async {
      final loan = LoanModel(
        id: 'LOAN-P91-006',
        userId: 'USR-CUST-91',
        userName: 'Customer P91',
        amount: 40000.0,
        tenureMonths: 12,
        purpose: 'Personal',
        priority: LoanPriority.high,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);
      await loanProvider.fetchUserLoans('USR-CUST-91');

      final syncStatus = loanProvider.getSyncStatus('LOAN-P91-006');
      expect(syncStatus, isNot(equals(LoanSyncStatus.synced)));
      expect(syncStatus, equals(LoanSyncStatus.pendingSync));
    });

    testWidgets('7. LoanCard widget renders SyncStatusBadge correctly for PENDING_SYNC', (WidgetTester tester) async {
      final loan = LoanModel(
        id: 'LOAN-P91-WIDGET-1',
        userId: 'USR-CUST-91',
        userName: 'Customer P91',
        amount: 12000.0,
        tenureMonths: 6,
        purpose: 'Car Repair',
        priority: LoanPriority.medium,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      await loanRepo.createLoan(loan);
      await loanProvider.fetchUserLoans('USR-CUST-91');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider<LoanProvider>.value(
              value: loanProvider,
              child: LoanCard(
                loan: loan,
                onTap: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.byType(SyncStatusBadge), findsOneWidget);
      expect(find.text('Saved Offline'), findsOneWidget);
    });
  });
}

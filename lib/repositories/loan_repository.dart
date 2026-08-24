import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/loan_model.dart';
import '../models/loan_priority.dart';
import '../models/loan_status.dart';

/// Abstract interface for Loan Repository operations.
abstract class LoanRepository {
  Future<List<LoanModel>> getAllLoans();
  Future<List<LoanModel>> getUserLoans(String userId);
  Future<LoanModel?> getLoanById(String id);
  Future<LoanModel> createLoan(LoanModel loan);
  Future<LoanModel> updateLoanStatus(String id, LoanStatus newStatus);
}

/// Local implementation of LoanRepository using SharedPreferences persistence
/// and initial seed data for demo accounts.
class LocalLoanRepository implements LoanRepository {
  static const String _keyLoansData = 'key_loans_data_v1';

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

  Future<List<LoanModel>> _loadPersistedLoans() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_keyLoansData);
      if (jsonString == null || jsonString.isEmpty) {
        // Initialize with seed data on first run
        await _savePersistedLoans(_seedLoans);
        return List.from(_seedLoans);
      }
      final List<dynamic> decoded = jsonDecode(jsonString) as List<dynamic>;
      return decoded
          .map((item) => LoanModel.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return List.from(_seedLoans);
    }
  }

  Future<void> _savePersistedLoans(List<LoanModel> loans) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(loans.map((l) => l.toJson()).toList());
    await prefs.setString(_keyLoansData, encoded);
  }

  @override
  Future<List<LoanModel>> getAllLoans() async {
    await Future.delayed(const Duration(milliseconds: 300));
    final loans = await _loadPersistedLoans();
    loans.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return loans;
  }

  @override
  Future<List<LoanModel>> getUserLoans(String userId) async {
    await Future.delayed(const Duration(milliseconds: 300));
    final loans = await _loadPersistedLoans();
    final userLoans = loans.where((l) => l.userId == userId).toList();
    userLoans.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return userLoans;
  }

  @override
  Future<LoanModel?> getLoanById(String id) async {
    final loans = await _loadPersistedLoans();
    try {
      return loans.firstWhere((l) => l.id == id);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<LoanModel> createLoan(LoanModel loan) async {
    await Future.delayed(const Duration(milliseconds: 500));
    final loans = await _loadPersistedLoans();
    loans.insert(0, loan);
    await _savePersistedLoans(loans);
    return loan;
  }

  @override
  Future<LoanModel> updateLoanStatus(String id, LoanStatus newStatus) async {
    await Future.delayed(const Duration(milliseconds: 400));
    final loans = await _loadPersistedLoans();
    final index = loans.indexWhere((l) => l.id == id);
    if (index == -1) {
      throw Exception('Loan request not found');
    }
    final updated = loans[index].copyWith(status: newStatus);
    loans[index] = updated;
    await _savePersistedLoans(loans);
    return updated;
  }
}

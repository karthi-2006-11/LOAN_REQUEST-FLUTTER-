import 'package:flutter/foundation.dart';
import '../models/loan_model.dart';
import '../models/loan_priority.dart';
import '../models/loan_status.dart';
import '../repositories/loan_repository.dart';

class LoanProvider extends ChangeNotifier {
  final LoanRepository _loanRepository;

  bool _isLoading = false;
  String? _errorMessage;
  List<LoanModel> _userLoans = [];
  List<LoanModel> _allLoans = [];
  LoanStatus? _selectedStatusFilter;

  LoanProvider({LoanRepository? loanRepository})
      : _loanRepository = loanRepository ?? LocalLoanRepository();

  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  LoanStatus? get selectedStatusFilter => _selectedStatusFilter;

  /// All loans for the active user
  List<LoanModel> get userLoans => List.unmodifiable(_userLoans);

  /// All system loans (for Admin views)
  List<LoanModel> get allLoans => List.unmodifiable(_allLoans);

  /// Filtered view for user based on selected tab/chip
  List<LoanModel> get filteredLoans {
    if (_selectedStatusFilter == null) {
      return userLoans;
    }
    return _userLoans
        .where((loan) => loan.status == _selectedStatusFilter)
        .toList();
  }

  /// Filtered view for admin based on selected tab/chip
  List<LoanModel> get filteredAdminLoans {
    if (_selectedStatusFilter == null) {
      return allLoans;
    }
    return _allLoans
        .where((loan) => loan.status == _selectedStatusFilter)
        .toList();
  }

  // User Dashboard Metrics
  int get activeLoansCount => _userLoans
      .where((l) => l.status == LoanStatus.pending || l.status == LoanStatus.approved)
      .length;

  int get pendingLoansCount =>
      _userLoans.where((l) => l.status == LoanStatus.pending).length;

  double get totalAmountBorrowed => _userLoans
      .where((l) => l.status == LoanStatus.pending || l.status == LoanStatus.approved)
      .fold(0.0, (sum, loan) => sum + loan.amount);

  // Admin Dashboard Metrics
  int get totalLoansCount => _allLoans.length;

  int get adminPendingCount =>
      _allLoans.where((l) => l.status == LoanStatus.pending).length;

  int get approvedLoansCount =>
      _allLoans.where((l) => l.status == LoanStatus.approved).length;

  int get rejectedLoansCount =>
      _allLoans.where((l) => l.status == LoanStatus.rejected).length;

  /// Set status filter (null = All)
  void setFilter(LoanStatus? filter) {
    _selectedStatusFilter = filter;
    notifyListeners();
  }

  /// Fetch loans for current user
  Future<void> fetchUserLoans(String userId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _userLoans = await _loanRepository.getUserLoans(userId);
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Fetch all system loans (Admin flow)
  Future<void> fetchAllLoans() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _allLoans = await _loanRepository.getAllLoans();
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Create a new loan request
  Future<bool> createLoan({
    required String userId,
    required String userName,
    required double amount,
    required int tenureMonths,
    required String purpose,
    required LoanPriority priority,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final loanId = 'LOAN-${DateTime.now().millisecondsSinceEpoch.toString().substring(6)}';
      final newLoan = LoanModel(
        id: loanId,
        userId: userId,
        userName: userName,
        amount: amount,
        tenureMonths: tenureMonths,
        purpose: purpose,
        priority: priority,
        status: LoanStatus.pending,
        createdAt: DateTime.now(),
      );

      final created = await _loanRepository.createLoan(newLoan);
      _userLoans.insert(0, created);
      _allLoans.insert(0, created);
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      notifyListeners();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Find loan details by ID
  Future<LoanModel?> getLoanById(String id) async {
    try {
      return await _loanRepository.getLoanById(id);
    } catch (_) {
      return null;
    }
  }

  /// Admin/System status update support (Approve / Reject)
  Future<bool> updateLoanStatus(String loanId, LoanStatus newStatus) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final updated = await _loanRepository.updateLoanStatus(loanId, newStatus);

      // Update in _allLoans
      final adminIndex = _allLoans.indexWhere((l) => l.id == loanId);
      if (adminIndex != -1) {
        _allLoans[adminIndex] = updated;
      }

      // Update in _userLoans if loaded
      final userIndex = _userLoans.indexWhere((l) => l.id == loanId);
      if (userIndex != -1) {
        _userLoans[userIndex] = updated;
      }

      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      notifyListeners();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }
}

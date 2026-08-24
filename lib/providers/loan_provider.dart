import 'package:flutter/foundation.dart';
import '../models/loan_model.dart';
import '../models/loan_priority.dart';
import '../models/loan_status.dart';
import '../repositories/loan_repository.dart';

enum AdminSortOption {
  newest,
  oldest,
  highestAmount,
  lowestAmount,
  highestPriority,
}

extension AdminSortOptionExtension on AdminSortOption {
  String get label {
    switch (this) {
      case AdminSortOption.newest:
        return 'Newest First';
      case AdminSortOption.oldest:
        return 'Oldest First';
      case AdminSortOption.highestAmount:
        return 'Highest Amount';
      case AdminSortOption.lowestAmount:
        return 'Lowest Amount';
      case AdminSortOption.highestPriority:
        return 'Highest Priority';
    }
  }
}

class LoanProvider extends ChangeNotifier {
  final LoanRepository _loanRepository;

  bool _isLoading = false;
  String? _errorMessage;
  List<LoanModel> _userLoans = [];
  List<LoanModel> _allLoans = [];

  // Filter & Search State
  LoanStatus? _selectedStatusFilter;
  LoanPriority? _selectedPriorityFilter;
  String _searchQuery = '';
  AdminSortOption _selectedSortOption = AdminSortOption.newest;

  LoanProvider({LoanRepository? loanRepository})
      : _loanRepository = loanRepository ?? LocalLoanRepository();

  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  LoanStatus? get selectedStatusFilter => _selectedStatusFilter;
  LoanPriority? get selectedPriorityFilter => _selectedPriorityFilter;
  String get searchQuery => _searchQuery;
  AdminSortOption get selectedSortOption => _selectedSortOption;

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

  /// Filtered & Sorted view for admin
  List<LoanModel> get filteredAdminLoans {
    List<LoanModel> result = List.from(_allLoans);

    // 1. Status Filter
    if (_selectedStatusFilter != null) {
      result = result.where((l) => l.status == _selectedStatusFilter).toList();
    }

    // 2. Priority Filter
    if (_selectedPriorityFilter != null) {
      result = result.where((l) => l.priority == _selectedPriorityFilter).toList();
    }

    // 3. Search Query (Applicant name, Loan ID, Purpose)
    if (_searchQuery.trim().isNotEmpty) {
      final query = _searchQuery.trim().toLowerCase();
      result = result.where((l) {
        final nameMatch = l.userName.toLowerCase().contains(query);
        final idMatch = l.id.toLowerCase().contains(query);
        final purposeMatch = l.purpose.toLowerCase().contains(query);
        return nameMatch || idMatch || purposeMatch;
      }).toList();
    }

    // 4. Sorting
    switch (_selectedSortOption) {
      case AdminSortOption.newest:
        result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        break;
      case AdminSortOption.oldest:
        result.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        break;
      case AdminSortOption.highestAmount:
        result.sort((a, b) => b.amount.compareTo(a.amount));
        break;
      case AdminSortOption.lowestAmount:
        result.sort((a, b) => a.amount.compareTo(b.amount));
        break;
      case AdminSortOption.highestPriority:
        result.sort((a, b) => b.priority.index.compareTo(a.priority.index));
        break;
    }

    return List.unmodifiable(result);
  }

  // User Dashboard Metrics
  int get activeLoansCount => _userLoans
      .where((l) => l.status == LoanStatus.pending || l.status == LoanStatus.approved)
      .length;

  int get pendingLoansCount =>
      _userLoans.where((l) => l.status == LoanStatus.pending).length;

  int get userCancelledLoansCount =>
      _userLoans.where((l) => l.status == LoanStatus.cancelled).length;

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

  int get cancelledLoansCount =>
      _allLoans.where((l) => l.status == LoanStatus.cancelled).length;

  /// Set status filter (null = All)
  void setFilter(LoanStatus? filter) {
    _selectedStatusFilter = filter;
    notifyListeners();
  }

  /// Set priority filter (null = All)
  void setPriorityFilter(LoanPriority? priority) {
    _selectedPriorityFilter = priority;
    notifyListeners();
  }

  /// Set search query
  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  /// Set sort option
  void setSortOption(AdminSortOption option) {
    _selectedSortOption = option;
    notifyListeners();
  }

  /// Clear all admin search/filters
  void clearAdminFilters() {
    _searchQuery = '';
    _selectedStatusFilter = null;
    _selectedPriorityFilter = null;
    _selectedSortOption = AdminSortOption.newest;
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

  /// Customer Cancel Pending Loan Action
  Future<bool> cancelLoan(String loanId) async {
    final loan = await getLoanById(loanId);
    if (loan == null || loan.status != LoanStatus.pending) {
      _errorMessage = 'Only pending loans can be cancelled.';
      notifyListeners();
      return false;
    }
    return await updateLoanStatus(loanId, LoanStatus.cancelled);
  }

  /// Find loan details by ID
  Future<LoanModel?> getLoanById(String id) async {
    try {
      return await _loanRepository.getLoanById(id);
    } catch (_) {
      return null;
    }
  }

  /// Update Loan Status (Approve / Reject / Cancel)
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

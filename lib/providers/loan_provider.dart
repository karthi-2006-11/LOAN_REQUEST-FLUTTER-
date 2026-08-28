import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import '../models/loan_activity_model.dart';
import '../models/loan_model.dart';
import '../models/loan_priority.dart';
import '../models/loan_status.dart';
import '../models/loan_sync_status.dart';
import '../models/notification_model.dart';
import '../repositories/loan_activity_repository.dart';
import '../repositories/loan_repository.dart';
import '../repositories/notification_repository.dart';
import '../repositories/sync_queue_repository.dart';
import '../services/sync_coordinator.dart';

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
  final NotificationRepository _notificationRepository;
  final LoanActivityRepository _activityRepository;
  final SyncQueueRepository _queueRepository;
  final SyncCoordinator? _syncCoordinator;

  bool _isLoading = false;
  String? _errorMessage;
  List<LoanModel> _userLoans = [];
  List<LoanModel> _allLoans = [];
  List<LoanActivityModel> _currentLoanActivities = [];
  Map<String, LoanSyncStatus> _syncStatusMap = {};

  // Filter & Search State
  LoanStatus? _selectedStatusFilter;
  LoanPriority? _selectedPriorityFilter;
  String _searchQuery = '';
  AdminSortOption _selectedSortOption = AdminSortOption.newest;

  LoanProvider({
    LoanRepository? loanRepository,
    NotificationRepository? notificationRepository,
    LoanActivityRepository? activityRepository,
    SyncQueueRepository? queueRepository,
    SyncCoordinator? syncCoordinator,
  })  : _loanRepository = loanRepository ?? LocalLoanRepository(),
        _notificationRepository = notificationRepository ?? LocalNotificationRepository(),
        _activityRepository = activityRepository ?? LocalLoanActivityRepository(),
        _queueRepository = queueRepository ?? LocalSyncQueueRepository(),
        _syncCoordinator = syncCoordinator;

  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  LoanStatus? get selectedStatusFilter => _selectedStatusFilter;
  LoanPriority? get selectedPriorityFilter => _selectedPriorityFilter;
  String get searchQuery => _searchQuery;
  AdminSortOption get selectedSortOption => _selectedSortOption;

  /// Return customer-facing sync status for a loan
  LoanSyncStatus getSyncStatus(String loanId) {
    return _syncStatusMap[loanId] ?? LoanSyncStatus.synced;
  }

  /// Re-evaluate sync queue status for all loaded loans
  Future<void> refreshSyncStatuses() async {
    final newMap = <String, LoanSyncStatus>{};
    final allCombined = {..._userLoans, ..._allLoans};
    for (final loan in allCombined) {
      final statusStr = await _queueRepository.getLatestQueueStatus('loan', loan.id);
      if (statusStr == null || statusStr == 'SYNCED') {
        newMap[loan.id] = LoanSyncStatus.synced;
      } else if (statusStr == 'PENDING_SYNC' || statusStr == 'SYNCING') {
        newMap[loan.id] = LoanSyncStatus.pendingSync;
      } else if (statusStr == 'SYNC_FAILED' || statusStr == 'CONFLICT') {
        newMap[loan.id] = LoanSyncStatus.syncFailed;
      } else {
        newMap[loan.id] = LoanSyncStatus.synced;
      }
    }
    _syncStatusMap = newMap;
    notifyListeners();
  }

  /// All loans for the active user
  List<LoanModel> get userLoans => List.unmodifiable(_userLoans);

  /// All system loans (for Admin views)
  List<LoanModel> get allLoans => List.unmodifiable(_allLoans);

  /// Activities for currently inspected loan
  List<LoanActivityModel> get currentLoanActivities => List.unmodifiable(_currentLoanActivities);

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
      await refreshSyncStatuses();
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
      await refreshSyncStatuses();
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Fetch activity history for a specific loan
  Future<void> fetchLoanActivities(String loanId) async {
    try {
      _currentLoanActivities = await _activityRepository.getLoanActivities(loanId);
      notifyListeners();
    } catch (_) {
      _currentLoanActivities = [];
    }
  }

  /// Create a new loan request + Trigger Automatic Notifications & Activity
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

    final currencyFormatter = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);

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

      // 1. Create User Notification (1 Submission Notification)
      final userNotifId = 'NOTIF-SUB-${DateTime.now().millisecondsSinceEpoch}';
      await _notificationRepository.createNotification(
        NotificationModel(
          id: userNotifId,
          userId: userId,
          title: 'Loan Application Submitted',
          message: 'Your loan request $loanId for ${currencyFormatter.format(amount)} ($purpose) has been submitted and is pending review.',
          type: NotificationType.loanSubmitted,
          loanId: loanId,
          createdAt: DateTime.now(),
          isRead: false,
        ),
      );

      // 2. Create Admin Notification
      final adminNotifId = 'NOTIF-ADM-${DateTime.now().millisecondsSinceEpoch}';
      await _notificationRepository.createNotification(
        NotificationModel(
          id: adminNotifId,
          userId: 'admin',
          title: 'New Loan Application Submitted',
          message: 'Applicant $userName submitted loan request $loanId for ${currencyFormatter.format(amount)}.',
          type: NotificationType.loanSubmitted,
          loanId: loanId,
          createdAt: DateTime.now(),
          isRead: false,
        ),
      );

      // 3. Create Loan Activity Entry
      await _activityRepository.addActivity(
        LoanActivityModel(
          id: 'ACT-${DateTime.now().millisecondsSinceEpoch}',
          loanId: loanId,
          userId: userId,
          userName: userName,
          type: ActivityType.submitted,
          message: 'Loan application submitted for ${currencyFormatter.format(amount)}',
          createdAt: DateTime.now(),
        ),
      );

      await refreshSyncStatuses();
      notifyListeners();

      // Trigger post-mutation background synchronization (non-blocking, offline-safe)
      _syncCoordinator?.requestSync(
        trigger: SyncTrigger.postMutation,
        baseUrl: 'http://localhost:8080',
        authToken: 'session-token',
      );

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

  /// Customer Cancel Pending Loan Action + Trigger Automatic Notifications & Activity
  Future<bool> cancelLoan(String loanId) async {
    final loan = await getLoanById(loanId);
    if (loan == null || loan.status != LoanStatus.pending) {
      _errorMessage = 'Only pending loans can be cancelled.';
      notifyListeners();
      return false;
    }
    return await updateLoanStatus(loanId, LoanStatus.cancelled, targetLoan: loan);
  }

  /// Find loan details by ID
  Future<LoanModel?> getLoanById(String id) async {
    try {
      return await _loanRepository.getLoanById(id);
    } catch (_) {
      return null;
    }
  }

  /// Update Loan Status (Approve / Reject / Cancel) + Trigger Automatic Notifications & Activity
  Future<bool> updateLoanStatus(String loanId, LoanStatus newStatus, {LoanModel? targetLoan}) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    final currencyFormatter = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);

    try {
      final loan = targetLoan ?? await _loanRepository.getLoanById(loanId);
      if (loan == null) {
        _errorMessage = 'Loan application not found.';
        return false;
      }

      if (loan.isFinalized) {
        _errorMessage = 'State transition denied: Cannot modify a finalized (${loan.status.label}) loan application.';
        return false;
      }

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

      final amountStr = currencyFormatter.format(loan.amount);
      final userId = loan.userId;
      final userName = loan.userName;

      if (newStatus == LoanStatus.approved) {
        // User Notification
        await _notificationRepository.createNotification(
          NotificationModel(
            id: 'NOTIF-APP-${DateTime.now().millisecondsSinceEpoch}',
            userId: userId,
            title: 'Loan Approved',
            message: 'Great news! Your loan request $loanId for $amountStr has been approved by management.',
            type: NotificationType.loanApproved,
            loanId: loanId,
            createdAt: DateTime.now(),
            isRead: false,
          ),
        );

        // Activity Record
        await _activityRepository.addActivity(
          LoanActivityModel(
            id: 'ACT-APP-${DateTime.now().millisecondsSinceEpoch}',
            loanId: loanId,
            userId: userId,
            userName: userName,
            type: ActivityType.approved,
            message: 'Administrator approved loan application for $amountStr',
            createdAt: DateTime.now(),
          ),
        );
      } else if (newStatus == LoanStatus.rejected) {
        // User Notification
        await _notificationRepository.createNotification(
          NotificationModel(
            id: 'NOTIF-REJ-${DateTime.now().millisecondsSinceEpoch}',
            userId: userId,
            title: 'Loan Rejected',
            message: 'Your loan request $loanId for $amountStr has been rejected.',
            type: NotificationType.loanRejected,
            loanId: loanId,
            createdAt: DateTime.now(),
            isRead: false,
          ),
        );

        // Activity Record
        await _activityRepository.addActivity(
          LoanActivityModel(
            id: 'ACT-REJ-${DateTime.now().millisecondsSinceEpoch}',
            loanId: loanId,
            userId: userId,
            userName: userName,
            type: ActivityType.rejected,
            message: 'Administrator rejected loan application for $amountStr',
            createdAt: DateTime.now(),
          ),
        );
      } else if (newStatus == LoanStatus.cancelled) {
        // User Notification
        await _notificationRepository.createNotification(
          NotificationModel(
            id: 'NOTIF-CAN-${DateTime.now().millisecondsSinceEpoch}',
            userId: userId,
            title: 'Loan Application Cancelled',
            message: 'You cancelled your loan request $loanId for $amountStr.',
            type: NotificationType.loanCancelled,
            loanId: loanId,
            createdAt: DateTime.now(),
            isRead: false,
          ),
        );

        // Admin Notification
        await _notificationRepository.createNotification(
          NotificationModel(
            id: 'NOTIF-CAN-ADM-${DateTime.now().millisecondsSinceEpoch}',
            userId: 'admin',
            title: 'Loan Application Cancelled',
            message: 'Applicant $userName cancelled loan request $loanId for $amountStr.',
            type: NotificationType.loanCancelled,
            loanId: loanId,
            createdAt: DateTime.now(),
            isRead: false,
          ),
        );

        // Activity Record
        await _activityRepository.addActivity(
          LoanActivityModel(
            id: 'ACT-CAN-${DateTime.now().millisecondsSinceEpoch}',
            loanId: loanId,
            userId: userId,
            userName: userName,
            type: ActivityType.cancelled,
            message: 'Applicant $userName cancelled loan application',
            createdAt: DateTime.now(),
          ),
        );
      }

      await fetchLoanActivities(loanId);
      notifyListeners();

      // Trigger post-mutation background synchronization (non-blocking, offline-safe)
      _syncCoordinator?.requestSync(
        trigger: SyncTrigger.postMutation,
        baseUrl: 'http://localhost:8080',
        authToken: 'session-token',
      );

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

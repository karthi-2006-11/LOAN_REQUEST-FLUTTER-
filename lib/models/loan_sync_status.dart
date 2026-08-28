/// Customer-facing synchronization state of a loan application.
enum LoanSyncStatus {
  /// Loan exists locally in SQLite, but backend acceptance has not yet been confirmed.
  pendingSync,

  /// Backend has successfully accepted and verified the loan.
  synced,

  /// Synchronization was attempted but encountered an unrecovered error or conflict.
  syncFailed,
}

extension LoanSyncStatusExtension on LoanSyncStatus {
  String get label {
    switch (this) {
      case LoanSyncStatus.pendingSync:
        return 'Saved Offline';
      case LoanSyncStatus.synced:
        return 'Server Verified';
      case LoanSyncStatus.syncFailed:
        return 'Sync Failed';
    }
  }
}

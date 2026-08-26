/// Field ownership definitions for BlackVault Loan entity.
class LoanFieldOwnership {
  /// Fields owned by Customer while loan is pending review
  static const Set<String> customerOwnedFields = {
    'amount',
    'tenureMonths',
    'purpose',
    'priority',
  };

  /// Fields owned exclusively by Admin / Central Server
  static const Set<String> adminOwnedFields = {
    'status',
  };

  /// Immutable metadata fields
  static const Set<String> immutableFields = {
    'id',
    'userId',
    'createdAt',
  };

  static bool isCustomerOwned(String field) => customerOwnedFields.contains(field);
  static bool isAdminOwned(String field) => adminOwnedFields.contains(field);
  static bool isImmutable(String field) => immutableFields.contains(field);

  /// Inspect payload to determine if it contains any customer-owned fields
  static bool hasCustomerFields(Map<String, dynamic> payload) {
    return payload.keys.any((key) => isCustomerOwned(key));
  }

  /// Inspect payload to determine if it contains any admin-owned fields
  static bool hasAdminFields(Map<String, dynamic> payload) {
    return payload.keys.any((key) => isAdminOwned(key));
  }
}

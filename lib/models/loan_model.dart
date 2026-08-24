import 'loan_priority.dart';
import 'loan_status.dart';

/// Data model representing a customer loan request.
class LoanModel {
  final String id;
  final String userId;
  final String userName;
  final double amount;
  final int tenureMonths;
  final String purpose;
  final LoanPriority priority;
  final LoanStatus status;
  final DateTime createdAt;

  const LoanModel({
    required this.id,
    required this.userId,
    required this.userName,
    required this.amount,
    required this.tenureMonths,
    required this.purpose,
    required this.priority,
    required this.status,
    required this.createdAt,
  });

  /// Calculate estimated monthly payment without compounding interest (basic repayment)
  double get estimatedMonthlyPayment {
    if (tenureMonths <= 0) return 0.0;
    return amount / tenureMonths;
  }

  /// State helper checks
  bool get isPending => status == LoanStatus.pending;
  bool get isApproved => status == LoanStatus.approved;
  bool get isRejected => status == LoanStatus.rejected;
  bool get isCancelled => status == LoanStatus.cancelled;
  bool get canBeCancelled => status == LoanStatus.pending;
  bool get isFinalized => status != LoanStatus.pending;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'userId': userId,
      'userName': userName,
      'amount': amount,
      'tenureMonths': tenureMonths,
      'purpose': purpose,
      'priority': priority.toJson(),
      'status': status.toJson(),
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory LoanModel.fromJson(Map<String, dynamic> json) {
    return LoanModel(
      id: json['id'] as String,
      userId: json['userId'] as String,
      userName: json['userName'] as String? ?? 'Valued Customer',
      amount: (json['amount'] as num).toDouble(),
      tenureMonths: json['tenureMonths'] as int,
      purpose: json['purpose'] as String,
      priority: LoanPriorityExtension.fromString(json['priority'] as String? ?? 'low'),
      status: LoanStatusExtension.fromString(json['status'] as String? ?? 'pending'),
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
    );
  }

  LoanModel copyWith({
    String? id,
    String? userId,
    String? userName,
    double? amount,
    int? tenureMonths,
    String? purpose,
    LoanPriority? priority,
    LoanStatus? status,
    DateTime? createdAt,
  }) {
    return LoanModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      amount: amount ?? this.amount,
      tenureMonths: tenureMonths ?? this.tenureMonths,
      purpose: purpose ?? this.purpose,
      priority: priority ?? this.priority,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

class LoanServerModel {
  final String id;
  final String userId;
  final String userName;
  final double amount;
  final int tenureMonths;
  final String purpose;
  final String priority;
  final String status;
  final String? deviceId;
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;

  LoanServerModel({
    required this.id,
    required this.userId,
    required this.userName,
    required this.amount,
    required this.tenureMonths,
    required this.purpose,
    required this.priority,
    required this.status,
    this.deviceId,
    this.version = 1,
    required this.createdAt,
    required this.updatedAt,
  });

  LoanServerModel copyWith({
    String? userName,
    double? amount,
    int? tenureMonths,
    String? purpose,
    String? priority,
    String? status,
    String? deviceId,
    int? version,
    DateTime? updatedAt,
  }) {
    return LoanServerModel(
      id: id,
      userId: userId,
      userName: userName ?? this.userName,
      amount: amount ?? this.amount,
      tenureMonths: tenureMonths ?? this.tenureMonths,
      purpose: purpose ?? this.purpose,
      priority: priority ?? this.priority,
      status: status ?? this.status,
      deviceId: deviceId ?? this.deviceId,
      version: version ?? this.version,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'userId': userId,
        'userName': userName,
        'amount': amount,
        'tenureMonths': tenureMonths,
        'purpose': purpose,
        'priority': priority,
        'status': status,
        'deviceId': deviceId,
        'version': version,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  Map<String, dynamic> toSqlMap() => toJson();

  factory LoanServerModel.fromSqlMap(Map<String, dynamic> map) {
    return LoanServerModel(
      id: map['id'] as String,
      userId: map['userId'] as String,
      userName: map['userName'] as String,
      amount: (map['amount'] as num).toDouble(),
      tenureMonths: map['tenureMonths'] as int,
      purpose: map['purpose'] as String,
      priority: map['priority'] as String,
      status: map['status'] as String,
      deviceId: map['deviceId'] as String?,
      version: map['version'] as int? ?? 1,
      createdAt: DateTime.parse(map['createdAt'] as String),
      updatedAt: map['updatedAt'] != null
          ? DateTime.parse(map['updatedAt'] as String)
          : DateTime.parse(map['createdAt'] as String),
    );
  }
}

class UserServerModel {
  final String id;
  final String email;
  final String fullName;
  final String phone;
  final String role; // 'CUSTOMER' or 'ADMIN'
  final String passwordHash;
  final String? salt;
  final DateTime createdAt;
  final DateTime updatedAt;

  UserServerModel({
    required this.id,
    required this.email,
    required this.fullName,
    required this.phone,
    required this.role,
    required this.passwordHash,
    this.salt,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'fullName': fullName,
        'phone': phone,
        'role': role,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  Map<String, dynamic> toSqlMap() => {
        'id': id,
        'email': email,
        'fullName': fullName,
        'phone': phone,
        'role': role,
        'passwordHash': passwordHash,
        'salt': salt,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory UserServerModel.fromSqlMap(Map<String, dynamic> map) {
    return UserServerModel(
      id: map['id'] as String,
      email: map['email'] as String,
      fullName: map['fullName'] as String,
      phone: map['phone'] as String,
      role: map['role'] as String,
      passwordHash: map['passwordHash'] as String,
      salt: map['salt'] as String?,
      createdAt: DateTime.parse(map['createdAt'] as String),
      updatedAt: DateTime.parse(map['updatedAt'] as String),
    );
  }
}

import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../core/constants/app_constants.dart';
import '../models/user_model.dart';
import '../models/user_role.dart';

/// Abstract interface for authentication repository.
abstract class AuthRepository {
  Future<UserModel?> login({required String email, required String password});
  Future<UserModel> registerUser({
    required String fullName,
    required String email,
    required String phone,
    required String password,
  });
  Future<UserModel?> getUserById(String id);
  Future<UserModel?> getUserByEmail(String email);
}

/// Mock implementation of AuthRepository supporting in-memory storage,
/// seeded accounts (User & Admin), and hashed password verification.
class MockAuthRepository implements AuthRepository {
  // Hash passwords using SHA-256 for secure storage pattern
  static String _hashPassword(String password) {
    final bytes = utf8.encode('loan_app_salt_$password');
    return sha256.convert(bytes).toString();
  }

  // Pre-seeded users database
  static final List<UserModel> _users = [
    UserModel(
      id: 'USR-ADMIN-001',
      fullName: 'System Administrator',
      email: AppConstants.defaultAdminEmail,
      phone: '+1 (800) 555-0199',
      role: UserRole.admin,
      createdAt: DateTime(2025, 1, 1),
    ),
    UserModel(
      id: 'USR-DEMO-101',
      fullName: 'Alex Morgan',
      email: AppConstants.defaultUserEmail,
      phone: '+1 (555) 019-9834',
      role: UserRole.user,
      createdAt: DateTime(2025, 2, 15),
    ),
  ];

  // Hashed passwords storage
  static final Map<String, String> _passwords = {
    AppConstants.defaultAdminEmail.toLowerCase():
        _hashPassword(AppConstants.defaultAdminPassword),
    AppConstants.defaultUserEmail.toLowerCase():
        _hashPassword(AppConstants.defaultUserPassword),
  };

  @override
  Future<UserModel?> login({
    required String email,
    required String password,
  }) async {
    // Simulate network delay for realistic experience
    await Future.delayed(const Duration(milliseconds: 700));

    final normalizedEmail = email.trim().toLowerCase();
    final storedHash = _passwords[normalizedEmail];

    if (storedHash == null) {
      throw Exception('Account with this email does not exist.');
    }

    final inputHash = _hashPassword(password);
    if (storedHash != inputHash) {
      throw Exception('Invalid password. Please check your credentials.');
    }

    final user = _users.firstWhere(
      (u) => u.email.toLowerCase() == normalizedEmail,
      orElse: () => throw Exception('User record not found.'),
    );

    return user;
  }

  @override
  Future<UserModel> registerUser({
    required String fullName,
    required String email,
    required String phone,
    required String password,
  }) async {
    await Future.delayed(const Duration(milliseconds: 800));

    final normalizedEmail = email.trim().toLowerCase();

    if (_passwords.containsKey(normalizedEmail)) {
      throw Exception('An account with this email address already exists.');
    }

    final newUserId = 'USR-${DateTime.now().millisecondsSinceEpoch.toString().substring(5)}';

    // Strict Enforcement: All registered accounts via public flow MUST be 'user' role.
    final newUser = UserModel(
      id: newUserId,
      fullName: fullName.trim(),
      email: normalizedEmail,
      phone: phone.trim(),
      role: UserRole.user,
      createdAt: DateTime.now(),
    );

    _users.add(newUser);
    _passwords[normalizedEmail] = _hashPassword(password);

    return newUser;
  }

  @override
  Future<UserModel?> getUserById(String id) async {
    try {
      return _users.firstWhere((u) => u.id == id);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<UserModel?> getUserByEmail(String email) async {
    final normalized = email.trim().toLowerCase();
    try {
      return _users.firstWhere((u) => u.email.toLowerCase() == normalized);
    } catch (_) {
      return null;
    }
  }
}

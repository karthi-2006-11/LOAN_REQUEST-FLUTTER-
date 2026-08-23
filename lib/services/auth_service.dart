import 'package:shared_preferences/shared_preferences.dart';
import '../core/constants/app_constants.dart';
import '../models/user_model.dart';
import '../models/user_role.dart';
import '../repositories/auth_repository.dart';

/// Service managing authentication flow and local session persistence.
class AuthService {
  final AuthRepository _authRepository;

  AuthService({AuthRepository? authRepository})
      : _authRepository = authRepository ?? MockAuthRepository();

  /// Check if a persisted session exists on app launch
  Future<UserModel?> getPersistedSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isLoggedIn = prefs.getBool(AppConstants.keyIsLoggedIn) ?? false;
      if (!isLoggedIn) return null;

      final email = prefs.getString(AppConstants.keyUserEmail);
      if (email == null || email.isEmpty) return null;

      return await _authRepository.getUserByEmail(email);
    } catch (_) {
      return null;
    }
  }

  /// Perform user login and save session
  Future<UserModel> login({
    required String email,
    required String password,
  }) async {
    final user = await _authRepository.login(email: email, password: password);
    if (user == null) {
      throw Exception('Authentication failed. Invalid response.');
    }
    await _saveSession(user);
    return user;
  }

  /// Perform user registration and save session
  Future<UserModel> registerUser({
    required String fullName,
    required String email,
    required String phone,
    required String password,
  }) async {
    final user = await _authRepository.registerUser(
      fullName: fullName,
      email: email,
      phone: phone,
      password: password,
    );
    await _saveSession(user);
    return user;
  }

  /// Save user session locally
  Future<void> _saveSession(UserModel user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.keyIsLoggedIn, true);
    await prefs.setString(AppConstants.keyUserEmail, user.email);
    await prefs.setString(AppConstants.keyUserId, user.id);
    await prefs.setString(AppConstants.keyUserRole, user.role.nameString);
    await prefs.setString(AppConstants.keyUserName, user.fullName);
  }

  /// Logout and clear stored session
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppConstants.keyIsLoggedIn);
    await prefs.remove(AppConstants.keyUserEmail);
    await prefs.remove(AppConstants.keyUserId);
    await prefs.remove(AppConstants.keyUserRole);
    await prefs.remove(AppConstants.keyUserName);
  }
}

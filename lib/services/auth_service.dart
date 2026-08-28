import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../core/constants/app_constants.dart';
import '../models/auth_session.dart';
import '../models/user_model.dart';
import '../models/user_role.dart';
import '../repositories/auth_repository.dart';

/// Exceptions for Auth refresh classification
class AuthRequiredException implements Exception {
  final String message;
  AuthRequiredException(this.message);
  @override
  String toString() => message;
}

class TemporaryAuthException implements Exception {
  final String message;
  TemporaryAuthException(this.message);
  @override
  String toString() => message;
}

/// Service managing authentication flow and local session persistence.
class AuthService {
  final AuthRepository _authRepository;
  final http.Client _httpClient;
  Future<AuthSession?>? _refreshInFlight;

  AuthService({
    AuthRepository? authRepository,
    http.Client? httpClient,
  })  : _authRepository = authRepository ?? MockAuthRepository(),
        _httpClient = httpClient ?? http.Client();

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

  /// Retrieve active AuthSession from local storage
  Future<AuthSession?> getAuthSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isLoggedIn = prefs.getBool(AppConstants.keyIsLoggedIn) ?? false;
      if (!isLoggedIn) return null;

      final email = prefs.getString(AppConstants.keyUserEmail) ?? '';
      final userId = prefs.getString(AppConstants.keyUserId) ?? '';
      final userRole = prefs.getString(AppConstants.keyUserRole) ?? 'CUSTOMER';
      final userName = prefs.getString(AppConstants.keyUserName) ?? '';
      final accessToken = prefs.getString(AppConstants.keyAccessToken) ?? 'session-token';
      final refreshToken = prefs.getString(AppConstants.keyRefreshToken) ?? 'refresh-token';
      final expiresIso = prefs.getString(AppConstants.keyAccessTokenExpiresAt);
      final reauthRequired = prefs.getBool(AppConstants.keyReauthRequired) ?? false;

      final expiresAt = expiresIso != null ? DateTime.tryParse(expiresIso) ?? DateTime.now().add(const Duration(hours: 24)) : DateTime.now().add(const Duration(hours: 24));

      return AuthSession(
        userId: userId,
        email: email,
        role: userRole,
        fullName: userName,
        accessToken: accessToken,
        refreshToken: refreshToken,
        accessTokenExpiresAt: expiresAt,
        reauthRequired: reauthRequired,
      );
    } catch (_) {
      return null;
    }
  }

  /// Retrieve valid session, executing single-flight refresh if access token expired
  Future<AuthSession?> getValidSession({
    String baseUrl = 'http://localhost:8080',
  }) async {
    final session = await getAuthSession();
    if (session == null) return null;

    if (session.reauthRequired) return null;

    if (session.isAccessTokenValid) {
      return session;
    }

    // Access token expired -> Attempt refresh with single-flight protection
    return await refreshSessionIfNeeded(baseUrl: baseUrl);
  }

  /// Perform token refresh with single-flight deduplication
  Future<AuthSession?> refreshSessionIfNeeded({
    String baseUrl = 'http://localhost:8080',
  }) async {
    if (_refreshInFlight != null) {
      return await _refreshInFlight;
    }

    final completerFuture = _performRefreshInternal(baseUrl: baseUrl);
    _refreshInFlight = completerFuture;

    try {
      final result = await completerFuture;
      return result;
    } finally {
      _refreshInFlight = null;
    }
  }

  Future<AuthSession?> _performRefreshInternal({
    required String baseUrl,
  }) async {
    final session = await getAuthSession();
    if (session == null) {
      throw AuthRequiredException('No session available to refresh');
    }

    if (session.refreshToken.isEmpty) {
      await _flagReauthRequired();
      throw AuthRequiredException('Missing refresh token');
    }

    try {
      final uri = Uri.parse('$baseUrl/api/auth/refresh');
      final response = await _httpClient.post(
        uri,
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'refreshToken': session.refreshToken}),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final data = body['data'] as Map<String, dynamic>?;
        final newAccessToken = data?['token'] as String?;
        final newRefreshToken = data?['refreshToken'] as String?;
        final expiresInSeconds = data?['expiresIn'] as int? ?? 86400;

        if (newAccessToken != null && newRefreshToken != null) {
          final newExpiresAt = DateTime.now().add(Duration(seconds: expiresInSeconds));
          final updatedSession = session.copyWith(
            accessToken: newAccessToken,
            refreshToken: newRefreshToken,
            accessTokenExpiresAt: newExpiresAt,
            reauthRequired: false,
          );
          await _saveSessionTokens(updatedSession);
          return updatedSession;
        }
      }

      if (response.statusCode == 401 || response.statusCode == 403) {
        await _flagReauthRequired();
        throw AuthRequiredException('Refresh token rejected with HTTP ${response.statusCode}');
      }

      throw TemporaryAuthException('Server error HTTP ${response.statusCode} during token refresh');
    } on AuthRequiredException {
      rethrow;
    } on TemporaryAuthException {
      rethrow;
    } catch (e) {
      throw TemporaryAuthException('Network failure during token refresh: $e');
    }
  }

  Future<void> _flagReauthRequired() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.keyReauthRequired, true);
  }

  /// Perform user login and save session
  Future<UserModel> login({
    required String email,
    required String password,
    String accessToken = 'session-token',
    String refreshToken = 'refresh-token',
  }) async {
    final user = await _authRepository.login(email: email, password: password);
    if (user == null) {
      throw Exception('Authentication failed. Invalid response.');
    }
    await _saveSession(user, accessToken: accessToken, refreshToken: refreshToken);
    return user;
  }

  /// Perform user registration and save session
  Future<UserModel> registerUser({
    required String fullName,
    required String email,
    required String phone,
    required String password,
    String accessToken = 'session-token',
    String refreshToken = 'refresh-token',
  }) async {
    final user = await _authRepository.registerUser(
      fullName: fullName,
      email: email,
      phone: phone,
      password: password,
    );
    await _saveSession(user, accessToken: accessToken, refreshToken: refreshToken);
    return user;
  }

  /// Save user session locally
  Future<void> _saveSession(
    UserModel user, {
    String accessToken = 'session-token',
    String refreshToken = 'refresh-token',
    int expiresInSeconds = 86400,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final expiresAt = DateTime.now().add(Duration(seconds: expiresInSeconds));

    await prefs.setBool(AppConstants.keyIsLoggedIn, true);
    await prefs.setString(AppConstants.keyUserEmail, user.email);
    await prefs.setString(AppConstants.keyUserId, user.id);
    await prefs.setString(AppConstants.keyUserRole, user.role.nameString);
    await prefs.setString(AppConstants.keyUserName, user.fullName);
    await prefs.setString(AppConstants.keyAccessToken, accessToken);
    await prefs.setString(AppConstants.keyRefreshToken, refreshToken);
    await prefs.setString(AppConstants.keyAccessTokenExpiresAt, expiresAt.toIso8601String());
    await prefs.setBool(AppConstants.keyReauthRequired, false);
  }

  /// Atomically save updated session tokens
  Future<void> _saveSessionTokens(AuthSession session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.keyAccessToken, session.accessToken);
    await prefs.setString(AppConstants.keyRefreshToken, session.refreshToken);
    await prefs.setString(AppConstants.keyAccessTokenExpiresAt, session.accessTokenExpiresAt.toIso8601String());
    await prefs.setBool(AppConstants.keyReauthRequired, false);
  }

  /// Logout and clear stored session credentials while preserving offline SQLite loan data
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppConstants.keyIsLoggedIn);
    await prefs.remove(AppConstants.keyUserEmail);
    await prefs.remove(AppConstants.keyUserId);
    await prefs.remove(AppConstants.keyUserRole);
    await prefs.remove(AppConstants.keyUserName);
    await prefs.remove(AppConstants.keyAccessToken);
    await prefs.remove(AppConstants.keyRefreshToken);
    await prefs.remove(AppConstants.keyAccessTokenExpiresAt);
    await prefs.remove(AppConstants.keyReauthRequired);
  }
}

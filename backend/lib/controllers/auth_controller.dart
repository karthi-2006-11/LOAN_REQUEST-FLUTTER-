import 'dart:convert';
import 'package:shelf/shelf.dart';
import '../config/env_config.dart';
import '../models/user_server_model.dart';
import '../repositories/user_backend_repository.dart';
import '../utils/jwt_util.dart';
import '../utils/password_util.dart';

class AuthController {
  final UserBackendRepository userRepository;
  final EnvConfig config;

  AuthController({required this.userRepository, required this.config});

  static final Set<String> _activeRefreshTokens = {};

  Future<Response> register(Request request) async {
    try {
      final bodyStr = await request.readAsString();
      if (bodyStr.isEmpty) {
        return _jsonResponse(400, {'success': false, 'error': {'code': 'INVALID_BODY', 'message': 'Request body is empty'}});
      }

      final body = jsonDecode(bodyStr) as Map<String, dynamic>;
      final email = (body['email'] as String?)?.trim();
      final password = body['password'] as String?;
      final fullName = (body['fullName'] as String?)?.trim();
      final phone = (body['phone'] as String?)?.trim() ?? '';
      final role = (body['role'] as String?)?.toUpperCase() ?? 'CUSTOMER';

      if (email == null || email.isEmpty || !email.contains('@')) {
        return _jsonResponse(400, {'success': false, 'error': {'code': 'INVALID_EMAIL', 'message': 'Valid email is required'}});
      }
      if (password == null || password.length < 6) {
        return _jsonResponse(400, {'success': false, 'error': {'code': 'INVALID_PASSWORD', 'message': 'Password must be at least 6 characters'}});
      }
      if (fullName == null || fullName.isEmpty) {
        return _jsonResponse(400, {'success': false, 'error': {'code': 'INVALID_NAME', 'message': 'Full name is required'}});
      }
      if (role != 'CUSTOMER' && role != 'ADMIN') {
        return _jsonResponse(400, {'success': false, 'error': {'code': 'INVALID_ROLE', 'message': 'Role must be CUSTOMER or ADMIN'}});
      }

      final existing = await userRepository.findByEmail(email);
      if (existing != null) {
        return _jsonResponse(409, {'success': false, 'error': {'code': 'EMAIL_EXISTS', 'message': 'User with this email already exists'}});
      }

      final id = body['id'] as String? ?? 'USR-${DateTime.now().millisecondsSinceEpoch}';
      final passwordHash = PasswordUtil.hashPassword(password);
      final now = DateTime.now();

      final newUser = UserServerModel(
        id: id,
        email: email.toLowerCase(),
        fullName: fullName,
        phone: phone,
        role: role,
        passwordHash: passwordHash,
        createdAt: now,
        updatedAt: now,
      );

      await userRepository.createUser(newUser);
      final token = JwtUtil.generateToken(userId: newUser.id, role: newUser.role, config: config);
      final refreshToken = JwtUtil.generateRefreshToken(userId: newUser.id, role: newUser.role, config: config);
      _activeRefreshTokens.add(refreshToken);

      return _jsonResponse(201, {
        'success': true,
        'data': {
          'user': newUser.toJson(),
          'token': token,
          'refreshToken': refreshToken,
          'expiresIn': config.jwtExpirationSeconds,
        }
      });
    } catch (e) {
      return _jsonResponse(500, {'success': false, 'error': {'code': 'SERVER_ERROR', 'message': e.toString()}});
    }
  }

  Future<Response> login(Request request) async {
    try {
      final bodyStr = await request.readAsString();
      if (bodyStr.isEmpty) {
        return _jsonResponse(400, {'success': false, 'error': {'code': 'INVALID_BODY', 'message': 'Request body is empty'}});
      }

      final body = jsonDecode(bodyStr) as Map<String, dynamic>;
      final email = (body['email'] as String?)?.trim();
      final password = body['password'] as String?;

      if (email == null || email.isEmpty || password == null || password.isEmpty) {
        return _jsonResponse(400, {'success': false, 'error': {'code': 'MISSING_CREDENTIALS', 'message': 'Email and password are required'}});
      }

      final user = await userRepository.findByEmail(email);
      if (user == null) {
        return _jsonResponse(401, {'success': false, 'error': {'code': 'INVALID_CREDENTIALS', 'message': 'Invalid email or password'}});
      }

      final isMatch = PasswordUtil.verifyPassword(password, user.passwordHash);
      if (!isMatch) {
        return _jsonResponse(401, {'success': false, 'error': {'code': 'INVALID_CREDENTIALS', 'message': 'Invalid email or password'}});
      }

      final token = JwtUtil.generateToken(userId: user.id, role: user.role, config: config);
      final refreshToken = JwtUtil.generateRefreshToken(userId: user.id, role: user.role, config: config);
      _activeRefreshTokens.add(refreshToken);

      return _jsonResponse(200, {
        'success': true,
        'data': {
          'user': user.toJson(),
          'token': token,
          'refreshToken': refreshToken,
          'expiresIn': config.jwtExpirationSeconds,
        }
      });
    } catch (e) {
      return _jsonResponse(500, {'success': false, 'error': {'code': 'SERVER_ERROR', 'message': e.toString()}});
    }
  }

  Future<Response> refresh(Request request) async {
    try {
      final bodyStr = await request.readAsString();
      if (bodyStr.isEmpty) {
        return _jsonResponse(400, {'success': false, 'error': {'code': 'INVALID_BODY', 'message': 'Request body is empty'}});
      }

      final body = jsonDecode(bodyStr) as Map<String, dynamic>;
      final refreshTokenStr = (body['refreshToken'] as String?)?.trim();

      if (refreshTokenStr == null || refreshTokenStr.isEmpty) {
        return _jsonResponse(400, {'success': false, 'error': {'code': 'MISSING_REFRESH_TOKEN', 'message': 'Refresh token is required'}});
      }

      final verified = JwtUtil.verifyRefreshToken(refreshTokenStr, config);
      if (verified == null) {
        return _jsonResponse(401, {'success': false, 'error': {'code': 'INVALID_REFRESH_TOKEN', 'message': 'Refresh token is invalid or expired'}});
      }

      // Check if refresh token was already revoked / rotated
      if (!_activeRefreshTokens.contains(refreshTokenStr)) {
        return _jsonResponse(401, {'success': false, 'error': {'code': 'REVOKED_REFRESH_TOKEN', 'message': 'Refresh token has been revoked'}});
      }

      final user = await userRepository.findById(verified.userId);
      if (user == null) {
        return _jsonResponse(401, {'success': false, 'error': {'code': 'USER_NOT_FOUND', 'message': 'User no longer exists'}});
      }

      // Token Rotation: Revoke old refresh token, generate new access token and new refresh token
      _activeRefreshTokens.remove(refreshTokenStr);
      final newAccessToken = JwtUtil.generateToken(userId: user.id, role: user.role, config: config);
      final newRefreshToken = JwtUtil.generateRefreshToken(userId: user.id, role: user.role, config: config);
      _activeRefreshTokens.add(newRefreshToken);

      return _jsonResponse(200, {
        'success': true,
        'data': {
          'token': newAccessToken,
          'refreshToken': newRefreshToken,
          'expiresIn': config.jwtExpirationSeconds,
        }
      });
    } catch (e) {
      return _jsonResponse(500, {'success': false, 'error': {'code': 'SERVER_ERROR', 'message': e.toString()}});
    }
  }

  Response _jsonResponse(int statusCode, Map<String, dynamic> body) {
    return Response(
      statusCode,
      body: jsonEncode(body),
      headers: {'content-type': 'application/json'},
    );
  }
}

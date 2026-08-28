import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import '../config/env_config.dart';

class JWTResult {
  final String userId;
  final String role;
  final String? type;
  JWTResult({required this.userId, required this.role, this.type});
}

/// Utility for JWT token generation and verification
class JwtUtil {
  static String generateToken({
    required String userId,
    required String role,
    required EnvConfig config,
  }) {
    final jwt = JWT(
      {
        'sub': userId,
        'role': role,
        'type': 'access',
      },
      issuer: config.jwtIssuer,
    );

    return jwt.sign(
      SecretKey(config.jwtSecret),
      expiresIn: Duration(seconds: config.jwtExpirationSeconds),
    );
  }

  static String generateRefreshToken({
    required String userId,
    required String role,
    required EnvConfig config,
  }) {
    final nonce = DateTime.now().microsecondsSinceEpoch.toString();
    final jwt = JWT(
      {
        'sub': userId,
        'role': role,
        'type': 'refresh',
        'jti': nonce,
      },
      issuer: config.jwtIssuer,
    );

    // Refresh token expires in 30 days
    return jwt.sign(
      SecretKey(config.jwtSecret),
      expiresIn: const Duration(days: 30),
    );
  }

  static JWTResult? verifyToken(String token, EnvConfig config) {
    try {
      final jwt = JWT.verify(
        token,
        SecretKey(config.jwtSecret),
        issuer: config.jwtIssuer,
      );
      final payload = jwt.payload as Map<String, dynamic>;
      final type = payload['type'] as String?;
      if (type != null && type != 'access') return null;

      return JWTResult(
        userId: payload['sub'] as String,
        role: payload['role'] as String,
        type: type,
      );
    } catch (_) {
      return null;
    }
  }

  static JWTResult? verifyRefreshToken(String token, EnvConfig config) {
    try {
      final jwt = JWT.verify(
        token,
        SecretKey(config.jwtSecret),
        issuer: config.jwtIssuer,
      );
      final payload = jwt.payload as Map<String, dynamic>;
      final type = payload['type'] as String?;
      if (type != 'refresh') return null;

      return JWTResult(
        userId: payload['sub'] as String,
        role: payload['role'] as String,
        type: type,
      );
    } catch (_) {
      return null;
    }
  }
}

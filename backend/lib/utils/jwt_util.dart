import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import '../config/env_config.dart';

class JWTResult {
  final String userId;
  final String role;
  JWTResult({required this.userId, required this.role});
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
      },
      issuer: config.jwtIssuer,
    );

    return jwt.sign(
      SecretKey(config.jwtSecret),
      expiresIn: Duration(seconds: config.jwtExpirationSeconds),
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
      return JWTResult(
        userId: payload['sub'] as String,
        role: payload['role'] as String,
      );
    } catch (_) {
      return null;
    }
  }
}

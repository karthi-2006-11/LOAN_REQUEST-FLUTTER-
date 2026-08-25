import 'dart:convert';
import 'package:shelf/shelf.dart';
import '../config/env_config.dart';
import '../utils/jwt_util.dart';

class AuthUserContext {
  final String userId;
  final String role;
  AuthUserContext({required this.userId, required this.role});
}

Middleware buildAuthMiddleware(EnvConfig config) {
  return (Handler innerHandler) {
    return (Request request) async {
      final authHeader = request.headers['authorization'];
      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        return Response(
          401,
          body: jsonEncode({
            'success': false,
            'error': {
              'code': 'UNAUTHORIZED',
              'message': 'Missing or invalid Authorization header',
            }
          }),
          headers: {'content-type': 'application/json'},
        );
      }

      final token = authHeader.substring(7).trim();
      final jwtResult = JwtUtil.verifyToken(token, config);

      if (jwtResult == null) {
        return Response(
          401,
          body: jsonEncode({
            'success': false,
            'error': {
              'code': 'INVALID_TOKEN',
              'message': 'Token is invalid or expired',
            }
          }),
          headers: {'content-type': 'application/json'},
        );
      }

      final updatedRequest = request.change(
        context: {
          'authUser': AuthUserContext(
            userId: jwtResult.userId,
            role: jwtResult.role,
          ),
        },
      );

      return await innerHandler(updatedRequest);
    };
  };
}

AuthUserContext? getAuthUser(Request request) {
  final contextObj = request.context['authUser'];
  if (contextObj is AuthUserContext) {
    return contextObj;
  }
  return null;
}

import 'package:shelf/shelf.dart';
import 'package:shelf_cors_headers/shelf_cors_headers.dart';

Middleware buildCorsMiddleware() {
  return corsHeaders(
    headers: {
      'ACCESS_CONTROL_ALLOW_ORIGIN': '*',
      'ACCESS_CONTROL_ALLOW_METHODS': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
      'ACCESS_CONTROL_ALLOW_HEADERS': 'Origin, Content-Type, Authorization, X-Device-ID, X-Client-Operation-ID',
    },
  );
}

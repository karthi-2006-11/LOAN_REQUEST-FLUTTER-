import 'dart:convert';
import 'package:shelf/shelf.dart';

Middleware buildErrorMiddleware() {
  return (Handler innerHandler) {
    return (Request request) async {
      try {
        return await innerHandler(request);
      } catch (_) {
        return Response.internalServerError(
          body: jsonEncode({
            'success': false,
            'error': {
              'code': 'INTERNAL_SERVER_ERROR',
              'message': 'An unexpected error occurred on the server.',
            }
          }),
          headers: {'content-type': 'application/json'},
        );
      }
    };
  };
}

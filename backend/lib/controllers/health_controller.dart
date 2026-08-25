import 'dart:convert';
import 'package:shelf/shelf.dart';
import '../database/backend_database.dart';

class HealthController {
  final BackendDatabase database;

  HealthController({required this.database});

  Future<Response> handleHealthCheck(Request request) async {
    try {
      final db = await database.db;
      final result = await db.rawQuery('SELECT 1 as healthy');
      final dbHealthy = result.isNotEmpty && result.first['healthy'] == 1;

      return Response.ok(
        jsonEncode({
          'success': true,
          'status': 'HEALTHY',
          'database': dbHealthy ? 'CONNECTED' : 'DISCONNECTED',
          'timestamp': DateTime.now().toIso8601String(),
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({
          'success': false,
          'status': 'UNHEALTHY',
          'error': e.toString(),
        }),
        headers: {'content-type': 'application/json'},
      );
    }
  }
}

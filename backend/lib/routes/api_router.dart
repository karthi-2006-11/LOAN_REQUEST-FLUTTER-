import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import '../config/env_config.dart';
import '../controllers/auth_controller.dart';
import '../controllers/health_controller.dart';
import '../controllers/loan_controller.dart';
import '../middleware/auth_middleware.dart';

Router buildApiRouter({
  required HealthController healthController,
  required AuthController authController,
  required LoanController loanController,
  required EnvConfig config,
}) {
  final router = Router();

  // 1. Health check (unauthenticated)
  router.get('/health', healthController.handleHealthCheck);

  // 2. Auth routes (unauthenticated)
  router.post('/auth/register', authController.register);
  router.post('/auth/login', authController.login);

  // 3. Authenticated Loan routes
  final authMiddleware = buildAuthMiddleware(config);
  final loanPipeline = const Pipeline().addMiddleware(authMiddleware);

  router.get('/loans', loanPipeline.addHandler((request) => loanController.getLoans(request)));

  router.get('/loans/<id>', (Request request, String id) {
    final handler = loanPipeline.addHandler((req) => loanController.getLoanById(req, id));
    return handler(request);
  });

  router.post('/loans', loanPipeline.addHandler((request) => loanController.createLoan(request)));

  router.patch('/loans/<id>', (Request request, String id) {
    final handler = loanPipeline.addHandler((req) => loanController.updateLoan(req, id));
    return handler(request);
  });

  // 4. Sync route placeholders (Unimplemented in Phase 8.2; returns 501 Not Implemented)
  router.post('/sync/push', (Request request) async {
    return Response(501, body: jsonEncode({
      'success': false,
      'error': {'code': 'NOT_IMPLEMENTED', 'message': 'Push sync is scheduled for Phase 8.4'}
    }), headers: {'content-type': 'application/json'});
  });

  router.get('/sync/pull', (Request request) async {
    return Response(501, body: jsonEncode({
      'success': false,
      'error': {'code': 'NOT_IMPLEMENTED', 'message': 'Pull sync is scheduled for Phase 8.5'}
    }), headers: {'content-type': 'application/json'});
  });

  return router;
}

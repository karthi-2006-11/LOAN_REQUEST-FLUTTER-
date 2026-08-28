import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import '../config/env_config.dart';
import '../controllers/auth_controller.dart';
import '../controllers/health_controller.dart';
import '../controllers/loan_controller.dart';
import '../controllers/sync_backend_controller.dart';
import '../middleware/auth_middleware.dart';

Router buildApiRouter({
  required HealthController healthController,
  required AuthController authController,
  required LoanController loanController,
  required SyncBackendController syncController,
  required EnvConfig config,
}) {
  final router = Router();

  // 1. Health check (unauthenticated)
  router.get('/health', healthController.handleHealthCheck);

  // 2. Auth routes (unauthenticated)
  router.post('/auth/register', authController.register);
  router.post('/auth/login', authController.login);
  router.post('/auth/refresh', authController.refresh);

  // 3. Authenticated Loan & Sync routes
  final authMiddleware = buildAuthMiddleware(config);
  final authenticatedPipeline = const Pipeline().addMiddleware(authMiddleware);

  router.get('/loans', authenticatedPipeline.addHandler((request) => loanController.getLoans(request)));

  router.get('/loans/<id>', (Request request, String id) {
    final handler = authenticatedPipeline.addHandler((req) => loanController.getLoanById(req, id));
    return handler(request);
  });

  router.post('/loans', authenticatedPipeline.addHandler((request) => loanController.createLoan(request)));

  router.patch('/loans/<id>', (Request request, String id) {
    final handler = authenticatedPipeline.addHandler((req) => loanController.updateLoan(req, id));
    return handler(request);
  });

  // 4. Authenticated Push & Pull Sync
  router.post('/sync/push', authenticatedPipeline.addHandler((request) => syncController.handlePush(request)));
  router.get('/sync/pull', authenticatedPipeline.addHandler((request) => syncController.handlePull(request)));

  return router;
}

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'config/env_config.dart';
import 'controllers/auth_controller.dart';
import 'controllers/health_controller.dart';
import 'controllers/loan_controller.dart';
import 'controllers/sync_backend_controller.dart';
import 'database/backend_database.dart';
import 'middleware/cors_middleware.dart';
import 'middleware/error_middleware.dart';
import 'repositories/idempotency_repository.dart';
import 'repositories/loan_backend_repository.dart';
import 'repositories/user_backend_repository.dart';
import 'routes/api_router.dart';

class BlackVaultBackendApp {
  final EnvConfig config;
  final BackendDatabase database;
  final UserBackendRepository userRepository;
  final LoanBackendRepository loanRepository;
  final IdempotencyRepository idempotencyRepository;
  final HealthController healthController;
  final AuthController authController;
  final LoanController loanController;
  final SyncBackendController syncController;

  BlackVaultBackendApp._({
    required this.config,
    required this.database,
    required this.userRepository,
    required this.loanRepository,
    required this.idempotencyRepository,
    required this.healthController,
    required this.authController,
    required this.loanController,
    required this.syncController,
  });

  factory BlackVaultBackendApp.create({EnvConfig? configOverride, BackendDatabase? databaseOverride}) {
    final config = configOverride ?? EnvConfig.fromEnvironment();
    final database = databaseOverride ?? BackendDatabase(config: config);
    final userRepository = UserBackendRepository(database: database);
    final loanRepository = LoanBackendRepository(database: database);
    final idempotencyRepository = IdempotencyRepository(database: database);

    final healthController = HealthController(database: database);
    final authController = AuthController(userRepository: userRepository, config: config);
    final loanController = LoanController(
      loanRepository: loanRepository,
      idempotencyRepository: idempotencyRepository,
    );
    final syncController = SyncBackendController(
      loanRepository: loanRepository,
      idempotencyRepository: idempotencyRepository,
    );

    return BlackVaultBackendApp._(
      config: config,
      database: database,
      userRepository: userRepository,
      loanRepository: loanRepository,
      idempotencyRepository: idempotencyRepository,
      healthController: healthController,
      authController: authController,
      loanController: loanController,
      syncController: syncController,
    );
  }

  Handler buildHandler() {
    final router = Router();
    final apiRouter = buildApiRouter(
      healthController: healthController,
      authController: authController,
      loanController: loanController,
      syncController: syncController,
      config: config,
    );

    router.mount('/api', apiRouter.call);

    return const Pipeline()
        .addMiddleware(buildCorsMiddleware())
        .addMiddleware(buildErrorMiddleware())
        .addMiddleware(logRequests())
        .addHandler(router.call);
  }
}

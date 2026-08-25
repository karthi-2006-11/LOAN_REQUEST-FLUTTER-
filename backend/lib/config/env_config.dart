import 'dart:io';

/// Environment configuration loader for BlackVault backend.
class EnvConfig {
  final int port;
  final String dbPath;
  final String jwtSecret;
  final String jwtIssuer;
  final int jwtExpirationSeconds;
  final String environment;

  EnvConfig({
    required this.port,
    required this.dbPath,
    required this.jwtSecret,
    required this.jwtIssuer,
    required this.jwtExpirationSeconds,
    required this.environment,
  });

  factory EnvConfig.fromEnvironment({Map<String, String>? envOverride}) {
    final env = envOverride ?? Platform.environment;
    return EnvConfig(
      port: int.tryParse(env['PORT'] ?? '8080') ?? 8080,
      dbPath: env['DATABASE_PATH'] ?? 'backend_blackvault.db',
      jwtSecret: env['JWT_SECRET'] ?? 'blackvault_secure_jwt_secret_key_change_in_production',
      jwtIssuer: env['JWT_ISSUER'] ?? 'blackvault_backend',
      jwtExpirationSeconds: int.tryParse(env['JWT_EXPIRATION'] ?? '86400') ?? 86400,
      environment: env['ENVIRONMENT'] ?? 'development',
    );
  }
}

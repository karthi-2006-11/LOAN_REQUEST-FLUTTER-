import 'dart:io';
import 'package:shelf/shelf_io.dart' as io;
import 'package:blackvault_backend/app.dart';
import 'package:blackvault_backend/config/env_config.dart';

void main() async {
  final config = EnvConfig.fromEnvironment();
  final app = BlackVaultBackendApp.create(configOverride: config);

  final handler = app.buildHandler();
  final server = await io.serve(handler, InternetAddress.anyIPv4, config.port);

  print('🚀 BlackVault Backend Server running on http://${server.address.host}:${server.port}');
}

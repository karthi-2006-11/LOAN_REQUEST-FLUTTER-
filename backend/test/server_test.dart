import 'dart:convert';
import 'dart:io';
import 'package:blackvault_backend/app.dart';
import 'package:blackvault_backend/config/env_config.dart';
import 'package:blackvault_backend/database/backend_database.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

void main() {
  late EnvConfig testConfig;
  late String testDbPath;
  late BackendDatabase testDb;
  late BlackVaultBackendApp testApp;
  late HttpServer server;
  late String baseUrl;

  setUp(() async {
    final tempDir = Directory.systemTemp.createTempSync('backend_test_');
    testDbPath = p.join(tempDir.path, 'test_backend_blackvault.db');

    testConfig = EnvConfig(
      port: 0,
      dbPath: testDbPath,
      jwtSecret: 'test_jwt_secret_key_1234567890_super_secure',
      jwtIssuer: 'test_blackvault_backend',
      jwtExpirationSeconds: 3600,
      environment: 'test',
    );

    testDb = BackendDatabase(config: testConfig);
    testApp = BlackVaultBackendApp.create(
      configOverride: testConfig,
      databaseOverride: testDb,
    );

    final handler = testApp.buildHandler();
    server = await io.serve(handler, '127.0.0.1', 0);
    baseUrl = 'http://127.0.0.1:${server.port}/api';
  });

  tearDown(() async {
    await server.close(force: true);
    await testDb.close();
    final file = File(testDbPath);
    if (file.existsSync()) {
      file.deleteSync();
    }
  });

  group('BlackVault Backend Foundation & Concurrency Tests', () {
    test('1. GET /api/health returns HTTP 200 and HEALTHY database status', () async {
      final res = await http.get(Uri.parse('$baseUrl/health'));
      expect(res.statusCode, equals(200));

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['success'], isTrue);
      expect(body['status'], equals('HEALTHY'));
      expect(body['database'], equals('CONNECTED'));
    });

    test('2. Authentication: Argon2id password hashing and JWT login', () async {
      final regRes = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'email': 'customer1@blackvault.com',
          'password': 'SecurePassword123!',
          'fullName': 'Alice Morgan',
          'phone': '+1234567890',
          'role': 'CUSTOMER',
        }),
      );
      expect(regRes.statusCode, equals(201));

      final loginRes = await http.post(
        Uri.parse('$baseUrl/auth/login'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'email': 'customer1@blackvault.com',
          'password': 'SecurePassword123!',
        }),
      );
      expect(loginRes.statusCode, equals(200));
    });

    test('3. Authorization & Entity Version: Server loan initial version is 1 and increments on update', () async {
      final cRes = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': 'version@test.com', 'password': 'pass1234', 'fullName': 'V User', 'role': 'CUSTOMER'}),
      );
      final token = jsonDecode(cRes.body)['data']['token'] as String;

      final aRes = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': 'vadmin@test.com', 'password': 'pass1234', 'fullName': 'V Admin', 'role': 'ADMIN'}),
      );
      final aToken = jsonDecode(aRes.body)['data']['token'] as String;

      // 1. Create loan -> Initial version 1
      final createRes = await http.post(
        Uri.parse('$baseUrl/loans'),
        headers: {'content-type': 'application/json', 'authorization': 'Bearer $token'},
        body: jsonEncode({'id': 'LOAN-VER-001', 'amount': 10000.0, 'tenureMonths': 12, 'purpose': 'Equipment'}),
      );
      expect(createRes.statusCode, equals(201));
      final createdLoan = jsonDecode(createRes.body)['data'];
      expect(createdLoan['version'], equals(1));

      // 2. Admin update -> Version becomes 2
      final updateRes = await http.patch(
        Uri.parse('$baseUrl/loans/LOAN-VER-001'),
        headers: {'content-type': 'application/json', 'authorization': 'Bearer $aToken'},
        body: jsonEncode({'status': 'approved'}),
      );
      expect(updateRes.statusCode, equals(200));
      final updatedLoan = jsonDecode(updateRes.body)['data'];
      expect(updatedLoan['version'], equals(2));
      expect(updatedLoan['status'], equals('approved'));
    });

    test('4. Stale Push Detection: Push with baseVersion < current server version returns CONFLICT and serverState', () async {
      final cRes = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': 'stale@test.com', 'password': 'pass1234', 'fullName': 'Stale User', 'role': 'CUSTOMER'}),
      );
      final cToken = jsonDecode(cRes.body)['data']['token'] as String;

      final aRes = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': 'staleadmin@test.com', 'password': 'pass1234', 'fullName': 'Stale Admin', 'role': 'ADMIN'}),
      );
      final aToken = jsonDecode(aRes.body)['data']['token'] as String;

      // 1. Create loan (version 1)
      await http.post(
        Uri.parse('$baseUrl/loans'),
        headers: {'content-type': 'application/json', 'authorization': 'Bearer $cToken'},
        body: jsonEncode({'id': 'LOAN-STALE-100', 'amount': 15000.0, 'tenureMonths': 12, 'purpose': 'Business'}),
      );

      // 2. Admin approves loan (version becomes 2)
      await http.patch(
        Uri.parse('$baseUrl/loans/LOAN-STALE-100'),
        headers: {'content-type': 'application/json', 'authorization': 'Bearer $aToken'},
        body: jsonEncode({'status': 'approved'}),
      );

      // 3. Customer attempts stale push edit with baseVersion = 1 -> REJECTED with CONFLICT
      final pushRes = await http.post(
        Uri.parse('$baseUrl/sync/push'),
        headers: {'content-type': 'application/json', 'authorization': 'Bearer $cToken'},
        body: jsonEncode({
          'operations': [
            {
              'clientOperationId': 'OP-STALE-PUSH-1',
              'entityType': 'loan',
              'entityId': 'LOAN-STALE-100',
              'operation': 'UPDATE',
              'baseVersion': 1,
              'payload': {
                'id': 'LOAN-STALE-100',
                'amount': 20000.0,
              },
            }
          ]
        }),
      );
      expect(pushRes.statusCode, equals(200));
      final body = jsonDecode(pushRes.body);
      expect(body['results'][0]['status'], equals('CONFLICT'));
      expect(body['results'][0]['serverState'], isNotNull);
      expect(body['results'][0]['serverState']['version'], equals(2));
      expect(body['results'][0]['serverState']['status'], equals('approved'));

      // Verify server amount remained 15000 (unchanged)
      final serverLoan = await testApp.loanRepository.getLoanById('LOAN-STALE-100');
      expect(serverLoan!.amount, equals(15000.0));
      expect(serverLoan.version, equals(2));
    });

    test('5. Idempotency & Versioning: Replay with same clientOperationId returns cached result without re-incrementing version', () async {
      final cRes = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': 'idempver@test.com', 'password': 'pass1234', 'fullName': 'Idemp Ver', 'role': 'CUSTOMER'}),
      );
      final token = jsonDecode(cRes.body)['data']['token'] as String;

      const clientOpId = 'CLIENT-OP-VER-777';

      final res1 = await http.post(
        Uri.parse('$baseUrl/loans'),
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer $token',
          'x-client-operation-id': clientOpId,
        },
        body: jsonEncode({'id': 'LOAN-IDEMP-VER', 'amount': 8000.0, 'tenureMonths': 12, 'purpose': 'Tools'}),
      );
      expect(res1.statusCode, equals(201));

      final res2 = await http.post(
        Uri.parse('$baseUrl/loans'),
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer $token',
          'x-client-operation-id': clientOpId,
        },
        body: jsonEncode({'id': 'LOAN-IDEMP-VER', 'amount': 8000.0, 'tenureMonths': 12, 'purpose': 'Tools'}),
      );
      expect(res2.statusCode, equals(201));
      expect(res2.headers['x-idempotent-replay'], equals('true'));

      final loan = await testApp.loanRepository.getLoanById('LOAN-IDEMP-VER');
      expect(loan!.version, equals(1)); // Version remains 1!
    });

    test('6. Sync Endpoints Authentication: Unauthenticated push and pull requests are rejected with 401', () async {
      final unauthPushRes = await http.post(Uri.parse('$baseUrl/sync/push'));
      expect(unauthPushRes.statusCode, equals(401));

      final unauthPullRes = await http.get(Uri.parse('$baseUrl/sync/pull'));
      expect(unauthPullRes.statusCode, equals(401));
    });

    test('7. Push Sync Endpoint: Preserves originDeviceId and prevents duplicate sync_changes on retry', () async {
      final cRes = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': 'push@test.com', 'password': 'pass1234', 'fullName': 'Push User', 'role': 'CUSTOMER'}),
      );
      final cToken = jsonDecode(cRes.body)['data']['token'] as String;
      final cUser = jsonDecode(cRes.body)['data']['user'];
      final cUserId = cUser['id'] as String;

      const deviceId = 'DEV-CLIENT-ALPHA';

      final pushRes1 = await http.post(
        Uri.parse('$baseUrl/sync/push'),
        headers: {'content-type': 'application/json', 'authorization': 'Bearer $cToken'},
        body: jsonEncode({
          'operations': [
            {
              'clientOperationId': 'OP-PUSH-001',
              'entityType': 'loan',
              'entityId': 'LOAN-PUSH-001',
              'operation': 'CREATE',
              'deviceId': deviceId,
              'payload': {
                'id': 'LOAN-PUSH-001',
                'userId': cUserId,
                'userName': 'Push User',
                'amount': 18000.0,
                'tenureMonths': 12,
                'purpose': 'Inventory Expansion',
                'priority': 'high',
              },
            }
          ]
        }),
      );
      expect(pushRes1.statusCode, equals(200));

      final db = await testDb.db;
      final changes = await db.query('sync_changes', where: "entityId = 'LOAN-PUSH-001'");
      expect(changes.length, equals(1));
      expect(changes.first['originDeviceId'], equals(deviceId));

      final pushRes2 = await http.post(
        Uri.parse('$baseUrl/sync/push'),
        headers: {'content-type': 'application/json', 'authorization': 'Bearer $cToken'},
        body: jsonEncode({
          'operations': [
            {
              'clientOperationId': 'OP-PUSH-001',
              'entityType': 'loan',
              'entityId': 'LOAN-PUSH-001',
              'operation': 'CREATE',
              'payload': {},
            }
          ]
        }),
      );
      expect(pushRes2.statusCode, equals(200));

      final changesAfterRetry = await db.query('sync_changes', where: "entityId = 'LOAN-PUSH-001'");
      expect(changesAfterRetry.length, equals(1));
    });

    test('8. Pull Sync Endpoint: Global Cursor + Customer Filtering & Validation', () async {
      final caRes = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': 'custA@test.com', 'password': 'pass1234', 'fullName': 'Cust A', 'role': 'CUSTOMER'}),
      );
      final caToken = jsonDecode(caRes.body)['data']['token'] as String;

      final cbRes = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': 'custB@test.com', 'password': 'pass1234', 'fullName': 'Cust B', 'role': 'CUSTOMER'}),
      );
      final cbToken = jsonDecode(cbRes.body)['data']['token'] as String;

      await http.post(
        Uri.parse('$baseUrl/loans'),
        headers: {'content-type': 'application/json', 'authorization': 'Bearer $caToken'},
        body: jsonEncode({'id': 'LOAN-A-1', 'amount': 1000.0, 'tenureMonths': 6, 'purpose': 'P1'}),
      );
      await http.post(
        Uri.parse('$baseUrl/loans'),
        headers: {'content-type': 'application/json', 'authorization': 'Bearer $cbToken'},
        body: jsonEncode({'id': 'LOAN-B-1', 'amount': 2000.0, 'tenureMonths': 6, 'purpose': 'P2'}),
      );
      await http.post(
        Uri.parse('$baseUrl/loans'),
        headers: {'content-type': 'application/json', 'authorization': 'Bearer $caToken'},
        body: jsonEncode({'id': 'LOAN-A-2', 'amount': 3000.0, 'tenureMonths': 6, 'purpose': 'P3'}),
      );

      final pullA1 = await http.get(
        Uri.parse('$baseUrl/sync/pull?since=0&limit=1'),
        headers: {'authorization': 'Bearer $caToken'},
      );
      expect(pullA1.statusCode, equals(200));
      final bodyA1 = jsonDecode(pullA1.body);
      expect((bodyA1['changes'] as List).length, equals(1));
      expect(bodyA1['changes'][0]['serverVersion'], equals(1));
      expect(bodyA1['nextVersion'], equals(1));
      expect(bodyA1['hasMore'], isTrue);

      final pullA2 = await http.get(
        Uri.parse('$baseUrl/sync/pull?since=1&limit=1'),
        headers: {'authorization': 'Bearer $caToken'},
      );
      expect(pullA2.statusCode, equals(200));
      final bodyA2 = jsonDecode(pullA2.body);
      expect((bodyA2['changes'] as List).length, equals(1));
      expect(bodyA2['changes'][0]['serverVersion'], equals(3));
      expect(bodyA2['nextVersion'], equals(3));

      final invalidPull = await http.get(
        Uri.parse('$baseUrl/sync/pull?since=-1'),
        headers: {'authorization': 'Bearer $caToken'},
      );
      expect(invalidPull.statusCode, equals(400));
    });
  });
}

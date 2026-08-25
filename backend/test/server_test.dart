import 'dart:convert';
import 'dart:io';
import 'package:blackvault_backend/app.dart';
import 'package:blackvault_backend/config/env_config.dart';
import 'package:blackvault_backend/database/backend_database.dart';
import 'package:blackvault_backend/utils/password_util.dart';
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

  group('BlackVault Backend Foundation Tests', () {
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
      final regBody = jsonDecode(regRes.body) as Map<String, dynamic>;
      expect(regBody['success'], isTrue);
      expect(regBody['data']['token'], isNotEmpty);
      expect(regBody['data']['user']['passwordHash'], isNull);

      final userInDb = await testApp.userRepository.findByEmail('customer1@blackvault.com');
      expect(userInDb, isNotNull);
      expect(userInDb!.passwordHash.startsWith('\$argon2id\$'), isTrue);
      expect(PasswordUtil.verifyPassword('SecurePassword123!', userInDb.passwordHash), isTrue);

      final loginRes = await http.post(
        Uri.parse('$baseUrl/auth/login'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'email': 'customer1@blackvault.com',
          'password': 'SecurePassword123!',
        }),
      );
      expect(loginRes.statusCode, equals(200));

      final invalidRes = await http.post(
        Uri.parse('$baseUrl/auth/login'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'email': 'customer1@blackvault.com',
          'password': 'WrongPassword!',
        }),
      );
      expect(invalidRes.statusCode, equals(401));
    });

    test('3. Authorization: Customer data isolation and Admin permissions', () async {
      final c1Res = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': 'c1@test.com', 'password': 'pass1234', 'fullName': 'C1', 'role': 'CUSTOMER'}),
      );
      final c1Token = jsonDecode(c1Res.body)['data']['token'] as String;

      final c2Res = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': 'c2@test.com', 'password': 'pass1234', 'fullName': 'C2', 'role': 'CUSTOMER'}),
      );
      final c2Token = jsonDecode(c2Res.body)['data']['token'] as String;

      final adminRes = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': 'admin@test.com', 'password': 'adminpass', 'fullName': 'Admin', 'role': 'ADMIN'}),
      );
      final adminToken = jsonDecode(adminRes.body)['data']['token'] as String;

      final createLoanRes = await http.post(
        Uri.parse('$baseUrl/loans'),
        headers: {'content-type': 'application/json', 'authorization': 'Bearer $c1Token'},
        body: jsonEncode({
          'id': 'LOAN-C1-001',
          'amount': 25000.0,
          'tenureMonths': 12,
          'purpose': 'Business Expansion',
        }),
      );
      expect(createLoanRes.statusCode, equals(201));

      final c2AccessRes = await http.get(
        Uri.parse('$baseUrl/loans/LOAN-C1-001'),
        headers: {'authorization': 'Bearer $c2Token'},
      );
      expect(c2AccessRes.statusCode, equals(403));

      final adminAccessRes = await http.get(
        Uri.parse('$baseUrl/loans/LOAN-C1-001'),
        headers: {'authorization': 'Bearer $adminToken'},
      );
      expect(adminAccessRes.statusCode, equals(200));
    });

    test('4. Field Ownership: Customer cannot modify status; Admin owns status updates', () async {
      final cRes = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': 'c@test.com', 'password': 'pass1234', 'fullName': 'C', 'role': 'CUSTOMER'}),
      );
      final cToken = jsonDecode(cRes.body)['data']['token'] as String;

      final aRes = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': 'a@test.com', 'password': 'pass1234', 'fullName': 'A', 'role': 'ADMIN'}),
      );
      final aToken = jsonDecode(aRes.body)['data']['token'] as String;

      await http.post(
        Uri.parse('$baseUrl/loans'),
        headers: {'content-type': 'application/json', 'authorization': 'Bearer $cToken'},
        body: jsonEncode({'id': 'LOAN-OWN-1', 'amount': 15000.0, 'tenureMonths': 6, 'purpose': 'Personal'}),
      );

      final cApproveAttempt = await http.patch(
        Uri.parse('$baseUrl/loans/LOAN-OWN-1'),
        headers: {'content-type': 'application/json', 'authorization': 'Bearer $cToken'},
        body: jsonEncode({'status': 'approved'}),
      );
      expect(cApproveAttempt.statusCode, equals(403));

      final adminApprove = await http.patch(
        Uri.parse('$baseUrl/loans/LOAN-OWN-1'),
        headers: {'content-type': 'application/json', 'authorization': 'Bearer $aToken'},
        body: jsonEncode({'status': 'approved'}),
      );
      expect(adminApprove.statusCode, equals(200));

      final updatedLoan = jsonDecode(adminApprove.body)['data'];
      expect(updatedLoan['status'], equals('approved'));
    });

    test('5. Idempotency & Origin Device: Duplicate clientOperationId returns cached response without duplicating sync_changes', () async {
      final cRes = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': 'idemp@test.com', 'password': 'pass1234', 'fullName': 'Idemp', 'role': 'CUSTOMER'}),
      );
      final token = jsonDecode(cRes.body)['data']['token'] as String;

      const clientOpId = 'CLIENT-OP-UNIQUE-999';

      final res1 = await http.post(
        Uri.parse('$baseUrl/loans'),
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer $token',
          'x-client-operation-id': clientOpId,
        },
        body: jsonEncode({'id': 'LOAN-IDEMP-99', 'amount': 8000.0, 'tenureMonths': 12, 'purpose': 'Equipment'}),
      );
      expect(res1.statusCode, equals(201));

      final res2 = await http.post(
        Uri.parse('$baseUrl/loans'),
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer $token',
          'x-client-operation-id': clientOpId,
        },
        body: jsonEncode({'id': 'LOAN-IDEMP-99', 'amount': 8000.0, 'tenureMonths': 12, 'purpose': 'Equipment'}),
      );
      expect(res2.statusCode, equals(201));
      expect(res2.headers['x-idempotent-replay'], equals('true'));

      final allLoans = await testApp.loanRepository.getAllLoans();
      expect(allLoans.length, equals(1));

      // Verify sync_changes table contains exactly 1 record for this loan creation
      final db = await testDb.db;
      final changes = await db.query('sync_changes', where: "entityId = 'LOAN-IDEMP-99'");
      expect(changes.length, equals(1));
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

      // 1. Customer pushes new loan creation with deviceId
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

      // 2. Retry push with same clientOperationId -> Returns cached response, NO duplicate sync_changes
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
      expect(changesAfterRetry.length, equals(1)); // Still exactly 1 row!
    });

    test('8. Pull Sync Endpoint: Global Cursor + Customer Filtering & Validation', () async {
      // Register Customer A
      final caRes = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': 'custA@test.com', 'password': 'pass1234', 'fullName': 'Cust A', 'role': 'CUSTOMER'}),
      );
      final caToken = jsonDecode(caRes.body)['data']['token'] as String;

      // Register Customer B
      final cbRes = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': 'custB@test.com', 'password': 'pass1234', 'fullName': 'Cust B', 'role': 'CUSTOMER'}),
      );
      final cbToken = jsonDecode(cbRes.body)['data']['token'] as String;

      // Create sequence of server changes:
      // v1 -> Cust A
      // v2 -> Cust B
      // v3 -> Cust A
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

      // Customer A pulls since=0, limit=1
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

      // Customer A pulls since=1, limit=1 -> Must skip v2 (Customer B) and return v3 (Customer A)!
      final pullA2 = await http.get(
        Uri.parse('$baseUrl/sync/pull?since=1&limit=1'),
        headers: {'authorization': 'Bearer $caToken'},
      );
      expect(pullA2.statusCode, equals(200));
      final bodyA2 = jsonDecode(pullA2.body);
      expect((bodyA2['changes'] as List).length, equals(1));
      expect(bodyA2['changes'][0]['serverVersion'], equals(3));
      expect(bodyA2['nextVersion'], equals(3));

      // Validation: invalid since parameter rejected
      final invalidPull = await http.get(
        Uri.parse('$baseUrl/sync/pull?since=-1'),
        headers: {'authorization': 'Bearer $caToken'},
      );
      expect(invalidPull.statusCode, equals(400));
    });
  });
}

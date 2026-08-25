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
      port: 0, // Random available port
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
      // Register customer
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
      expect(regBody['data']['user']['passwordHash'], isNull); // Never expose hash in response

      // Verify stored database hash is formatted Argon2id
      final userInDb = await testApp.userRepository.findByEmail('customer1@blackvault.com');
      expect(userInDb, isNotNull);
      expect(userInDb!.passwordHash.startsWith('\$argon2id\$'), isTrue);
      expect(PasswordUtil.verifyPassword('SecurePassword123!', userInDb.passwordHash), isTrue);

      // Login customer
      final loginRes = await http.post(
        Uri.parse('$baseUrl/auth/login'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'email': 'customer1@blackvault.com',
          'password': 'SecurePassword123!',
        }),
      );
      expect(loginRes.statusCode, equals(200));
      final loginBody = jsonDecode(loginRes.body) as Map<String, dynamic>;
      expect(loginBody['success'], isTrue);
      expect(loginBody['data']['token'], isNotEmpty);

      // Invalid password rejected
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
      // Register Customer 1
      final c1Res = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': 'c1@test.com', 'password': 'pass1234', 'fullName': 'C1', 'role': 'CUSTOMER'}),
      );
      final c1Token = jsonDecode(c1Res.body)['data']['token'] as String;

      // Register Customer 2
      final c2Res = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': 'c2@test.com', 'password': 'pass1234', 'fullName': 'C2', 'role': 'CUSTOMER'}),
      );
      final c2Token = jsonDecode(c2Res.body)['data']['token'] as String;

      // Register Admin
      final adminRes = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': 'admin@test.com', 'password': 'adminpass', 'fullName': 'Admin', 'role': 'ADMIN'}),
      );
      final adminToken = jsonDecode(adminRes.body)['data']['token'] as String;

      // Customer 1 creates a loan
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

      // Customer 2 tries to access Customer 1's loan -> REJECTED 403 Forbidden
      final c2AccessRes = await http.get(
        Uri.parse('$baseUrl/loans/LOAN-C1-001'),
        headers: {'authorization': 'Bearer $c2Token'},
      );
      expect(c2AccessRes.statusCode, equals(403));

      // Admin accesses Customer 1's loan -> ALLOWED 200 OK
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

      // Customer attempts to set status = "approved" -> REJECTED 403
      final cApproveAttempt = await http.patch(
        Uri.parse('$baseUrl/loans/LOAN-OWN-1'),
        headers: {'content-type': 'application/json', 'authorization': 'Bearer $cToken'},
        body: jsonEncode({'status': 'approved'}),
      );
      expect(cApproveAttempt.statusCode, equals(403));

      // Admin approves status -> ALLOWED 200
      final adminApprove = await http.patch(
        Uri.parse('$baseUrl/loans/LOAN-OWN-1'),
        headers: {'content-type': 'application/json', 'authorization': 'Bearer $aToken'},
        body: jsonEncode({'status': 'approved'}),
      );
      expect(adminApprove.statusCode, equals(200));

      final updatedLoan = jsonDecode(adminApprove.body)['data'];
      expect(updatedLoan['status'], equals('approved'));
    });

    test('5. Idempotency Foundation: Duplicate clientOperationId returns cached response', () async {
      final cRes = await http.post(
        Uri.parse('$baseUrl/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': 'idemp@test.com', 'password': 'pass1234', 'fullName': 'Idemp', 'role': 'CUSTOMER'}),
      );
      final token = jsonDecode(cRes.body)['data']['token'] as String;

      const clientOpId = 'CLIENT-OP-UNIQUE-999';

      // Request 1
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
      expect(res1.headers['x-idempotent-replay'], isNull);

      // Request 2 (Retry with same clientOperationId)
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

      // Verify database contains exactly 1 loan record
      final allLoans = await testApp.loanRepository.getAllLoans();
      expect(allLoans.length, equals(1));
    });

    test('6. Unimplemented sync placeholders return HTTP 501 Not Implemented', () async {
      final pushRes = await http.post(Uri.parse('$baseUrl/sync/push'));
      expect(pushRes.statusCode, equals(501));

      final pullRes = await http.get(Uri.parse('$baseUrl/sync/pull'));
      expect(pullRes.statusCode, equals(501));
    });
  });
}

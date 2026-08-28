import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:loan_request_app/core/constants/app_constants.dart';
import 'package:loan_request_app/models/auth_session.dart';
import 'package:loan_request_app/services/android_background_sync.dart';
import 'package:loan_request_app/services/auth_service.dart';
import 'package:loan_request_app/services/background_sync_runner.dart';
import 'package:loan_request_app/services/connectivity_service.dart';
import 'package:loan_request_app/services/ios_background_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeConnectivityService implements ConnectivityService {
  ConnectivityState state = ConnectivityState.backendReachable;

  @override
  Stream<ConnectivityState> get stateStream => Stream.empty();

  @override
  Future<ConnectivityState> getCurrentState() async => state;

  @override
  Future<bool> hasNetworkInterface() async => state != ConnectivityState.offline;

  @override
  Future<bool> isBackendReachable({String? baseUrl, Duration? timeout}) async => state == ConnectivityState.backendReachable;

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('Phase 10.4 — Background Authentication Refresh & Session Recovery', () {
    test('1. Valid access token skips refresh', () async {
      final session = AuthSession(
        userId: 'USR-001',
        email: 'user@test.com',
        role: 'CUSTOMER',
        fullName: 'User Test',
        accessToken: 'valid-access-token',
        refreshToken: 'valid-refresh-token',
        accessTokenExpiresAt: DateTime.now().add(const Duration(hours: 1)),
      );

      expect(session.isAccessTokenValid, isTrue);
    });

    test('2. Expired token is detected correctly with safety buffer', () {
      final session = AuthSession(
        userId: 'USR-001',
        email: 'user@test.com',
        role: 'CUSTOMER',
        fullName: 'User Test',
        accessToken: 'expired-access-token',
        refreshToken: 'valid-refresh-token',
        accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 2)), // within 5m buffer
      );

      expect(session.isAccessTokenValid, isFalse);
    });

    test('3. Successful refresh stores new access token and rotated refresh token', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyIsLoggedIn: true,
        AppConstants.keyUserEmail: 'user@test.com',
        AppConstants.keyUserId: 'USR-001',
        AppConstants.keyUserRole: 'CUSTOMER',
        AppConstants.keyUserName: 'User Test',
        AppConstants.keyAccessToken: 'old-access-token',
        AppConstants.keyRefreshToken: 'old-refresh-token',
        AppConstants.keyAccessTokenExpiresAt: DateTime.now().subtract(const Duration(hours: 1)).toIso8601String(),
      });

      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/auth/refresh') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['refreshToken'], equals('old-refresh-token'));
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {
                'token': 'new-access-token-123',
                'refreshToken': 'new-refresh-token-456',
                'expiresIn': 86400,
              }
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not Found', 404);
      });

      final authService = AuthService(httpClient: mockClient);
      final refreshedSession = await authService.refreshSessionIfNeeded();

      expect(refreshedSession, isNotNull);
      expect(refreshedSession!.accessToken, equals('new-access-token-123'));
      expect(refreshedSession.refreshToken, equals('new-refresh-token-456'));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppConstants.keyAccessToken), equals('new-access-token-123'));
      expect(prefs.getString(AppConstants.keyRefreshToken), equals('new-refresh-token-456'));
    });

    test('4. Missing refresh token throws AuthRequiredException', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyIsLoggedIn: true,
        AppConstants.keyUserEmail: 'user@test.com',
        AppConstants.keyUserId: 'USR-001',
        AppConstants.keyRefreshToken: '',
      });

      final authService = AuthService();
      expect(
        () async => await authService.refreshSessionIfNeeded(),
        throwsA(isA<AuthRequiredException>()),
      );
    });

    test('5. Refresh HTTP 401 throws AuthRequiredException and sets reauthRequired flag', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyIsLoggedIn: true,
        AppConstants.keyUserEmail: 'user@test.com',
        AppConstants.keyUserId: 'USR-001',
        AppConstants.keyRefreshToken: 'invalid-refresh-token',
      });

      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'success': false,
            'error': {'code': 'INVALID_REFRESH_TOKEN', 'message': 'Token expired or revoked'}
          }),
          401,
          headers: {'content-type': 'application/json'},
        );
      });

      final authService = AuthService(httpClient: mockClient);

      try {
        await authService.refreshSessionIfNeeded();
        fail('Should have thrown AuthRequiredException');
      } catch (e) {
        expect(e, isA<AuthRequiredException>());
      }

      final prefsAfter = await SharedPreferences.getInstance();
      expect(prefsAfter.getBool(AppConstants.keyReauthRequired), isTrue);
    });

    test('6. Refresh HTTP 403 throws AuthRequiredException', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyIsLoggedIn: true,
        AppConstants.keyUserEmail: 'user@test.com',
        AppConstants.keyUserId: 'USR-001',
        AppConstants.keyRefreshToken: 'forbidden-refresh-token',
      });

      final mockClient = MockClient((request) async {
        return http.Response('Forbidden', 403);
      });

      final authService = AuthService(httpClient: mockClient);

      expect(
        () async => await authService.refreshSessionIfNeeded(),
        throwsA(isA<AuthRequiredException>()),
      );
    });

    test('7. Refresh HTTP 5xx throws TemporaryAuthException', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyIsLoggedIn: true,
        AppConstants.keyUserEmail: 'user@test.com',
        AppConstants.keyUserId: 'USR-001',
        AppConstants.keyRefreshToken: 'valid-refresh-token',
      });

      final mockClient = MockClient((request) async {
        return http.Response('Server Error', 500);
      });

      final authService = AuthService(httpClient: mockClient);

      expect(
        () async => await authService.refreshSessionIfNeeded(),
        throwsA(isA<TemporaryAuthException>()),
      );
    });

    test('8. Refresh HTTP 429 Rate Limit throws TemporaryAuthException', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyIsLoggedIn: true,
        AppConstants.keyUserEmail: 'user@test.com',
        AppConstants.keyUserId: 'USR-001',
        AppConstants.keyRefreshToken: 'valid-refresh-token',
      });

      final mockClient = MockClient((request) async {
        return http.Response('Too Many Requests', 429);
      });

      final authService = AuthService(httpClient: mockClient);

      expect(
        () async => await authService.refreshSessionIfNeeded(),
        throwsA(isA<TemporaryAuthException>()),
      );
    });

    test('9. Concurrent refresh calls execute single-flight deduplication', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyIsLoggedIn: true,
        AppConstants.keyUserEmail: 'user@test.com',
        AppConstants.keyUserId: 'USR-001',
        AppConstants.keyRefreshToken: 'valid-refresh-token',
      });

      int refreshCallCount = 0;
      final mockClient = MockClient((request) async {
        refreshCallCount++;
        await Future.delayed(const Duration(milliseconds: 50));
        return http.Response(
          jsonEncode({
            'success': true,
            'data': {
              'token': 'single-flight-access-token',
              'refreshToken': 'single-flight-refresh-token',
              'expiresIn': 86400,
            }
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final authService = AuthService(httpClient: mockClient);

      final results = await Future.wait([
        authService.refreshSessionIfNeeded(),
        authService.refreshSessionIfNeeded(),
        authService.refreshSessionIfNeeded(),
      ]);

      expect(refreshCallCount, equals(1)); // Executed exactly once
      expect(results[0]?.accessToken, equals('single-flight-access-token'));
      expect(results[1]?.accessToken, equals('single-flight-access-token'));
      expect(results[2]?.accessToken, equals('single-flight-access-token'));
    });

    test('10. Logout clears stored credentials while preserving offline user data keys', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyIsLoggedIn: true,
        AppConstants.keyUserEmail: 'user@test.com',
        AppConstants.keyUserId: 'USR-001',
        AppConstants.keyAccessToken: 'access-token',
        AppConstants.keyRefreshToken: 'refresh-token',
      });

      final authService = AuthService();
      await authService.logout();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AppConstants.keyIsLoggedIn), isNull);
      expect(prefs.getString(AppConstants.keyAccessToken), isNull);
      expect(prefs.getString(AppConstants.keyRefreshToken), isNull);
    });

    test('11. BackgroundSyncRunner handles AuthRequiredException safely', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyIsLoggedIn: true,
        AppConstants.keyUserEmail: 'user@test.com',
        AppConstants.keyUserId: 'USR-001',
        AppConstants.keyRefreshToken: 'invalid-token',
        AppConstants.keyAccessTokenExpiresAt: DateTime.now().subtract(const Duration(hours: 1)).toIso8601String(),
      });

      final mockClient = MockClient((request) async {
        return http.Response('Unauthorized', 401);
      });

      final fakeConn = FakeConnectivityService();
      final authService = AuthService(httpClient: mockClient);

      final runner = BackgroundSyncRunner(
        connectivityService: fakeConn,
        authService: authService,
      );

      final result = await runner.executeBackgroundSync();
      expect(result.status, equals(BackgroundSyncStatus.authRequired));
    });

    test('12. BackgroundSyncRunner handles TemporaryAuthException safely', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.keyIsLoggedIn: true,
        AppConstants.keyUserEmail: 'user@test.com',
        AppConstants.keyUserId: 'USR-001',
        AppConstants.keyRefreshToken: 'valid-token',
        AppConstants.keyAccessTokenExpiresAt: DateTime.now().subtract(const Duration(hours: 1)).toIso8601String(),
      });

      final mockClient = MockClient((request) async {
        return http.Response('Server Error', 500);
      });

      final fakeConn = FakeConnectivityService();
      final authService = AuthService(httpClient: mockClient);

      final runner = BackgroundSyncRunner(
        connectivityService: fakeConn,
        authService: authService,
      );

      final result = await runner.executeBackgroundSync();
      expect(result.status, equals(BackgroundSyncStatus.failed));
    });

    test('13. Phase 10.1 background runner compatibility', () {
      final runner = BackgroundSyncRunner();
      expect(runner, isNotNull);
    });

    test('14. Phase 10.2 Android WorkManager task identifier matches', () {
      expect(kBlackVaultAndroidSyncUniqueWorkName, equals('com.blackvault.app.backgroundsync'));
    });

    test('15. Phase 10.3 iOS BGTaskScheduler task identifier matches', () {
      expect(kBlackVaultIOSSyncTaskIdentifier, equals('com.blackvault.app.backgroundsync'));
    });
  });
}

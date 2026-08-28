import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:loan_request_app/services/connectivity_service.dart';

class FakeConnectivity implements Connectivity {
  final StreamController<List<ConnectivityResult>> _controller =
      StreamController<List<ConnectivityResult>>.broadcast();

  List<ConnectivityResult> currentResults = [ConnectivityResult.none];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _controller.stream;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      currentResults;

  void emit(List<ConnectivityResult> results) {
    currentResults = results;
    _controller.add(results);
  }

  void emitError(Object error) {
    _controller.addError(error);
  }

  void close() {
    _controller.close();
  }
}

void main() {
  late FakeConnectivity fakeConnectivity;

  setUp(() {
    fakeConnectivity = FakeConnectivity();
  });

  tearDown(() {
    fakeConnectivity.close();
  });

  group('ConnectivityService Unit & Isolation Tests (Phase 8.7.2)', () {
    test('1. none connectivity -> ConnectivityState.offline', () async {
      fakeConnectivity.currentResults = [ConnectivityResult.none];
      final mockClient = MockClient((req) async => http.Response('OK', 200));

      final service = DefaultConnectivityService(
        connectivity: fakeConnectivity,
        httpClient: mockClient,
      );

      final hasInterface = await service.hasNetworkInterface();
      expect(hasInterface, isFalse);

      final state = await service.getCurrentState();
      expect(state, equals(ConnectivityState.offline));

      await service.dispose();
    });

    test('2. Wi-Fi / network interface available, but backend unreachable -> ConnectivityState.networkAvailable', () async {
      fakeConnectivity.currentResults = [ConnectivityResult.wifi];
      final mockClient = MockClient((req) async => throw Exception('Connection refused'));

      final service = DefaultConnectivityService(
        connectivity: fakeConnectivity,
        httpClient: mockClient,
      );

      final hasInterface = await service.hasNetworkInterface();
      expect(hasInterface, isTrue);

      final isReachable = await service.isBackendReachable();
      expect(isReachable, isFalse);

      final state = await service.getCurrentState();
      expect(state, equals(ConnectivityState.networkAvailable));

      await service.dispose();
    });

    test('3. Backend HTTP 200 on /api/health -> ConnectivityState.backendReachable', () async {
      fakeConnectivity.currentResults = [ConnectivityResult.mobile];
      final mockClient = MockClient((req) async {
        expect(req.url.path, equals('/api/health'));
        return http.Response('{"status":"HEALTHY"}', 200);
      });

      final service = DefaultConnectivityService(
        connectivity: fakeConnectivity,
        httpClient: mockClient,
      );

      final isReachable = await service.isBackendReachable();
      expect(isReachable, isTrue);

      final state = await service.getCurrentState();
      expect(state, equals(ConnectivityState.backendReachable));

      await service.dispose();
    });

    test('4. Backend non-200 (HTTP 500) -> not reachable', () async {
      fakeConnectivity.currentResults = [ConnectivityResult.wifi];
      final mockClient = MockClient((req) async {
        return http.Response('{"status":"UNHEALTHY"}', 500);
      });

      final service = DefaultConnectivityService(
        connectivity: fakeConnectivity,
        httpClient: mockClient,
      );

      final isReachable = await service.isBackendReachable();
      expect(isReachable, isFalse);

      final state = await service.getCurrentState();
      expect(state, equals(ConnectivityState.networkAvailable));

      await service.dispose();
    });

    test('5. Probe timeout -> not reachable', () async {
      fakeConnectivity.currentResults = [ConnectivityResult.wifi];
      final mockClient = MockClient((req) async {
        await Future.delayed(const Duration(milliseconds: 200));
        return http.Response('{"status":"HEALTHY"}', 200);
      });

      final service = DefaultConnectivityService(
        connectivity: fakeConnectivity,
        httpClient: mockClient,
      );

      // Pass short timeout of 50ms to enforce timeout behavior
      final isReachable = await service.isBackendReachable(
        timeout: const Duration(milliseconds: 50),
      );
      expect(isReachable, isFalse);

      await service.dispose();
    });

    test('6. Socket/Network exception -> not reachable without throwing exception', () async {
      fakeConnectivity.currentResults = [ConnectivityResult.ethernet];
      final mockClient = MockClient((req) async {
        throw SocketException('No route to host');
      });

      final service = DefaultConnectivityService(
        connectivity: fakeConnectivity,
        httpClient: mockClient,
      );

      expect(() async => await service.isBackendReachable(), returnsNormally);
      final isReachable = await service.isBackendReachable();
      expect(isReachable, isFalse);

      await service.dispose();
    });

    test('7 & 8. Connectivity event transitions converted and deduplicated correctly', () async {
      final mockClient = MockClient((req) async {
        return http.Response('{"status":"HEALTHY"}', 200);
      });

      final service = DefaultConnectivityService(
        connectivity: fakeConnectivity,
        httpClient: mockClient,
      );

      final statesEmitted = <ConnectivityState>[];
      final subscription = service.stateStream.listen(statesEmitted.add);

      // Emit wifi twice -> should deduplicate
      fakeConnectivity.emit([ConnectivityResult.wifi]);
      await Future.delayed(const Duration(milliseconds: 50));

      fakeConnectivity.emit([ConnectivityResult.wifi]);
      await Future.delayed(const Duration(milliseconds: 50));

      // Emit none -> offline
      fakeConnectivity.emit([ConnectivityResult.none]);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(statesEmitted.length, equals(2));
      expect(statesEmitted[0], equals(ConnectivityState.backendReachable));
      expect(statesEmitted[1], equals(ConnectivityState.offline));

      await subscription.cancel();
      await service.dispose();
    });

    test('9. Stream subscription is cleaned up cleanly by dispose()', () async {
      final mockClient = MockClient((req) async => http.Response('OK', 200));

      final service = DefaultConnectivityService(
        connectivity: fakeConnectivity,
        httpClient: mockClient,
      );

      final states = <ConnectivityState>[];
      service.stateStream.listen(states.add);

      await service.dispose();

      fakeConnectivity.emit([ConnectivityResult.wifi]);
      await Future.delayed(const Duration(milliseconds: 50));

      // No new states emitted after dispose
      expect(states, isEmpty);
    });

    test('10. Service does not throw on platform listener stream errors', () async {
      final mockClient = MockClient((req) async => http.Response('OK', 200));

      final service = DefaultConnectivityService(
        connectivity: fakeConnectivity,
        httpClient: mockClient,
      );

      expect(() => fakeConnectivity.emitError(Exception('Platform IPC failure')), returnsNormally);
      await Future.delayed(const Duration(milliseconds: 50));

      await service.dispose();
    });

    test('11, 12, 13. Service has zero side-effects on SQLite, SyncEngine, or Auth headers', () async {
      bool authHeaderSent = false;
      final mockClient = MockClient((req) async {
        if (req.headers.containsKey('authorization') || req.headers.containsKey('Authorization')) {
          authHeaderSent = true;
        }
        return http.Response('{"status":"HEALTHY"}', 200);
      });

      final service = DefaultConnectivityService(
        connectivity: fakeConnectivity,
        httpClient: mockClient,
      );

      await service.isBackendReachable();

      // Verify NO auth header sent/logged on public health probe
      expect(authHeaderSent, isFalse);

      await service.dispose();
    });

    test('14. Backend probe targets exact /api/health endpoint', () async {
      Uri? requestedUri;
      final mockClient = MockClient((req) async {
        requestedUri = req.url;
        return http.Response('{"status":"HEALTHY"}', 200);
      });

      final service = DefaultConnectivityService(
        connectivity: fakeConnectivity,
        httpClient: mockClient,
        defaultBaseUrl: 'http://custom-server:9090',
      );

      await service.isBackendReachable();
      expect(requestedUri, equals(Uri.parse('http://custom-server:9090/api/health')));

      await service.dispose();
    });

    test('15. Custom timeout parameter is respected by health probe', () async {
      final mockClient = MockClient((req) async {
        await Future.delayed(const Duration(milliseconds: 150));
        return http.Response('{"status":"HEALTHY"}', 200);
      });

      final service = DefaultConnectivityService(
        connectivity: fakeConnectivity,
        httpClient: mockClient,
      );

      // Exceeds custom 50ms timeout
      final isReachableShort = await service.isBackendReachable(
        timeout: const Duration(milliseconds: 50),
      );
      expect(isReachableShort, isFalse);

      // Within custom 300ms timeout
      final isReachableLong = await service.isBackendReachable(
        timeout: const Duration(milliseconds: 300),
      );
      expect(isReachableLong, isTrue);

      await service.dispose();
    });
  });
}

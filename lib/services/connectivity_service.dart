import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;

/// Represents the three-tier connectivity state of the BlackVault client application.
enum ConnectivityState {
  /// No network interface (Wi-Fi, Mobile, Ethernet) is active.
  offline,

  /// Device has an active network interface, but the backend is not reachable.
  networkAvailable,

  /// Device has an active network interface AND central backend responded HTTP 200 to /api/health.
  backendReachable,
}

/// Abstract contract for device network connectivity and backend health probing.
abstract class ConnectivityService {
  /// Broadcast stream emitting connectivity state changes (deduplicated).
  Stream<ConnectivityState> get stateStream;

  /// Evaluate and return the current 3-tier connectivity state.
  Future<ConnectivityState> getCurrentState();

  /// Check whether the device has an active network interface (Wi-Fi, Mobile, Ethernet).
  Future<bool> hasNetworkInterface();

  /// Probe the central backend health endpoint (GET /api/health).
  Future<bool> isBackendReachable({String? baseUrl, Duration? timeout});

  /// Dispose stream controllers and cancel platform listeners.
  Future<void> dispose();
}

/// Production implementation of ConnectivityService utilizing connectivity_plus
/// and HTTP health probes against GET /api/health.
class DefaultConnectivityService implements ConnectivityService {
  final Connectivity _connectivity;
  final http.Client _httpClient;
  final String _defaultBaseUrl;

  final StreamController<ConnectivityState> _stateController =
      StreamController<ConnectivityState>.broadcast();

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  ConnectivityState? _lastEmittedState;
  bool _isDisposed = false;

  DefaultConnectivityService({
    Connectivity? connectivity,
    http.Client? httpClient,
    String defaultBaseUrl = 'http://localhost:8080',
  })  : _connectivity = connectivity ?? Connectivity(),
        _httpClient = httpClient ?? http.Client(),
        _defaultBaseUrl = defaultBaseUrl {
    _initConnectivityListener();
  }

  void _initConnectivityListener() {
    try {
      _connectivitySubscription = _connectivity.onConnectivityChanged.listen(
        (results) async {
          if (_isDisposed) return;
          try {
            final newState = await _computeStateFromResults(results);
            _emitState(newState);
          } catch (_) {
            // Silently swallow platform stream handler errors to prevent application crash
          }
        },
        onError: (_) {
          // Silently handle platform listener errors
        },
      );
    } catch (_) {
      // Platform listener initialization fallback
    }
  }

  Future<ConnectivityState> _computeStateFromResults(
      List<ConnectivityResult> results) async {
    final hasInterface = _isInterfaceAvailable(results);
    if (!hasInterface) {
      return ConnectivityState.offline;
    }

    final reachable = await isBackendReachable();
    if (reachable) {
      return ConnectivityState.backendReachable;
    }
    return ConnectivityState.networkAvailable;
  }

  bool _isInterfaceAvailable(List<ConnectivityResult> results) {
    if (results.isEmpty) return false;
    return results.any((result) =>
        result == ConnectivityResult.wifi ||
        result == ConnectivityResult.mobile ||
        result == ConnectivityResult.ethernet ||
        result == ConnectivityResult.vpn ||
        result == ConnectivityResult.other);
  }

  void _emitState(ConnectivityState state) {
    if (_isDisposed) return;
    if (_lastEmittedState != state) {
      _lastEmittedState = state;
      if (!_stateController.isClosed) {
        _stateController.add(state);
      }
    }
  }

  @override
  Stream<ConnectivityState> get stateStream => _stateController.stream;

  @override
  Future<bool> hasNetworkInterface() async {
    try {
      final results = await _connectivity.checkConnectivity();
      return _isInterfaceAvailable(results);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isBackendReachable({
    String? baseUrl,
    Duration? timeout,
  }) async {
    final targetBaseUrl = baseUrl ?? _defaultBaseUrl;
    final probeTimeout = timeout ?? const Duration(seconds: 3);
    final healthUri = Uri.parse('$targetBaseUrl/api/health');

    try {
      final response = await _httpClient
          .get(healthUri)
          .timeout(probeTimeout);

      return response.statusCode == 200;
    } on TimeoutException {
      return false;
    } on SocketException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<ConnectivityState> getCurrentState() async {
    final hasInterface = await hasNetworkInterface();
    if (!hasInterface) {
      return ConnectivityState.offline;
    }

    final reachable = await isBackendReachable();
    if (reachable) {
      return ConnectivityState.backendReachable;
    }
    return ConnectivityState.networkAvailable;
  }

  @override
  Future<void> dispose() async {
    _isDisposed = true;
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    await _stateController.close();
  }
}

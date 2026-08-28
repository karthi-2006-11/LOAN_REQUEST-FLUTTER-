import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../services/sync_coordinator.dart';

/// Flutter application lifecycle observer component.
/// Listens to app startup and foreground resume transitions to trigger
/// asynchronous synchronization via SyncCoordinator cleanly.
class AppLifecycleSyncObserver extends StatefulWidget {
  final Widget child;
  final SyncCoordinator? syncCoordinator;
  final AuthProvider? authProvider;
  final String baseUrl;

  const AppLifecycleSyncObserver({
    super.key,
    required this.child,
    this.syncCoordinator,
    this.authProvider,
    this.baseUrl = 'http://localhost:8080',
  });

  @override
  State<AppLifecycleSyncObserver> createState() =>
      _AppLifecycleSyncObserverState();
}

class _AppLifecycleSyncObserverState extends State<AppLifecycleSyncObserver>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Asynchronous Startup Sync Trigger (non-blocking for UI/splash rendering)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _triggerStartupSync();
    });
  }

  void _triggerStartupSync() {
    final coordinator =
        widget.syncCoordinator ?? context.read<SyncCoordinator>();
    final auth = widget.authProvider ?? context.read<AuthProvider>();

    if (auth.isAuthenticated) {
      coordinator.requestSync(
        trigger: SyncTrigger.startup,
        baseUrl: widget.baseUrl,
        authToken: 'session-token',
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final coordinator =
          widget.syncCoordinator ?? context.read<SyncCoordinator>();
      final auth = widget.authProvider ?? context.read<AuthProvider>();

      if (auth.isAuthenticated) {
        coordinator.requestSync(
          trigger: SyncTrigger.appResumed,
          baseUrl: widget.baseUrl,
          authToken: 'session-token',
        );
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

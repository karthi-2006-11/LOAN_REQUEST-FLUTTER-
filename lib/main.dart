import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'core/constants/app_constants.dart';
import 'core/theme/app_theme.dart';
import 'navigation/app_router.dart';
import 'providers/auth_provider.dart';
import 'providers/loan_provider.dart';
import 'providers/notification_provider.dart';
import 'services/migration_service.dart';
import 'services/sync_coordinator.dart';
import 'widgets/app_lifecycle_sync_observer.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MigrationService.instance.runMigration();
  runApp(const LoanRequestApp());
}

class LoanRequestApp extends StatelessWidget {
  const LoanRequestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<SyncCoordinator>(
          create: (_) => SyncCoordinator(),
          dispose: (_, coordinator) => coordinator.dispose(),
        ),
        ChangeNotifierProvider<AuthProvider>(
          create: (context) => AuthProvider(
            syncCoordinator: context.read<SyncCoordinator>(),
          ),
        ),
        ChangeNotifierProvider<LoanProvider>(
          create: (context) => LoanProvider(
            syncCoordinator: context.read<SyncCoordinator>(),
          ),
        ),
        ChangeNotifierProvider<NotificationProvider>(
          create: (_) => NotificationProvider(),
        ),
      ],
      child: AppLifecycleSyncObserver(
        child: MaterialApp(
          title: AppConstants.appName,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: ThemeMode.system,
          initialRoute: AppRouter.splash,
          onGenerateRoute: AppRouter.onGenerateRoute,
        ),
      ),
    );
  }
}

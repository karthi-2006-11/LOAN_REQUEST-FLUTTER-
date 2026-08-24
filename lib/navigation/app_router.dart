import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/user_role.dart';
import '../providers/auth_provider.dart';
import '../screens/admin/admin_dashboard_screen.dart';
import '../screens/admin/admin_loan_details_screen.dart';
import '../screens/admin/admin_notifications_screen.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/register_screen.dart';
import '../screens/auth/splash_screen.dart';
import '../screens/user/create_loan_screen.dart';
import '../screens/user/loan_details_screen.dart';
import '../screens/user/notifications_screen.dart';
import '../screens/user/user_dashboard_screen.dart';

class AppRouter {
  AppRouter._();

  static const String splash = '/';
  static const String login = '/login';
  static const String register = '/register';
  static const String userDashboard = '/user-dashboard';
  static const String adminDashboard = '/admin-dashboard';
  static const String createLoan = '/create-loan';
  static const String loanDetails = '/loan-details';
  static const String adminLoanDetails = '/admin-loan-details';
  static const String userNotifications = '/user-notifications';
  static const String adminNotifications = '/admin-notifications';

  static Map<String, WidgetBuilder> get routes => {
        splash: (context) => const SplashScreen(),
        login: (context) => const LoginScreen(),
        register: (context) => const RegisterScreen(),
        userDashboard: (context) => const UserDashboardScreen(),
        adminDashboard: (context) => const AdminDashboardScreen(),
        createLoan: (context) => const CreateLoanScreen(),
        userNotifications: (context) => const UserNotificationsScreen(),
        adminNotifications: (context) => const AdminNotificationsScreen(),
      };

  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    // Parameterized routes
    if (settings.name == loanDetails) {
      final loanId = settings.arguments as String? ?? '';
      return MaterialPageRoute(
        builder: (context) => _guardUserRoute(context, LoanDetailsScreen(loanId: loanId)),
        settings: settings,
      );
    }

    if (settings.name == adminLoanDetails) {
      final loanId = settings.arguments as String? ?? '';
      return MaterialPageRoute(
        builder: (context) => _guardAdminRoute(context, AdminLoanDetailsScreen(loanId: loanId)),
        settings: settings,
      );
    }

    if (settings.name == adminDashboard || settings.name == adminNotifications) {
      final builder = routes[settings.name];
      if (builder != null) {
        return MaterialPageRoute(
          builder: (context) => _guardAdminRoute(context, builder(context)),
          settings: settings,
        );
      }
    }

    if (settings.name == userDashboard ||
        settings.name == createLoan ||
        settings.name == userNotifications) {
      final builder = routes[settings.name];
      if (builder != null) {
        return MaterialPageRoute(
          builder: (context) => _guardUserRoute(context, builder(context)),
          settings: settings,
        );
      }
    }

    final builder = routes[settings.name];
    if (builder != null) {
      return MaterialPageRoute(
        builder: builder,
        settings: settings,
      );
    }

    return MaterialPageRoute(
      builder: (context) => const SplashScreen(),
    );
  }

  static Widget _guardAdminRoute(BuildContext context, Widget child) {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final user = auth.currentUser;
    if (user == null) {
      return const LoginScreen();
    }
    if (user.role != UserRole.admin) {
      return const UserDashboardScreen();
    }
    return child;
  }

  static Widget _guardUserRoute(BuildContext context, Widget child) {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final user = auth.currentUser;
    if (user == null) {
      return const LoginScreen();
    }
    return child;
  }
}

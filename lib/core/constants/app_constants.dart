/// Application-wide constants for BlackVault.
class AppConstants {
  AppConstants._();

  static const String appName = 'BlackVault';
  static const String appTagline = 'Secure Loans. Smarter Decisions.';
  static const String appVersion = '1.0.0';

  // Storage Keys for Shared Preferences
  static const String keyIsLoggedIn = 'key_is_logged_in';
  static const String keyUserEmail = 'key_user_email';
  static const String keyUserRole = 'key_user_role';
  static const String keyUserId = 'key_user_id';
  static const String keyUserName = 'key_user_name';

  // Seed / Demo Credentials (FOR DEMO & TEST PURPOSES)
  static const String defaultAdminEmail = 'admin@loanapp.com';
  static const String defaultAdminPassword = 'admin123';

  static const String defaultUserEmail = 'user@loanapp.com';
  static const String defaultUserPassword = 'user123';
}

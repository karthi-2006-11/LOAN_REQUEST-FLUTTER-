/// Model representing an authenticated user session with JWT access and refresh tokens.
class AuthSession {
  final String userId;
  final String email;
  final String role;
  final String fullName;
  final String accessToken;
  final String refreshToken;
  final DateTime accessTokenExpiresAt;
  final bool reauthRequired;

  AuthSession({
    required this.userId,
    required this.email,
    required this.role,
    required this.fullName,
    required this.accessToken,
    required this.refreshToken,
    required this.accessTokenExpiresAt,
    this.reauthRequired = false,
  });

  /// Check if access token is valid with a 5-minute safety buffer.
  bool get isAccessTokenValid {
    if (reauthRequired || accessToken.isEmpty) return false;
    final bufferTime = DateTime.now().add(const Duration(minutes: 5));
    return bufferTime.isBefore(accessTokenExpiresAt);
  }

  /// Create updated copy of AuthSession
  AuthSession copyWith({
    String? userId,
    String? email,
    String? role,
    String? fullName,
    String? accessToken,
    String? refreshToken,
    DateTime? accessTokenExpiresAt,
    bool? reauthRequired,
  }) {
    return AuthSession(
      userId: userId ?? this.userId,
      email: email ?? this.email,
      role: role ?? this.role,
      fullName: fullName ?? this.fullName,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      accessTokenExpiresAt: accessTokenExpiresAt ?? this.accessTokenExpiresAt,
      reauthRequired: reauthRequired ?? this.reauthRequired,
    );
  }
}

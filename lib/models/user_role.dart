/// User roles supported in the system.
enum UserRole {
  user,
  admin,
}

extension UserRoleExtension on UserRole {
  String get nameString {
    switch (this) {
      case UserRole.admin:
        return 'Admin';
      case UserRole.user:
        return 'User';
    }
  }

  bool get isAdmin => this == UserRole.admin;
  bool get isUser => this == UserRole.user;

  static UserRole fromString(String role) {
    if (role.toLowerCase() == 'admin') {
      return UserRole.admin;
    }
    return UserRole.user;
  }
}

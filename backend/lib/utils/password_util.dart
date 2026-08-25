import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:argon2/argon2.dart';

/// Password hashing utility using Argon2id Key Derivation Function.
class PasswordUtil {
  static Uint8List _generateSecureSalt() {
    final random = Random.secure();
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }

  /// Hash password using Argon2id with a secure cryptographically random salt
  static String hashPassword(String password, {String? saltHex}) {
    final saltBytes = saltHex != null
        ? _hexToBytes(saltHex)
        : _generateSecureSalt();

    final parameters = Argon2Parameters(
      Argon2Parameters.ARGON2_id,
      saltBytes,
      version: Argon2Parameters.ARGON2_VERSION_13,
      iterations: 2,
      memoryPowerOf2: 12, // 4MB RAM allocation
    );

    final generator = Argon2BytesGenerator();
    generator.init(parameters);

    final result = Uint8List(32);
    generator.generateBytes(utf8.encode(password), result, 0, result.length);

    final hashHex = _bytesToHex(result);
    final saltHexStr = _bytesToHex(saltBytes);
    return '\$argon2id\$v=19\$m=4096,t=2,p=1\$$saltHexStr\$$hashHex';
  }

  /// Verify a plaintext password against an Argon2id formatted hash string
  static bool verifyPassword(String password, String storedHashString) {
    try {
      final parts = storedHashString.split('\$');
      if (parts.length < 6) return false;
      final saltHex = parts[4];
      final computedHash = hashPassword(password, saltHex: saltHex);
      return computedHash == storedHashString;
    } catch (_) {
      return false;
    }
  }

  static String _bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < hex.length; i += 2) {
      result[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return result;
  }
}

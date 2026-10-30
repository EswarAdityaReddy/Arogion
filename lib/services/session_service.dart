import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class SessionService {
  static const String _loggedInUserKey = 'logged_in_user';

  static Future<void> saveLoggedInUser(Map<String, dynamic> user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_loggedInUserKey, jsonEncode(user));
  }

  static Future<Map<String, dynamic>?> restoreLoggedInUser() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_loggedInUserKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    } catch (_) {
      await prefs.remove(_loggedInUserKey);
    }

    return null;
  }

  static Future<void> clearLoggedInUser() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_loggedInUserKey);
  }
}

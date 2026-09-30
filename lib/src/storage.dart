import 'package:shared_preferences/shared_preferences.dart';

/// Key/value persistence for ids, session, consent, survey state and the offline queue.
abstract class MetrickleStorage {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
  Future<void> remove(String key);
}

/// Default storage: SharedPreferences (NSUserDefaults, Android SharedPreferences, localStorage on
/// web). Keys are stored as-is (`mk_aid`, `mk_uid`, …).
class SharedPreferencesStorage implements MetrickleStorage {
  SharedPreferencesStorage([SharedPreferencesAsync? prefs]) : _prefs = prefs ?? SharedPreferencesAsync();
  final SharedPreferencesAsync _prefs;

  @override
  Future<String?> get(String key) => _prefs.getString(key);
  @override
  Future<void> set(String key, String value) => _prefs.setString(key, value);
  @override
  Future<void> remove(String key) => _prefs.remove(key);
}

/// In-memory storage, for tests or apps that persist nothing across launches.
class MemoryStorage implements MetrickleStorage {
  final Map<String, String> data = {};

  @override
  Future<String?> get(String key) async => data[key];
  @override
  Future<void> set(String key, String value) async => data[key] = value;
  @override
  Future<void> remove(String key) async => data.remove(key);
}

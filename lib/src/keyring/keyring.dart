/// Secure storage edge for API keys. Implement over
/// `flutter_secure_storage` (iOS Keychain / Android Keystore) — see the
/// README recipe. Keys never touch plain files or SharedPreferences.
abstract interface class SecureStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<List<String>> listKeys();
}

/// In-memory [SecureStorage] for tests and previews.
class MemorySecureStorage implements SecureStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<List<String>> listKeys() async => _values.keys.toList(growable: false);
}

/// Bring-your-own-key vault: one named key per provider, with rotation
/// events so the app can react (e.g. reset caches, notify the user).
class Keyring {
  Keyring(this._storage);

  final SecureStorage _storage;
  final _rotations = <String, String>{};

  static const _prefix = 'llm_outbox.key.';

  /// Stores (or replaces) the API key for a provider, e.g. `openai`.
  /// Replacing an existing key records a rotation.
  Future<void> setKey(String provider, String apiKey) async {
    final existing = await getKey(provider);
    await _storage.write('$_prefix$provider', apiKey);
    if (existing != null && existing != apiKey) {
      _rotations[provider] = apiKey;
    }
  }

  /// The stored key for a provider, or null.
  Future<String?> getKey(String provider) => _storage.read('$_prefix$provider');

  /// Removes a provider's key.
  Future<void> removeKey(String provider) =>
      _storage.delete('$_prefix$provider');

  /// Providers that currently hold a key.
  Future<List<String>> providers() async {
    final keys = await _storage.listKeys();
    return keys
        .where((k) => k.startsWith(_prefix))
        .map((k) => k.substring(_prefix.length))
        .toList(growable: false);
  }

  /// True when [setKey] replaced an existing key since app start, and the
  /// old key should be considered stale everywhere.
  bool wasRotated(String provider) => _rotations.containsKey(provider);
}

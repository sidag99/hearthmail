import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Converts a plist file to JSON text (via /usr/bin/plutil). Injectable for
/// tests.
typedef PlistReader = Future<String?> Function(String path);

/// One-time move of app data from the old App Sandbox container to the normal
/// locations, after the sandbox was removed (needed to run CLI tools).
///
/// The old preferences file is read directly: asking `defaults` would not
/// work, because macOS keeps answering for this app from the old container.
///
/// Must run before [SettingsStore.open]. Never throws.
class SandboxMigration {
  static const bundleId = 'app.hearthmail.hearthmail';

  /// The app's own keys (SharedPreferences adds the "flutter." prefix).
  static const _prefix = 'flutter.';
  static const _accountsKey = 'accounts.v1';

  static Future<String?> _plutil(String path) async {
    final r = await Process.run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path]);
    return r.exitCode == 0 ? r.stdout as String : null;
  }

  /// Returns true if data was migrated.
  static Future<bool> run({
    String? home,
    bool? sandboxed,
    PlistReader? readPlist,
    SharedPreferences? prefs,
  }) async {
    try {
      if (!Platform.isMacOS && home == null) return false;
      final isSandboxed = sandboxed ?? Platform.environment.containsKey('APP_SANDBOX_CONTAINER_ID');
      if (isSandboxed) return false;
      final h = home ?? Platform.environment['HOME'];
      if (h == null || h.isEmpty) return false;

      final p = prefs ?? await SharedPreferences.getInstance();
      // Accounts already set up outside the sandbox: nothing to do.
      if (p.containsKey(_accountsKey)) return false;

      final lib = Directory('$h/Library/Containers/$bundleId/Data/Library');
      final plist = File('${lib.path}/Preferences/$bundleId.plist');
      if (!plist.existsSync()) return false;
      final text = await (readPlist ?? _plutil)(plist.path);
      if (text == null) return false;
      final old = jsonDecode(text);
      if (old is! Map || old['$_prefix$_accountsKey'] is! String) return false;

      // Everything the old app stored (accounts, settings, VIPs, …). This
      // replaces the defaults a first launch of the new build may have saved.
      for (final MapEntry(:key, :value) in old.entries) {
        if (key is! String || !key.startsWith(_prefix)) continue;
        final k = key.substring(_prefix.length);
        switch (value) {
          case String v:
            await p.setString(k, v);
          case bool v:
            await p.setBool(k, v);
          case int v:
            await p.setInt(k, v);
          case double v:
            await p.setDouble(k, v);
          case List v when v.every((e) => e is String):
            await p.setStringList(k, v.cast<String>());
        }
      }

      final src = Directory('${lib.path}/Application Support/$bundleId');
      if (src.existsSync()) {
        await _copyTree(src, Directory('$h/Library/Application Support/$bundleId'));
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Copies [from] into [to], never overwriting files that already exist.
  static Future<void> _copyTree(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final e in from.list(followLinks: false)) {
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final target = '${to.path}/$name';
      if (e is Directory) {
        await _copyTree(e, Directory(target));
      } else if (e is File && !File(target).existsSync()) {
        await e.copy(target);
      }
    }
  }
}

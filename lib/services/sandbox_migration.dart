import 'dart:io';

/// Runs `/usr/bin/defaults args` and returns the exit code. Injectable for tests.
typedef DefaultsRunner = Future<int> Function(List<String> args);

/// One-time move of app data from the old App Sandbox container to the normal
/// locations, after the sandbox was removed (needed to run CLI tools).
///
/// Must run before SharedPreferences opens. Never throws.
class SandboxMigration {
  static const bundleId = 'app.hearthmail.hearthmail';
  static const _accountsKey = 'flutter.accounts.v1';

  static Future<int> _defaults(List<String> args) async =>
      (await Process.run('/usr/bin/defaults', args)).exitCode;

  /// Returns true if data was migrated.
  static Future<bool> run({
    String? home,
    bool? sandboxed,
    DefaultsRunner? defaults,
  }) async {
    try {
      if (!Platform.isMacOS && home == null) return false;
      final isSandboxed = sandboxed ?? Platform.environment.containsKey('APP_SANDBOX_CONTAINER_ID');
      if (isSandboxed) return false;
      final h = home ?? Platform.environment['HOME'];
      if (h == null || h.isEmpty) return false;
      final run = defaults ?? _defaults;

      // Already has data in the normal place: nothing to do.
      if (await run(['read', bundleId, _accountsKey]) == 0) return false;

      final lib = Directory('$h/Library/Containers/$bundleId/Data/Library');
      if (!lib.existsSync()) return false;

      final src = Directory('${lib.path}/Application Support/$bundleId');
      if (src.existsSync()) {
        await _copyTree(src, Directory('$h/Library/Application Support/$bundleId'));
      }
      final plist = File('${lib.path}/Preferences/$bundleId.plist');
      if (plist.existsSync()) {
        await run(['import', bundleId, plist.path]);
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

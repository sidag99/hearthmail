import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hearthmail/services/sandbox_migration.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory home;
  const id = SandboxMigration.bundleId;

  setUp(() {
    home = Directory.systemTemp.createTempSync('hm_home');
    final lib = '${home.path}/Library/Containers/$id/Data/Library';
    File('$lib/Preferences/$id.plist').createSync(recursive: true);
    File('$lib/Application Support/$id/triage_a.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"x":1}');
  });
  tearDown(() => home.deleteSync(recursive: true));

  Future<String?> oldPrefs(String _) async => jsonEncode({
        'flutter.accounts.v1': '[{"id":"a"}]',
        'flutter.settings.v1': '{"fastModel":"gemma"}',
        'flutter.userdata.v1': '{"vips":["v@example.com"]}',
        'NSWindow Frame main': '0 0 100 100',
      });

  test('copies old sandbox data over a fresh first launch', () async {
    // The new build already saved default settings on its first launch.
    SharedPreferences.setMockInitialValues({'flutter.settings.v1': '{}'});
    final prefs = await SharedPreferences.getInstance();
    final moved = await SandboxMigration.run(home: home.path, sandboxed: false, readPlist: oldPrefs, prefs: prefs);
    expect(moved, isTrue);
    expect(prefs.getString('accounts.v1'), '[{"id":"a"}]');
    expect(prefs.getString('settings.v1'), '{"fastModel":"gemma"}');
    expect(prefs.getString('userdata.v1'), contains('v@example.com'));
    expect(prefs.containsKey('NSWindow Frame main'), isFalse);
    expect(File('${home.path}/Library/Application Support/$id/triage_a.json').existsSync(), isTrue);
  });

  test('leaves existing accounts alone', () async {
    SharedPreferences.setMockInitialValues({'flutter.accounts.v1': '[{"id":"new"}]'});
    final prefs = await SharedPreferences.getInstance();
    final moved = await SandboxMigration.run(home: home.path, sandboxed: false, readPlist: oldPrefs, prefs: prefs);
    expect(moved, isFalse);
    expect(prefs.getString('accounts.v1'), '[{"id":"new"}]');
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/triage.dart';

/// Remembers AI sorting results on disk so each email is sorted only once.
class TriageCache {
  TriageCache._(this._file, this._data);

  /// An in-memory cache (for tests and previews); nothing is written to disk.
  TriageCache.memory([Map<String, Triage> data = const {}]) : _file = null, _data = {...data};

  final File? _file;
  final Map<String, Triage> _data;

  static Future<TriageCache> open(String accountId) async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/triage_${accountId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.json');
    final data = <String, Triage>{};
    if (await file.exists()) {
      try {
        final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        raw.forEach((k, v) => data[k] = Triage.fromJson(v as Map<String, dynamic>));
      } catch (_) {
        // A corrupt cache only costs a re-sort.
      }
    }
    return TriageCache._(file, data);
  }

  Triage? operator [](String key) => _data[key];
  bool contains(String key) => _data.containsKey(key);

  Future<void> putAll(Map<String, Triage> entries) async {
    _data.addAll(entries);
    // Keep the file from growing forever.
    if (_data.length > 5000) {
      final keys = _data.keys.take(_data.length - 5000).toList();
      keys.forEach(_data.remove);
    }
    final file = _file;
    if (file == null) return;
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({for (final e in _data.entries) e.key: e.value.toJson()}));
  }

  Future<void> clear() async {
    _data.clear();
    final file = _file;
    if (file != null && await file.exists()) await file.delete();
  }
}

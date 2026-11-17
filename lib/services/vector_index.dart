import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/email_content.dart';

/// Where an indexed email lives on the server, so a search hit can be
/// fetched again.
class IndexedMail {
  const IndexedMail(this.key, this.path, this.uid, this.date);
  final String key;
  final String path;
  final int uid;
  final DateTime date;
}

/// A small on-disk vector index for one account: one embedding per email,
/// searched by exact cosine similarity.
///
/// No separate database is needed: 20,000 emails at 512 dimensions are 40 MB
/// and a full scan takes about 10 milliseconds, which beats approximate
/// indexes (HNSW etc.) on both accuracy and simplicity at this size.
class VectorIndex {
  VectorIndex._(this._file, this.model);

  /// In-memory only (tests).
  VectorIndex.memory(this.model) : _file = null;

  /// Vectors are cut to this many dimensions (embeddinggemma and
  /// qwen3-embedding are trained so the first dimensions carry most of the
  /// meaning), then normalized. In tool/model_bench.dart, 512 kept every
  /// right answer in the top 3 at 2/3 of the size of the full 768.
  static const int dims = 512;

  /// Per-account cap (about 40 MB); the oldest mail drops out first.
  static const int maxEntries = 20000;

  final File? _file;
  final String model;
  final _entries = <IndexedMail>[];
  final _vectors = <Float32List>[];
  final _pos = <String, int>{};

  int get length => _entries.length;
  bool contains(String key) => _pos.containsKey(key);

  /// Oldest indexed date per folder path, to know where to continue.
  DateTime? oldestIn(String path) {
    DateTime? oldest;
    for (final e in _entries) {
      if (e.path == path && (oldest == null || e.date.isBefore(oldest))) oldest = e.date;
    }
    return oldest;
  }

  int countIn(String path) => _entries.where((e) => e.path == path).length;

  static Float32List _prepare(List<double> v) {
    final n = min(dims, v.length);
    var norm = 0.0;
    for (var i = 0; i < n; i++) {
      norm += v[i] * v[i];
    }
    norm = sqrt(norm);
    final out = Float32List(n);
    if (norm == 0) return out;
    for (var i = 0; i < n; i++) {
      out[i] = v[i] / norm;
    }
    return out;
  }

  void add(IndexedMail mail, List<double> vector) {
    final vec = _prepare(vector);
    final at = _pos[mail.key];
    if (at != null) {
      _entries[at] = mail;
      _vectors[at] = vec;
    } else {
      _pos[mail.key] = _entries.length;
      _entries.add(mail);
      _vectors.add(vec);
    }
    _dirty = true;
  }

  void remove(String key) {
    final at = _pos.remove(key);
    if (at == null) return;
    final last = _entries.length - 1;
    if (at != last) {
      _entries[at] = _entries[last];
      _vectors[at] = _vectors[last];
      _pos[_entries[at].key] = at;
    }
    _entries.removeLast();
    _vectors.removeLast();
    _dirty = true;
  }

  /// Best matches for [query], most similar first.
  List<(IndexedMail, double)> search(List<double> query, {int limit = 30, double minScore = 0.3}) {
    final q = _prepare(query);
    final scored = <(int, double)>[];
    for (var i = 0; i < _vectors.length; i++) {
      final v = _vectors[i];
      final n = min(v.length, q.length);
      var s = 0.0;
      for (var j = 0; j < n; j++) {
        s += v[j] * q[j];
      }
      if (s >= minScore) scored.add((i, s));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final (i, s) in scored.take(limit)) (_entries[i], s)];
  }

  // ------------------------------------------------------------ storage

  bool _dirty = false;
  Timer? _saveTimer;

  /// Saves soon (coalescing bursts of adds into one write).
  void scheduleSave() {
    if (_file == null || !_dirty) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 3), save);
  }

  Future<void> save() async {
    final file = _file;
    if (file == null || !_dirty) return;
    _dirty = false;
    if (_entries.length > maxEntries) {
      final order = List.generate(_entries.length, (i) => i)
        ..sort((a, b) => _entries[a].date.compareTo(_entries[b].date));
      for (final i in order.take(_entries.length - maxEntries).map((i) => _entries[i].key).toList()) {
        remove(i);
      }
    }
    final b = BytesBuilder(copy: false);
    void u32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
    void str(String s) {
      final bytes = utf8.encode(s);
      u32(bytes.length);
      b.add(bytes);
    }

    b.add(ascii.encode('LMVI'));
    u32(1);
    str(model);
    u32(_entries.length);
    for (var i = 0; i < _entries.length; i++) {
      final e = _entries[i];
      str(e.key);
      str(e.path);
      u32(e.uid);
      b.add((ByteData(8)..setInt64(0, e.date.millisecondsSinceEpoch, Endian.little)).buffer.asUint8List());
      final v = _vectors[i];
      u32(v.length);
      b.add(Uint8List.fromList(v.buffer.asUint8List(v.offsetInBytes, v.lengthInBytes)));
    }
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(b.takeBytes(), flush: true);
    await tmp.rename(file.path);
  }

  static Future<VectorIndex> open(String accountId, String model) async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/vectors_${accountId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.bin');
    final index = VectorIndex._(file, model);
    if (!await file.exists()) return index;
    try {
      final data = ByteData.sublistView(await file.readAsBytes());
      var o = 0;
      int u32() {
        final v = data.getUint32(o, Endian.little);
        o += 4;
        return v;
      }

      String str() {
        final n = u32();
        final s = utf8.decode(data.buffer.asUint8List(data.offsetInBytes + o, n));
        o += n;
        return s;
      }

      if (ascii.decode(data.buffer.asUint8List(data.offsetInBytes, 4)) != 'LMVI') return index;
      o = 4;
      if (u32() != 1) return index;
      // A different model's vectors are not comparable; start over.
      if (str() != model) return index;
      final count = u32();
      for (var i = 0; i < count; i++) {
        final key = str();
        final path = str();
        final uid = u32();
        final date = DateTime.fromMillisecondsSinceEpoch(data.getInt64(o, Endian.little));
        o += 8;
        final n = u32();
        final v = Float32List(n);
        for (var j = 0; j < n; j++) {
          v[j] = data.getFloat32(o, Endian.little);
          o += 4;
        }
        index._pos[key] = index._entries.length;
        index._entries.add(IndexedMail(key, path, uid, date));
        index._vectors.add(v);
      }
    } catch (_) {
      // A damaged index only costs re-indexing.
      index._entries.clear();
      index._vectors.clear();
      index._pos.clear();
    }
    return index;
  }

  Future<void> delete() async {
    _saveTimer?.cancel();
    _entries.clear();
    _vectors.clear();
    _pos.clear();
    final f = _file;
    if (f != null && await f.exists()) await f.delete();
  }
}

/// How each embedding model wants queries and documents phrased. Using the
/// model's own task prefixes noticeably improves search quality.
class EmbeddingFormat {
  const EmbeddingFormat(this.model);
  final String model;

  String _family() {
    final m = model.toLowerCase();
    if (m.contains('embeddinggemma')) return 'gemma';
    if (m.contains('qwen3-embedding')) return 'qwen';
    if (m.contains('nomic')) return 'nomic';
    return '';
  }

  String query(String q) => switch (_family()) {
        'gemma' => 'task: search result | query: $q',
        'qwen' => 'Instruct: Given an email search query, retrieve the emails that answer it\nQuery: $q',
        'nomic' => 'search_query: $q',
        _ => q,
      };

  String document(EmailContent e) {
    var body = e.body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (body.length > 1500) body = body.substring(0, 1500);
    final from = e.from.replaceAll(RegExp(r'[<>"]'), ' ').trim();
    final date = e.date == null ? '' : ' | date: ${e.date!.toIso8601String().substring(0, 10)}';
    final text = 'from: $from$date | $body';
    return switch (_family()) {
      'gemma' => 'title: ${e.subject} | text: $text',
      'nomic' => 'search_document: ${e.subject} | $text',
      _ => 'Subject: ${e.subject}\n$text',
    };
  }
}

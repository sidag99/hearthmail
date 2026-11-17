import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:enough_mail/enough_mail.dart';
import 'package:path_provider/path_provider.dart';

/// What [MessageCache.load] found on disk.
class CachedInbox {
  const CachedInbox({required this.messages, this.uidValidity, this.path});

  /// Newest first, as they were saved.
  final List<MimeMessage> messages;

  /// The folder's UIDVALIDITY when saved. If the server reports another
  /// value now, the cached UIDs are meaningless and must be dropped.
  final int? uidValidity;

  /// The inbox's real path on the server (it is not always "INBOX").
  final String? path;

  static const empty = CachedInbox(messages: []);
}

/// Keeps one account's newest inbox messages on disk so the app can show
/// mail instantly at launch and offline.
///
/// Each message is stored as raw RFC 822 text with its UID and flags.
/// Messages whose body is too large (or was never downloaded) are stored
/// as headers only, marked with [stubHeader]; opening one fetches the body.
class MessageCache {
  MessageCache._(this._file, {this.maxMessages = 500, this.maxBodyBytes = 1024 * 1024});

  /// Opens (without reading) the cache of [accountId]. [dir] overrides the
  /// app support directory, for tests.
  static Future<MessageCache> open(
    String accountId, {
    Directory? dir,
    int maxMessages = 500,
    int maxBodyBytes = 1024 * 1024,
  }) async {
    final base = dir ?? await getApplicationSupportDirectory();
    final safe = accountId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return MessageCache._(File('${base.path}/inbox_cache_$safe.json'),
        maxMessages: maxMessages, maxBodyBytes: maxBodyBytes);
  }

  final File _file;
  final int maxMessages;

  /// Messages whose raw text is longer than this keep only their headers.
  final int maxBodyBytes;

  /// Marks a message restored without its body.
  static const stubHeader = 'X-Hearthmail-Stub';

  /// True for a cached message that has headers only.
  static bool isStub(MimeMessage m) => m.getHeaderValue(stubHeader) != null;

  // Raw text of messages already rendered, so a flag change does not mean
  // re-rendering 500 messages. Keyed by UID, valid while the same object.
  final _rendered = <int, (MimeMessage, String, bool)>{};

  Future<void> _tail = Future.value();

  /// Reads the cache. Never throws: a missing or damaged file is an empty cache.
  Future<CachedInbox> load() async {
    try {
      if (!await _file.exists()) return CachedInbox.empty;
      final text = await _file.readAsString();
      final data = await Isolate.run(() => jsonDecode(text) as Map<String, dynamic>);
      if (data['v'] != 1) return CachedInbox.empty;
      final out = <MimeMessage>[];
      for (final e in (data['messages'] as List)) {
        try {
          final m = MimeMessage.parseFromText(e['raw'] as String)
            ..uid = e['uid'] as int
            ..flags = [for (final f in (e['flags'] as List)) f as String];
          if (e['size'] != null) m.size = e['size'] as int;
          out.add(m);
        } catch (_) {
          // Skip one unreadable entry, keep the rest.
        }
        // Stay responsive while parsing hundreds of messages.
        if (out.length % 25 == 0) await Future<void>.delayed(Duration.zero);
      }
      return CachedInbox(
        messages: out,
        uidValidity: data['uidValidity'] as int?,
        path: data['path'] as String?,
      );
    } catch (_) {
      return CachedInbox.empty;
    }
  }

  /// Replaces the cache with the newest [maxMessages] of [messages].
  /// Writes are queued, so concurrent calls cannot interleave.
  Future<void> save(List<MimeMessage> messages, {int? uidValidity, String? path}) {
    final entries = encode(messages);
    final result = _tail.then((_) => _write(entries, uidValidity, path));
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// The entries [save] would write (exposed for tests).
  List<Map<String, Object?>> encode(List<MimeMessage> messages) {
    final withUid = messages.where((m) => m.uid != null).toList()
      ..sort((a, b) => (_date(b)).compareTo(_date(a)));
    final keep = withUid.take(maxMessages).toList();
    final fresh = <int, (MimeMessage, String, bool)>{};
    final entries = <Map<String, Object?>>[];
    for (final m in keep) {
      final uid = m.uid!;
      var hit = _rendered[uid];
      if (hit == null || !identical(hit.$1, m)) {
        final (raw, full) = _render(m);
        hit = (m, raw, full);
      }
      fresh[uid] = hit;
      entries.add({
        'uid': uid,
        'flags': m.flags ?? const <String>[],
        'full': hit.$3,
        if (m.size != null) 'size': m.size,
        'raw': hit.$2,
      });
    }
    _rendered
      ..clear()
      ..addAll(fresh);
    return entries;
  }

  (String, bool) _render(MimeMessage m) {
    if (_hasBody(m) && !isStub(m)) {
      try {
        final raw = m.renderMessage();
        if (raw.length <= maxBodyBytes) return (raw, true);
      } catch (_) {
        // Fall through to headers only.
      }
    }
    return (_headersOnly(m), false);
  }

  static bool _hasBody(MimeMessage m) =>
      m.decodeTextPlainPart() != null || m.decodeTextHtmlPart() != null;

  static String _headersOnly(MimeMessage m) {
    final b = StringBuffer();
    final seen = <String>{};
    for (final h in m.headers ?? const <Header>[]) {
      final n = h.lowerCaseName;
      if (n == 'content-type' || n == 'content-transfer-encoding' || n == stubHeader.toLowerCase()) continue;
      seen.add(n);
      h.render(b);
    }
    // Envelope-only messages carry no From/To/Date headers; rebuild them.
    final env = m.envelope;
    void add(String name, String? value) {
      if (value != null && value.isNotEmpty && !seen.contains(name.toLowerCase())) {
        Header(name, value).render(b);
      }
    }

    String? addrs(List<MailAddress>? l) => (l == null || l.isEmpty) ? null : l.map((a) => a.encode()).join(', ');
    add('From', addrs(m.from ?? env?.from));
    add('To', addrs(m.to ?? env?.to));
    add('Cc', addrs(m.cc ?? env?.cc));
    add('Subject', env?.subject);
    final d = m.decodeDate();
    add('Date', d == null ? null : DateCodec.encodeDate(d));
    add('Message-ID', env?.messageId);
    add('In-Reply-To', env?.inReplyTo);
    b
      ..write('$stubHeader: 1\r\n')
      ..write('\r\n');
    return b.toString();
  }

  static DateTime _date(MimeMessage m) {
    try {
      return m.decodeDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  Future<void> _write(List<Map<String, Object?>> entries, int? uidValidity, String? path) async {
    final json = await Isolate.run(() => jsonEncode({
          'v': 1,
          'uidValidity': uidValidity,
          'path': path,
          'messages': entries,
        }));
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename(_file.path);
  }

  /// Deletes the cache from disk.
  Future<void> clear() async {
    _rendered.clear();
    final done = _tail.then((_) async {
      for (final f in [_file, File('${_file.path}.tmp')]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    });
    _tail = done;
    await done;
  }
}

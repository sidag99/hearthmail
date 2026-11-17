import 'package:enough_mail/enough_mail.dart';

import 'mail_service.dart';

/// Groups messages into conversations.
///
/// Every message names itself (Message-ID) and its ancestors (References,
/// In-Reply-To). Two messages are in the same conversation when those names
/// connect them, directly or through other messages. This also handles
/// clients that omit References (a reply whose In-Reply-To points at a
/// message that itself sits deep inside a thread).
class ThreadIndex {
  ThreadIndex(Iterable<MimeMessage> messages) {
    for (final m in messages) {
      final ids = idsOf(m);
      for (var i = 1; i < ids.length; i++) {
        _union(ids[0], ids[i]);
      }
    }
  }

  final _parent = <String, String>{};

  String _find(String id) {
    var root = id;
    while (true) {
      final p = _parent[root];
      if (p == null || p == root) break;
      root = p;
    }
    // Path compression.
    var cur = id;
    while (cur != root) {
      final next = _parent[cur] ?? root;
      _parent[cur] = root;
      cur = next;
    }
    return root;
  }

  void _union(String a, String b) {
    final ra = _find(a);
    final rb = _find(b);
    if (ra != rb) _parent[rb] = ra;
  }

  /// A key shared by all messages of one conversation.
  String keyOf(MimeMessage m) {
    final ids = idsOf(m);
    if (ids.isEmpty) return 'subject:${MailService.normalizedSubject(MailService.subjectOf(m))}';
    return _find(ids.first);
  }

  static final _idPattern = RegExp(r'<[^<>\s]+>');

  /// The message's own ID first, then the IDs it refers to.
  static List<String> idsOf(MimeMessage m) {
    final refs = m.getHeaderValue('references') ?? '';
    final irt = m.getHeaderValue('in-reply-to') ?? m.envelope?.inReplyTo ?? '';
    final out = <String>[];
    void add(String? s) {
      if (s != null && s.isNotEmpty && !out.contains(s)) out.add(s);
    }

    add(messageIdOf(m));
    for (final r in _idPattern.allMatches(refs)) {
      add(r.group(0));
    }
    for (final r in _idPattern.allMatches(irt)) {
      add(r.group(0));
    }
    return out;
  }

  /// The Message-ID of [m], or null.
  static String? messageIdOf(MimeMessage m) {
    final own = (m.getHeaderValue('message-id') ?? m.envelope?.messageId ?? '').trim();
    if (own.isEmpty) return null;
    return _idPattern.firstMatch(own)?.group(0) ?? own;
  }
}

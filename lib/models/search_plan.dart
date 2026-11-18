/// A structured search the AI extracts from a natural-language question,
/// e.g. "invoices from Acme last month" -> from: acme, keywords: [invoice], since/before.
class SearchPlan {
  const SearchPlan({
    this.keywords = const [],
    this.from,
    this.to,
    this.subject,
    this.since,
    this.before,
    this.unreadOnly = false,
    this.flaggedOnly = false,
    this.hasAttachment = false,
    this.matchAll = false,
  });

  /// Every keyword must match (typed searches), rather than any of them
  /// (AI searches, where keywords are alternative wordings).
  final bool matchAll;

  /// Parses a typed search the way Mail and Gmail do: words must all match,
  /// "quoted phrases" stay together, and from:, to:, subject:,
  /// has:attachment, is:unread, is:flagged/starred, after: and before:
  /// (YYYY-MM-DD) narrow it down.
  factory SearchPlan.parse(String query) {
    final tokens = RegExp(r'(\w+):"([^"]*)"|(\w+):(\S+)|"([^"]+)"|(\S+)').allMatches(query);
    final words = <String>[];
    String? from, to, subject;
    DateTime? since, before;
    var unread = false, flagged = false, attach = false;
    for (final t in tokens) {
      final key = (t[1] ?? t[3])?.toLowerCase();
      final value = t[2] ?? t[4];
      if (key != null && value != null) {
        switch (key) {
          case 'from':
            from = value;
          case 'to':
            to = value;
          case 'subject':
            subject = value;
          case 'has' when value.toLowerCase().startsWith('attach'):
            attach = true;
          case 'is' when value.toLowerCase() == 'unread':
            unread = true;
          case 'is' when value.toLowerCase() == 'flagged' || value.toLowerCase() == 'starred':
            flagged = true;
          case 'after' || 'since':
            since = DateTime.tryParse(value.replaceAll('/', '-'));
          case 'before':
            before = DateTime.tryParse(value.replaceAll('/', '-'));
          default:
            words.add('$key:$value'); // not an operator, e.g. a time "10:30"
        }
      } else if (t[5] != null) {
        words.add(t[5]!);
      } else if (t[6] != null) {
        words.add(t[6]!);
      }
    }
    return SearchPlan(
      keywords: words,
      from: from,
      to: to,
      subject: subject,
      since: since,
      before: before,
      unreadOnly: unread,
      flaggedOnly: flagged,
      hasAttachment: attach,
      matchAll: true,
    );
  }

  final List<String> keywords;
  final String? from;
  final String? to;
  final String? subject;
  final DateTime? since;
  final DateTime? before;
  final bool unreadOnly;
  final bool flaggedOnly;
  final bool hasAttachment;

  factory SearchPlan.fromJson(Map<String, dynamic> j) {
    String? str(String k) {
      final v = j[k];
      if (v is! String) return null;
      final t = v.trim();
      return t.isEmpty || t.toLowerCase() == 'null' ? null : t;
    }

    DateTime? date(String k) {
      final s = str(k);
      return s == null ? null : DateTime.tryParse(s);
    }

    return SearchPlan(
      keywords: [
        for (final k in (j['keywords'] as List? ?? const []))
          if (k is String && k.trim().isNotEmpty) k.trim()
      ],
      from: str('from'),
      to: str('to'),
      subject: str('subject'),
      since: date('since'),
      before: date('before'),
      unreadOnly: j['unread_only'] == true,
      flaggedOnly: j['flagged_only'] == true,
      hasAttachment: j['has_attachment'] == true,
    );
  }

  SearchPlan withoutKeywords() => SearchPlan(
        subject: subject,
        from: from,
        to: to,
        since: since,
        before: before,
        unreadOnly: unreadOnly,
        flaggedOnly: flaggedOnly,
        hasAttachment: hasAttachment,
      );

  bool get isEmpty =>
      keywords.isEmpty &&
      from == null &&
      to == null &&
      subject == null &&
      since == null &&
      before == null &&
      !unreadOnly &&
      !flaggedOnly &&
      !hasAttachment;

  /// Human-readable description shown above results.
  String describe() {
    final parts = <String>[
      if (keywords.isNotEmpty) 'about ${keywords.map((k) => '"$k"').join(matchAll ? ' and ' : ' or ')}',
      if (from != null) 'from $from',
      if (to != null) 'to $to',
      if (subject != null) 'subject "$subject"',
      if (since != null) 'after ${_ymd(since!)}',
      if (before != null) 'before ${_ymd(before!)}',
      if (unreadOnly) 'unread',
      if (flaggedOnly) 'flagged',
      if (hasAttachment) 'with attachments',
    ];
    return parts.isEmpty ? 'recent mail' : parts.join(', ');
  }

  /// Standard IMAP SEARCH criteria (RFC 3501). Works with any IMAP server.
  String toImapCriteria() {
    final c = <String>[];
    if (from != null) c.add('FROM ${_q(from!)}');
    if (to != null) c.add('TO ${_q(to!)}');
    if (subject != null) c.add('SUBJECT ${_q(subject!)}');
    if (since != null) c.add('SINCE ${_imapDate(since!)}');
    if (before != null) c.add('BEFORE ${_imapDate(before!)}');
    if (unreadOnly) c.add('UNSEEN');
    if (flaggedOnly) c.add('FLAGGED');
    if (keywords.isNotEmpty && matchAll) {
      // All words must match: IMAP criteria are ANDed by default.
      c.addAll([for (final k in keywords) 'TEXT ${_q(k)}']);
    } else if (keywords.isNotEmpty) {
      // Any keyword may match: OR them together (IMAP OR is binary).
      var expr = 'TEXT ${_q(keywords.last)}';
      for (final k in keywords.reversed.skip(1)) {
        expr = 'OR TEXT ${_q(k)} $expr';
      }
      c.add(keywords.length > 1 ? '($expr)' : expr);
    }
    return c.isEmpty ? 'ALL' : c.join(' ');
  }

  /// Gmail's own search syntax, used via the X-GM-RAW IMAP extension,
  /// which is smarter than plain IMAP search on Gmail accounts.
  String toGmailQuery() {
    final c = <String>[];
    if (from != null) c.add('from:${_g(from!)}');
    if (to != null) c.add('to:${_g(to!)}');
    if (subject != null) c.add('subject:${_g(subject!)}');
    if (since != null) c.add('after:${_ymd(since!, sep: '/')}');
    if (before != null) c.add('before:${_ymd(before!, sep: '/')}');
    if (unreadOnly) c.add('is:unread');
    if (flaggedOnly) c.add('is:starred');
    if (hasAttachment) c.add('has:attachment');
    if (keywords.isNotEmpty) {
      c.add(matchAll ? keywords.map(_g).join(' ') : '(${keywords.map(_g).join(' OR ')})');
    }
    return c.join(' ');
  }

  static String _q(String s) =>
      '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  static String _g(String s) =>
      s.contains(' ') ? '"${s.replaceAll('"', '')}"' : s;

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  static String _imapDate(DateTime d) =>
      '${d.day}-${_months[d.month - 1]}-${d.year}';
  static String _ymd(DateTime d, {String sep = '-'}) =>
      '${d.year}$sep${d.month.toString().padLeft(2, '0')}$sep${d.day.toString().padLeft(2, '0')}';
}

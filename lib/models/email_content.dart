/// The plain facts about one email that the AI needs. Kept independent of the
/// mail library so the AI layer can be reused (and tested) on its own.
class EmailContent {
  const EmailContent({
    required this.id,
    required this.from,
    required this.subject,
    required this.body,
    this.to = '',
    this.date,
    this.isUnread = false,
  });

  /// Stable key for this message (used to cache AI results).
  final String id;
  final String from;
  final String to;
  final String subject;
  final DateTime? date;
  final String body;
  final bool isUnread;

  String get snippet {
    final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 280 ? flat : '${flat.substring(0, 280)}…';
  }

  /// Full text for prompts, trimmed so a single huge email can't blow the
  /// model's context window.
  String forPrompt({int maxBodyChars = 12000}) {
    var b = body.trim();
    if (b.length > maxBodyChars) {
      b = '${b.substring(0, maxBodyChars)}\n[…email truncated…]';
    }
    return [
      'From: $from',
      if (to.isNotEmpty) 'To: $to',
      if (date != null) 'Date: ${date!.toLocal()}',
      'Subject: $subject',
      '',
      b,
    ].join('\n');
  }
}

/// AI-assigned sorting info for one email.
enum MailCategory {
  personal('Personal', 'messages from real people about personal life'),
  work('Work', 'job, colleagues, clients, projects, meetings'),
  finance('Finance', 'bills, banks, receipts, invoices, taxes, payments'),
  shopping('Shopping', 'orders, shipping and delivery updates'),
  travel('Travel', 'flights, hotels, bookings, itineraries'),
  newsletter('Newsletters', 'subscribed content, digests, blogs'),
  promotion('Promotions', 'marketing, sales, deals, ads'),
  social('Social', 'social networks and community notifications'),
  notification('Updates', 'automated alerts, security codes, account notices'),
  other('Other', 'anything else');

  const MailCategory(this.label, this.description);
  final String label;
  final String description;

  static MailCategory parse(String? s) => MailCategory.values.firstWhere(
        (c) => c.name == s,
        orElse: () => MailCategory.other,
      );
}

enum MailPriority {
  high,
  normal,
  low;

  static MailPriority parse(String? s) => MailPriority.values.firstWhere(
        (p) => p.name == s,
        orElse: () => MailPriority.normal,
      );
}

class Triage {
  const Triage({
    required this.category,
    required this.priority,
    required this.needsReply,
    this.suspicious = false,
  });

  final MailCategory category;
  final MailPriority priority;
  final bool needsReply;

  /// Looks like phishing or a scam.
  final bool suspicious;

  Map<String, dynamic> toJson() => {
        'category': category.name,
        'priority': priority.name,
        'needs_reply': needsReply,
        if (suspicious) 'suspicious': true,
      };

  factory Triage.fromJson(Map<String, dynamic> j) => Triage(
        category: MailCategory.parse(j['category'] as String?),
        priority: MailPriority.parse(j['priority'] as String?),
        needsReply: j['needs_reply'] == true,
        suspicious: j['suspicious'] == true,
      );
}

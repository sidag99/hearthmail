/// How much an email in "Catch me up" matters.
enum BriefGroup {
  attention,
  fyi,
  skip;

  static BriefGroup parse(String? s) =>
      BriefGroup.values.firstWhere((g) => g.name == s, orElse: () => BriefGroup.fyi);
}

/// What the user most likely needs to do about an email.
enum BriefAction {
  reply,
  pay,
  schedule,
  review,
  none;

  static BriefAction parse(String? s) =>
      BriefAction.values.firstWhere((a) => a.name == s, orElse: () => BriefAction.none);
}

/// One email in the "Catch me up" briefing: a one-line takeaway plus the
/// action it calls for.
class BriefItem {
  const BriefItem({required this.group, required this.takeaway, this.action = BriefAction.none, this.due = ''});

  final BriefGroup group;
  final String takeaway;
  final BriefAction action;

  /// A deadline in the email's own words ("Friday", "by 5 Dec"), or ''.
  final String due;

  factory BriefItem.fromJson(Map<String, dynamic> j) => BriefItem(
        group: BriefGroup.parse(j['group'] as String?),
        takeaway: (j['takeaway'] as String? ?? '').trim(),
        action: BriefAction.parse(j['action'] as String?),
        due: (j['due'] as String? ?? '').trim(),
      );
}

import '../models/triage.dart';

/// Decides whether a newly arrived inbox message deserves a notification.
///
/// Pure on purpose: the caller looks up the facts (muted, blocked, AI
/// category) and this only combines them.
bool shouldNotify({
  required bool enabled,
  required bool isSeen,
  required bool isMuted,
  required bool isBlocked,
  MailCategory? category,
  DateTime? received,
  DateTime? now,
  Duration maxAge = const Duration(days: 1),
}) {
  if (!enabled || isSeen || isMuted || isBlocked) return false;
  if (category == MailCategory.promotion || category == MailCategory.newsletter) return false;
  // Old mail that only just got downloaded (first sync, evicted cache)
  // is not "new mail".
  if (received != null && (now ?? DateTime.now()).difference(received) > maxAge) return false;
  return true;
}

/// Payload that travels with a notification so a click can find the message.
String notificationPayload(String accountId, int uid) => '$uid|$accountId';

/// Reverses [notificationPayload]; null if [payload] is not one of ours.
({String accountId, int uid})? parseNotificationPayload(String? payload) {
  if (payload == null) return null;
  final bar = payload.indexOf('|');
  if (bar <= 0 || bar == payload.length - 1) return null;
  final uid = int.tryParse(payload.substring(0, bar));
  if (uid == null) return null;
  return (accountId: payload.substring(bar + 1), uid: uid);
}

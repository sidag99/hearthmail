import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A message the user asked to be reminded about later ("Remind me" /
/// snooze). It disappears from the inbox until [until].
class Snooze {
  const Snooze({
    required this.key,
    required this.accountId,
    required this.until,
    this.subject = '',
    this.path = '',
    this.uid = 0,
  });
  final String key;
  final String accountId;
  final DateTime until;
  final String subject;

  /// Where the message is, to bring it back even if it is no longer loaded.
  final String path;
  final int uid;

  bool get isDue => !DateTime.now().isBefore(until);

  Map<String, dynamic> toJson() =>
      {'key': key, 'account': accountId, 'until': until.toIso8601String(), 'subject': subject, 'path': path, 'uid': uid};
  factory Snooze.fromJson(Map<String, dynamic> j) => Snooze(
        key: j['key'] as String,
        accountId: j['account'] as String? ?? '',
        until: DateTime.parse(j['until'] as String),
        subject: j['subject'] as String? ?? '',
        path: j['path'] as String? ?? '',
        uid: j['uid'] as int? ?? 0,
      );
}

/// A sent message to follow up on if nobody replies by [due].
class FollowUp {
  const FollowUp({required this.messageId, required this.accountId, required this.subject, required this.to, required this.due});
  final String messageId;
  final String accountId;
  final String subject;
  final String to;
  final DateTime due;

  Map<String, dynamic> toJson() =>
      {'id': messageId, 'account': accountId, 'subject': subject, 'to': to, 'due': due.toIso8601String()};
  factory FollowUp.fromJson(Map<String, dynamic> j) => FollowUp(
        messageId: j['id'] as String,
        accountId: j['account'] as String? ?? '',
        subject: j['subject'] as String? ?? '',
        to: j['to'] as String? ?? '',
        due: DateTime.parse(j['due'] as String),
      );
}

/// A message waiting to be sent later ("Send later").
class ScheduledMail {
  const ScheduledMail({
    required this.id,
    required this.accountId,
    required this.sendAt,
    required this.to,
    required this.cc,
    required this.bcc,
    required this.subject,
    required this.body,
    this.inReplyToId,
    this.references,
    this.attachmentPaths = const [],
  });

  final String id;
  final String accountId;
  final DateTime sendAt;
  final String to, cc, bcc, subject, body;
  final String? inReplyToId;
  final String? references;
  final List<String> attachmentPaths;

  Map<String, dynamic> toJson() => {
        'id': id,
        'account': accountId,
        'sendAt': sendAt.toIso8601String(),
        'to': to,
        'cc': cc,
        'bcc': bcc,
        'subject': subject,
        'body': body,
        'inReplyTo': inReplyToId,
        'references': references,
        'files': attachmentPaths,
      };

  factory ScheduledMail.fromJson(Map<String, dynamic> j) => ScheduledMail(
        id: j['id'] as String,
        accountId: j['account'] as String,
        sendAt: DateTime.parse(j['sendAt'] as String),
        to: j['to'] as String? ?? '',
        cc: j['cc'] as String? ?? '',
        bcc: j['bcc'] as String? ?? '',
        subject: j['subject'] as String? ?? '',
        body: j['body'] as String? ?? '',
        inReplyToId: j['inReplyTo'] as String?,
        references: j['references'] as String?,
        attachmentPaths: [for (final f in (j['files'] as List? ?? const [])) f as String],
      );
}

class Template {
  const Template(this.name, this.body);
  final String name;
  final String body;
  Map<String, dynamic> toJson() => {'name': name, 'body': body};
  factory Template.fromJson(Map<String, dynamic> j) => Template(j['name'] as String? ?? '', j['body'] as String? ?? '');
}

/// The user's personal mail organization, kept on this device: VIPs,
/// blocked senders, muted threads, reminders, scheduled mail, templates,
/// signatures and contacts.
class UserData {
  UserData._(this._prefs);

  /// In-memory only (tests and previews).
  UserData.memory() : _prefs = null;

  static Future<UserData> open() async {
    final prefs = await SharedPreferences.getInstance();
    final d = UserData._(prefs);
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        d._load(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {}
    }
    return d;
  }

  static const _key = 'userdata.v1';
  final SharedPreferences? _prefs;

  final vips = <String>{};
  final blocked = <String>{};
  final mutedThreads = <String>{};
  final snoozes = <String, Snooze>{};
  final followUps = <FollowUp>[];
  final scheduled = <ScheduledMail>[];
  final templates = <Template>[];
  final signatures = <String, String>{};

  /// email (lowercase) → (display name, times seen), for autocomplete.
  final contacts = <String, (String, int)>{};

  void _load(Map<String, dynamic> j) {
    vips.addAll([for (final v in j['vips'] as List? ?? const []) v as String]);
    blocked.addAll([for (final v in j['blocked'] as List? ?? const []) v as String]);
    mutedThreads.addAll([for (final v in j['muted'] as List? ?? const []) v as String]);
    for (final s in j['snoozes'] as List? ?? const []) {
      final z = Snooze.fromJson(s as Map<String, dynamic>);
      snoozes[z.key] = z;
    }
    followUps.addAll([for (final f in j['followUps'] as List? ?? const []) FollowUp.fromJson(f as Map<String, dynamic>)]);
    scheduled.addAll([for (final f in j['scheduled'] as List? ?? const []) ScheduledMail.fromJson(f as Map<String, dynamic>)]);
    templates.addAll([for (final t in j['templates'] as List? ?? const []) Template.fromJson(t as Map<String, dynamic>)]);
    (j['signatures'] as Map? ?? const {}).forEach((k, v) => signatures[k as String] = v as String);
    (j['contacts'] as Map? ?? const {}).forEach((k, v) {
      final l = v as List;
      contacts[k as String] = (l[0] as String, l[1] as int);
    });
  }

  Map<String, dynamic> toJson() => {
        'vips': vips.toList(),
        'blocked': blocked.toList(),
        'muted': mutedThreads.toList(),
        'snoozes': [for (final s in snoozes.values) s.toJson()],
        'followUps': [for (final f in followUps) f.toJson()],
        'scheduled': [for (final s in scheduled) s.toJson()],
        'templates': [for (final t in templates) t.toJson()],
        'signatures': signatures,
        'contacts': {for (final e in contacts.entries) e.key: [e.value.$1, e.value.$2]},
      };

  Future<void> save() async {
    // Keep the contact list bounded: drop the least-used.
    if (contacts.length > 3000) {
      final order = contacts.entries.toList()..sort((a, b) => a.value.$2.compareTo(b.value.$2));
      for (final e in order.take(contacts.length - 3000)) {
        contacts.remove(e.key);
      }
    }
    await _prefs?.setString(_key, jsonEncode(toJson()));
  }

  bool isVip(String email) => vips.contains(email.toLowerCase());

  /// Blocked by exact address or by "@domain".
  bool isBlocked(String email) {
    final e = email.toLowerCase();
    final at = e.indexOf('@');
    return blocked.contains(e) || (at >= 0 && blocked.contains(e.substring(at)));
  }

  /// Records an address for autocomplete. Returns true if anything changed.
  bool noteContact(String email, String? name, {int weight = 1}) {
    final e = email.trim().toLowerCase();
    if (e.isEmpty || !e.contains('@') || e.contains('noreply') || e.contains('no-reply') || e.contains('donotreply')) {
      return false;
    }
    final old = contacts[e];
    final n = (name?.trim().isNotEmpty ?? false) ? name!.trim() : (old?.$1 ?? '');
    contacts[e] = (n, (old?.$2 ?? 0) + weight);
    return true;
  }

  /// Best autocomplete matches for [prefix], most used first.
  List<(String email, String name)> suggestContacts(String prefix, {int limit = 6}) {
    final p = prefix.trim().toLowerCase();
    if (p.isEmpty) return const [];
    final hits = contacts.entries
        .where((e) => e.key.startsWith(p) || e.value.$1.toLowerCase().split(RegExp(r'\s+')).any((w) => w.startsWith(p)) || e.value.$1.toLowerCase().startsWith(p))
        .toList()
      ..sort((a, b) => b.value.$2.compareTo(a.value.$2));
    return [for (final e in hits.take(limit)) (e.key, e.value.$1)];
  }
}

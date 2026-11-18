import 'dart:convert';

import 'package:enough_mail/enough_mail.dart';

/// My answer to a meeting invitation (iTIP PARTSTAT).
enum PartStat {
  needsAction('NEEDS-ACTION', ''),
  accepted('ACCEPTED', 'Accepted'),
  tentative('TENTATIVE', 'Tentative'),
  declined('DECLINED', 'Declined');

  const PartStat(this.ical, this.subjectPrefix);
  final String ical;
  final String subjectPrefix;

  static PartStat parse(String? v) {
    switch ((v ?? '').toUpperCase()) {
      case 'ACCEPTED':
        return accepted;
      case 'TENTATIVE':
        return tentative;
      case 'DECLINED':
        return declined;
      default:
        return needsAction;
    }
  }

  String get verb => switch (this) {
        accepted => 'accepted',
        tentative => 'tentatively accepted',
        declined => 'declined',
        needsAction => 'not yet answered',
      };
}

class InviteAttendee {
  const InviteAttendee({required this.email, this.name = '', this.partStat = PartStat.needsAction, this.role = '', this.rsvp = false});
  final String email;
  final String name;
  final PartStat partStat;
  final String role;
  final bool rsvp;

  String get display => name.isNotEmpty ? name : email;
}

/// A meeting invitation (one VEVENT of an iCalendar attachment).
class Invite {
  const Invite({
    required this.method,
    required this.uid,
    this.sequence = 0,
    required this.summary,
    this.description = '',
    this.location = '',
    required this.start,
    this.end,
    this.allDay = false,
    this.startTzid,
    this.timeZoneKnown = true,
    this.organizerName = '',
    this.organizerEmail = '',
    this.attendees = const [],
    this.me,
    this.recurrenceId,
    this.rrule,
    required this.rawIcs,
  });

  /// REQUEST, CANCEL, PUBLISH, …
  final String method;
  final String uid;
  final int sequence;
  final String summary, description, location;

  /// A UTC instant when the time zone is known (or the invite used UTC);
  /// otherwise a "floating" local time. All-day events are local midnight.
  final DateTime start;

  /// End of the event. For all-day events this is exclusive (the day after
  /// the last day), as in iCalendar.
  final DateTime? end;
  final bool allDay;

  /// The TZID the invite used, if any.
  final String? startTzid;

  /// False if [startTzid] could not be resolved, so [start] is read as the
  /// computer's local time instead.
  final bool timeZoneKnown;
  final String organizerName, organizerEmail;
  final List<InviteAttendee> attendees;

  /// The attendee line that is me, if the invite lists one.
  final InviteAttendee? me;

  /// Set when the invite is for one occurrence of a recurring series.
  final String? recurrenceId;
  final String? rrule;
  final String rawIcs;

  bool get isRequest => method == 'REQUEST';
  bool get isCancel => method == 'CANCEL';
  bool get isRecurring => rrule != null && rrule!.isNotEmpty;

  /// Identifies this version of this event (for remembering my answer).
  String get key => '$uid#${recurrenceId ?? ''}#$sequence';

  /// The organizer's mailbox, for the reply.
  MailAddress? get organizer =>
      organizerEmail.isEmpty ? null : MailAddress(organizerName.isEmpty ? null : organizerName, organizerEmail);

  /// Last day of an all-day event (inclusive), or the end instant otherwise.
  DateTime? get displayEnd {
    final e = end;
    if (e == null) return null;
    return allDay ? e.subtract(const Duration(days: 1)) : e;
  }

  /// Copy with [me] resolved from the addresses that belong to the user.
  Invite withMe(Iterable<String> myEmails) {
    final mine = {for (final e in myEmails) e.toLowerCase()};
    InviteAttendee? found;
    for (final a in attendees) {
      if (mine.contains(a.email.toLowerCase())) {
        found = a;
        break;
      }
    }
    return Invite(
      method: method,
      uid: uid,
      sequence: sequence,
      summary: summary,
      description: description,
      location: location,
      start: start,
      end: end,
      allDay: allDay,
      startTzid: startTzid,
      timeZoneKnown: timeZoneKnown,
      organizerName: organizerName,
      organizerEmail: organizerEmail,
      attendees: attendees,
      me: found,
      recurrenceId: recurrenceId,
      rrule: rrule,
      rawIcs: rawIcs,
    );
  }

  // ------------------------------------------------------------- finding

  /// The invitation in [m], if it carries one (a text/calendar part or an
  /// .ics attachment). Returns null when the body has not been downloaded.
  static Invite? findIn(MimeMessage m, {Iterable<String> myEmails = const []}) {
    for (final text in calendarTexts(m)) {
      final invite = parse(text, myEmails: myEmails);
      if (invite != null) return invite;
    }
    return null;
  }

  /// The text of every iCalendar part of [m].
  static List<String> calendarTexts(MimeMessage m) {
    final out = <String>[];
    for (final part in m.allPartsFlat) {
      final type = part.getHeaderContentType();
      final sub = type?.mediaType.sub.name ?? '';
      final mt = type?.mediaType.text.toLowerCase() ?? '';
      final name = (type?.parameters['name'] ?? part.getHeaderContentDisposition()?.filename ?? '').toLowerCase();
      final isCal = mt == 'text/calendar' || mt == 'application/ics' || mt == 'text/x-vcalendar' || sub == 'textCalendar' || name.endsWith('.ics');
      if (!isCal) continue;
      final String? text;
      try {
        text = part.decodeContentText() ?? _utf8OrNull(part.decodeContentBinary());
      } catch (_) {
        continue;
      }
      if (text != null && text.contains('BEGIN:VCALENDAR')) out.add(text);
    }
    return out;
  }

  static String? _utf8OrNull(List<int>? bytes) => bytes == null ? null : utf8.decode(bytes, allowMalformed: true);

  // ------------------------------------------------------------- parsing

  /// Parses the first event of an iCalendar document; null if there is none.
  static Invite? parse(String ics, {Iterable<String> myEmails = const []}) {
    final lines = _contentLines(ics);
    String method = '';
    final zones = <String, List<_ZoneRule>>{};
    List<_Prop>? event;
    final events = <List<_Prop>>[];
    String? zoneId;
    List<_Prop>? zoneRule;
    String? zoneKind;
    final zoneProps = <(String, List<_Prop>)>[];
    var depth = <String>[];
    for (final p in lines) {
      if (p.name == 'BEGIN') {
        depth.add(p.value.toUpperCase());
        if (p.value.toUpperCase() == 'VEVENT') event = [];
        if (p.value.toUpperCase() == 'VTIMEZONE') {
          zoneId = null;
          zoneProps.clear();
        }
        if (p.value.toUpperCase() == 'STANDARD' || p.value.toUpperCase() == 'DAYLIGHT') {
          zoneRule = [];
          zoneKind = p.value.toUpperCase();
        }
        continue;
      }
      if (p.name == 'END') {
        final what = p.value.toUpperCase();
        if (depth.isNotEmpty) depth.removeLast();
        if (what == 'VEVENT' && event != null) {
          events.add(event);
          event = null;
        } else if ((what == 'STANDARD' || what == 'DAYLIGHT') && zoneRule != null) {
          zoneProps.add((zoneKind!, zoneRule));
          zoneRule = null;
        } else if (what == 'VTIMEZONE' && zoneId != null) {
          zones[zoneId] = [for (final z in zoneProps) ?_ZoneRule.parse(z.$2)];
        }
        continue;
      }
      final inZoneRule = zoneRule != null;
      if (inZoneRule) {
        zoneRule.add(p);
      } else if (depth.contains('VTIMEZONE')) {
        if (p.name == 'TZID') zoneId = p.value;
      } else if (event != null) {
        if (depth.last == 'VEVENT') event.add(p);
      } else if (p.name == 'METHOD') {
        method = p.value.trim().toUpperCase();
      }
    }
    if (events.isEmpty) return null;
    final props = events.first;
    _Prop? get(String n) {
      for (final p in props) {
        if (p.name == n) return p;
      }
      return null;
    }

    final uid = get('UID')?.value.trim() ?? '';
    final dtstart = get('DTSTART');
    if (uid.isEmpty || dtstart == null) return null;
    final startPoint = _parseDate(dtstart, zones);
    if (startPoint == null) return null;
    DateTime? end;
    final dtend = get('DTEND');
    if (dtend != null) {
      end = _parseDate(dtend, zones)?.time;
    } else if (get('DURATION') != null) {
      final d = _parseDuration(get('DURATION')!.value);
      if (d != null) end = startPoint.time.add(d);
    } else if (startPoint.allDay) {
      end = startPoint.time.add(const Duration(days: 1));
    }

    String clean(String? s) => _unescape(s ?? '').trim();
    final org = get('ORGANIZER');
    final attendees = <InviteAttendee>[];
    for (final p in props) {
      if (p.name != 'ATTENDEE') continue;
      final email = _mailto(p.value);
      if (email.isEmpty) continue;
      attendees.add(InviteAttendee(
        email: email,
        name: _unescape(p.params['CN'] ?? '').trim(),
        partStat: PartStat.parse(p.params['PARTSTAT']),
        role: p.params['ROLE'] ?? '',
        rsvp: (p.params['RSVP'] ?? '').toUpperCase() == 'TRUE',
      ));
    }
    final rec = get('RECURRENCE-ID');
    return Invite(
      method: method.isEmpty ? 'PUBLISH' : method,
      uid: uid,
      sequence: int.tryParse(get('SEQUENCE')?.value.trim() ?? '') ?? 0,
      summary: clean(get('SUMMARY')?.value).isEmpty ? '(no title)' : clean(get('SUMMARY')?.value),
      description: clean(get('DESCRIPTION')?.value),
      location: clean(get('LOCATION')?.value),
      start: startPoint.time,
      end: end,
      allDay: startPoint.allDay,
      startTzid: startPoint.tzid,
      timeZoneKnown: startPoint.known,
      organizerName: _unescape(org?.params['CN'] ?? '').trim(),
      organizerEmail: org == null ? '' : _mailto(org.value),
      attendees: attendees,
      recurrenceId: rec?.value.trim(),
      rrule: get('RRULE')?.value.trim(),
      rawIcs: ics,
    ).withMe(myEmails);
  }

  // ------------------------------------------------------------- replying

  /// The iTIP REPLY document for my answer [stat].
  String buildReply(PartStat stat, {required MailAddress me, DateTime? now}) {
    final stamp = _formatUtc((now ?? DateTime.now()).toUtc());
    // Answer with the address the organizer invited, if I was invited
    // under a different one (an alias).
    final email = this.me?.email ?? me.email;
    final cn = (this.me?.name.isNotEmpty ?? false) ? this.me!.name : (me.personalName ?? '');
    final lines = <String>[
      'BEGIN:VCALENDAR',
      'PRODID:-//Hearthmail//Mail//EN',
      'VERSION:2.0',
      'CALSCALE:GREGORIAN',
      'METHOD:REPLY',
      'BEGIN:VEVENT',
      'UID:$uid',
      'SEQUENCE:$sequence',
      'DTSTAMP:$stamp',
      if (recurrenceId != null && recurrenceId!.isNotEmpty) 'RECURRENCE-ID:$recurrenceId',
      _dateLine('DTSTART', start),
      if (end != null) _dateLine('DTEND', end!),
      'SUMMARY:${_escape(summary)}',
      if (organizerEmail.isNotEmpty)
        'ORGANIZER${organizerName.isEmpty ? '' : ';CN=${_quoteParam(organizerName)}'}:mailto:$organizerEmail',
      'ATTENDEE;PARTSTAT=${stat.ical}${cn.isEmpty ? '' : ';CN=${_quoteParam(cn)}'}:mailto:$email',
      'END:VEVENT',
      'END:VCALENDAR',
    ];
    return '${lines.map(_fold).join('\r\n')}\r\n';
  }

  String _dateLine(String name, DateTime t) {
    if (allDay) return '$name;VALUE=DATE:${_formatDate(t)}';
    if (t.isUtc) return '$name:${_formatUtc(t)}';
    return '$name:${_formatLocal(t)}';
  }

  /// The message to the organizer carrying the reply, e.g. "Accepted: Team
  /// sync". Send it with `MailService.sendBuilt`.
  MimeMessage buildReplyMessage(PartStat stat, {required MailAddress me, MimeMessage? inReplyTo, DateTime? now}) {
    final org = organizer;
    if (org == null) throw StateError('This invitation has no organizer to reply to.');
    final ics = buildReply(stat, me: me, now: now);
    final who = me.personalName?.isNotEmpty == true ? me.personalName! : me.email;
    final plain = '$who has ${stat.verb} this invitation.\n\n$summary';
    final builder = MessageBuilder.prepareMultipartAlternativeMessage()
      ..from = [me]
      ..to = [org]
      ..subject = '${stat.subjectPrefix}: $summary';
    if (inReplyTo != null) builder.originalMessage = inReplyTo;
    builder.addTextPlain(plain);
    builder.addPart()
      ..setContentType(
        MediaType.fromText('text/calendar'),
        characterSet: CharacterSet.utf8,
        parameters: {'method': 'REPLY'},
      )
      ..transferEncoding = TransferEncoding.base64
      ..text = ics;
    return builder.buildMimeMessage();
  }

  /// The invitation as a plain event file that Calendar imports directly
  /// (METHOD REQUEST would make it try to send replies by itself).
  String toImportIcs() =>
      rawIcs.replaceFirstMapped(RegExp(r'^METHOD:.*$', multiLine: true), (_) => 'METHOD:PUBLISH');
}

// ================================================================ internals

class _Prop {
  _Prop(this.name, this.params, this.value);
  final String name;
  final Map<String, String> params;
  final String value;
}

class _Point {
  _Point(this.time, {this.allDay = false, this.tzid, this.known = true});
  final DateTime time;
  final bool allDay;
  final String? tzid;
  final bool known;
}

List<_Prop> _contentLines(String ics) {
  final text = ics.replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll(RegExp(r'\n[ \t]'), '');
  final out = <_Prop>[];
  for (final line in text.split('\n')) {
    if (line.trim().isEmpty) continue;
    var nameEnd = -1;
    var inQuote = false;
    // Find the colon that ends the name and parameters.
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        inQuote = !inQuote;
      } else if (c == ':' && !inQuote) {
        nameEnd = i;
        break;
      }
    }
    if (nameEnd < 0) continue;
    final head = line.substring(0, nameEnd);
    final value = line.substring(nameEnd + 1);
    final parts = _splitParams(head);
    final params = <String, String>{};
    for (final p in parts.skip(1)) {
      final eq = p.indexOf('=');
      if (eq <= 0) continue;
      var v = p.substring(eq + 1);
      if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) v = v.substring(1, v.length - 1);
      params[p.substring(0, eq).toUpperCase()] = v;
    }
    out.add(_Prop(parts.first.toUpperCase(), params, value));
  }
  return out;
}

List<String> _splitParams(String head) {
  final out = <String>[];
  final b = StringBuffer();
  var inQuote = false;
  for (var i = 0; i < head.length; i++) {
    final c = head[i];
    if (c == '"') inQuote = !inQuote;
    if (c == ';' && !inQuote) {
      out.add(b.toString());
      b.clear();
    } else {
      b.write(c);
    }
  }
  out.add(b.toString());
  return out;
}

String _mailto(String v) {
  final t = v.trim();
  return t.toLowerCase().startsWith('mailto:') ? t.substring(7).trim() : (t.contains('@') ? t : '');
}

String _unescape(String s) => s
    .replaceAllMapped(RegExp(r'\\([nN,;\\])'), (m) => m[1]!.toLowerCase() == 'n' ? '\n' : m[1]!);

String _escape(String s) =>
    s.replaceAll(r'\', r'\\').replaceAll(';', r'\;').replaceAll(',', r'\,').replaceAll('\r\n', r'\n').replaceAll('\n', r'\n');

/// A quoted ICS parameter value: no quotes, and no line breaks or other
/// control characters that could start a new property.
String _quoteParam(String s) => '"${s.replaceAll('"', "'").replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')}"';

String _p2(int n) => n.toString().padLeft(2, '0');
String _formatDate(DateTime t) => '${t.year.toString().padLeft(4, '0')}${_p2(t.month)}${_p2(t.day)}';
String _formatLocal(DateTime t) => '${_formatDate(t)}T${_p2(t.hour)}${_p2(t.minute)}${_p2(t.second)}';
String _formatUtc(DateTime t) => '${_formatLocal(t.toUtc())}Z';

/// Folds a content line at 75 octets, as RFC 5545 asks.
String _fold(String line) {
  if (utf8.encode(line).length <= 75) return line;
  final out = StringBuffer();
  var bytes = 0;
  var limit = 75;
  for (final rune in line.runes) {
    final ch = String.fromCharCode(rune);
    final n = utf8.encode(ch).length;
    if (bytes + n > limit) {
      out.write('\r\n ');
      bytes = 1;
      limit = 75;
    }
    out.write(ch);
    bytes += n;
  }
  return out.toString();
}

Duration? _parseDuration(String v) {
  final m = RegExp(r'^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$').firstMatch(v.trim().toUpperCase());
  if (m == null) return null;
  int n(int i) => int.tryParse(m[i] ?? '') ?? 0;
  final d = Duration(days: n(2) * 7 + n(3), hours: n(4), minutes: n(5), seconds: n(6));
  return m[1] == '-' ? -d : d;
}

_Point? _parseDate(_Prop p, Map<String, List<_ZoneRule>> zones) {
  final v = p.value.trim();
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$').firstMatch(v);
  if (m == null) return null;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  final isDate = m[4] == null || (p.params['VALUE'] ?? '').toUpperCase() == 'DATE';
  if (isDate) return _Point(DateTime(y, mo, d), allDay: true);
  final h = int.parse(m[4]!), mi = int.parse(m[5]!), s = int.tryParse(m[6] ?? '') ?? 0;
  if (m[7] != null) return _Point(DateTime.utc(y, mo, d, h, mi, s));
  final tzid = p.params['TZID'];
  if (tzid == null) return _Point(DateTime(y, mo, d, h, mi, s)); // floating
  final rules = zones[tzid];
  final local = DateTime.utc(y, mo, d, h, mi, s); // wall clock, tagged as UTC for arithmetic
  final offset = rules == null ? null : _offsetAt(rules, local);
  if (offset == null) return _Point(DateTime(y, mo, d, h, mi, s), tzid: tzid, known: false);
  return _Point(local.subtract(Duration(seconds: offset)), tzid: tzid);
}

/// One STANDARD or DAYLIGHT block of a VTIMEZONE.
class _ZoneRule {
  _ZoneRule(this.from, this.offset, this.month, this.weekday, this.nth, this.until);

  final DateTime from; // wall-clock start (as UTC-tagged value)
  final int offset; // seconds east of UTC after the transition
  final int? month;
  final int? weekday; // DateTime.monday..sunday
  final int nth; // 1..5, or -1 for last
  final DateTime? until;

  bool get repeats => month != null && weekday != null;

  static _ZoneRule? parse(List<_Prop> props) {
    String? val(String n) {
      for (final p in props) {
        if (p.name == n) return p.value.trim();
      }
      return null;
    }

    final dt = val('DTSTART');
    final off = val('TZOFFSETTO');
    if (dt == null || off == null) return null;
    final dm = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})').firstMatch(dt);
    final om = RegExp(r'^([+-])(\d{2})(\d{2})(\d{2})?$').firstMatch(off);
    if (dm == null || om == null) return null;
    final from = DateTime.utc(int.parse(dm[1]!), int.parse(dm[2]!), int.parse(dm[3]!), int.parse(dm[4]!), int.parse(dm[5]!), int.parse(dm[6]!));
    final offset = (om[1] == '-' ? -1 : 1) * (int.parse(om[2]!) * 3600 + int.parse(om[3]!) * 60 + (int.tryParse(om[4] ?? '') ?? 0));
    int? month, weekday;
    var nth = 1;
    DateTime? until;
    final rr = val('RRULE');
    if (rr != null) {
      final parts = {
        for (final kv in rr.split(';'))
          if (kv.contains('=')) kv.split('=').first.toUpperCase(): kv.split('=').last,
      };
      month = int.tryParse(parts['BYMONTH'] ?? '');
      final by = RegExp(r'^([+-]?\d)?(MO|TU|WE|TH|FR|SA|SU)$').firstMatch((parts['BYDAY'] ?? '').split(',').first);
      if (by != null) {
        nth = int.tryParse(by[1] ?? '') ?? 1;
        weekday = const {'MO': 1, 'TU': 2, 'WE': 3, 'TH': 4, 'FR': 5, 'SA': 6, 'SU': 7}[by[2]];
      }
      final u = RegExp(r'^(\d{4})(\d{2})(\d{2})').firstMatch(parts['UNTIL'] ?? '');
      if (u != null) until = DateTime.utc(int.parse(u[1]!), int.parse(u[2]!), int.parse(u[3]!), 23, 59, 59);
    }
    return _ZoneRule(from, offset, month, weekday, nth, until);
  }

  /// The latest transition of this rule at or before the wall-clock [t].
  DateTime? lastTransitionAtOrBefore(DateTime t) {
    if (!repeats) return from.isAfter(t) ? null : from;
    DateTime? best;
    for (final year in [t.year, t.year - 1]) {
      if (year < from.year) continue;
      final day = _nthWeekday(year, month!, weekday!, nth);
      final tr = DateTime.utc(year, month!, day, from.hour, from.minute, from.second);
      if (tr.isAfter(t) || tr.isBefore(from)) continue;
      if (until != null && tr.isAfter(until!)) continue;
      if (best == null || tr.isAfter(best)) best = tr;
    }
    return best;
  }

  static int _nthWeekday(int year, int month, int weekday, int nth) {
    if (nth > 0) {
      final first = DateTime.utc(year, month, 1);
      return 1 + (weekday - first.weekday + 7) % 7 + (nth - 1) * 7;
    }
    final last = DateTime.utc(year, month + 1, 0);
    return last.day - (last.weekday - weekday + 7) % 7 + (nth + 1) * 7;
  }
}

/// Seconds east of UTC in force at wall-clock time [t], or null if unknown.
int? _offsetAt(List<_ZoneRule> rules, DateTime t) {
  if (rules.isEmpty) return null;
  DateTime? latest;
  int? offset;
  for (final r in rules) {
    final tr = r.lastTransitionAtOrBefore(t);
    if (tr != null && (latest == null || tr.isAfter(latest))) {
      latest = tr;
      offset = r.offset;
    }
  }
  if (offset != null) return offset;
  // Before every transition: the oldest rule's offset is the best guess.
  final sorted = [...rules]..sort((a, b) => a.from.compareTo(b.from));
  return sorted.first.offset;
}

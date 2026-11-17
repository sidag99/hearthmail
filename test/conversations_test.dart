import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearthmail/models/account_config.dart';
import 'package:hearthmail/services/calendar_invite.dart';
import 'package:hearthmail/services/mail_service.dart';
import 'package:hearthmail/services/settings_store.dart';
import 'package:hearthmail/services/threads.dart';
import 'package:hearthmail/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

MimeMessage msg(String headers, [String body = 'Hello']) =>
    MimeMessage.parseFromText('${headers.trim()}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n$body\r\n');

const googleIcs = 'BEGIN:VCALENDAR\r\nPRODID:-//Google Inc//Google Calendar 70.9054//EN\r\nVERSION:2.0\r\n'
    'METHOD:REQUEST\r\nBEGIN:VEVENT\r\nDTSTART:20261120T150000Z\r\nDTEND:20261120T160000Z\r\n'
    'DTSTAMP:20261110T090000Z\r\nORGANIZER;CN=Olga Orga:mailto:olga@example.com\r\nUID:abc123@google.com\r\n'
    'ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Me Myself;X-NUM-GUESTS=0:mailto:me@example.org\r\n'
    'ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;CN=Olga Orga:mailto:olga@example.com\r\n'
    'SEQUENCE:2\r\nSUMMARY:Planning\\, Q1\r\nLOCATION:Room 4\\; Berlin\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n';

const outlookIcs = 'BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nPRODID:Microsoft Exchange Server 2010\r\nVERSION:2.0\r\n'
    'BEGIN:VTIMEZONE\r\nTZID:W. Europe Standard Time\r\n'
    'BEGIN:STANDARD\r\nDTSTART:16010101T030000\r\nTZOFFSETFROM:+0200\r\nTZOFFSETTO:+0100\r\nRRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=10\r\nEND:STANDARD\r\n'
    'BEGIN:DAYLIGHT\r\nDTSTART:16010101T020000\r\nTZOFFSETFROM:+0100\r\nTZOFFSETTO:+0200\r\nRRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=3\r\nEND:DAYLIGHT\r\n'
    'END:VTIMEZONE\r\nBEGIN:VEVENT\r\nORGANIZER;CN=Boss:MAILTO:boss@corp.example\r\n'
    'ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Me:MAILTO:me@example.org\r\n'
    'UID:040000008200E00074C5B7101A82E008\r\nSUMMARY:Review\r\n'
    'DTSTART;TZID=W. Europe Standard Time:20261215T100000\r\nDTEND;TZID=W. Europe Standard Time:20261215T110000\r\n'
    'SEQUENCE:0\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n';

String inviteMail(String ics) => 'From: Olga <olga@example.com>\r\nTo: me@example.org\r\nSubject: Invitation\r\nMessage-ID: <inv@x>\r\n'
    'MIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=BB\r\n\r\n'
    '--BB\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nYou are invited\r\n'
    '--BB\r\nContent-Type: text/calendar; charset=utf-8; method=REQUEST\r\n\r\n$ics\r\n--BB--\r\n';

void main() {
  group('invites', () {
    test('parses a Google Calendar invitation', () {
      final m = MimeMessage.parseFromText(inviteMail(googleIcs));
      final inv = Invite.findIn(m, myEmails: ['ME@example.org'])!;
      expect(inv.isRequest, isTrue);
      expect(inv.uid, 'abc123@google.com');
      expect(inv.sequence, 2);
      expect(inv.summary, 'Planning, Q1');
      expect(inv.location, 'Room 4; Berlin');
      expect(inv.start, DateTime.utc(2026, 11, 20, 15));
      expect(inv.end, DateTime.utc(2026, 11, 20, 16));
      expect(inv.organizerEmail, 'olga@example.com');
      expect(inv.organizerName, 'Olga Orga');
      expect(inv.attendees, hasLength(2));
      expect(inv.me?.email, 'me@example.org');
      expect(inv.me?.partStat, PartStat.needsAction);
    });

    test('parses an Outlook invitation with TZID (winter and summer)', () {
      final inv = Invite.parse(outlookIcs, myEmails: ['me@example.org'])!;
      expect(inv.startTzid, 'W. Europe Standard Time');
      expect(inv.start, DateTime.utc(2026, 12, 15, 9)); // CET = UTC+1
      expect(inv.end, DateTime.utc(2026, 12, 15, 10));
      expect(inv.organizerEmail, 'boss@corp.example');
      expect(inv.me, isNotNull);
      final summer = Invite.parse(outlookIcs.replaceAll('20261215', '20260715'))!;
      expect(summer.start, DateTime.utc(2026, 7, 15, 8)); // CEST = UTC+2
    });

    test('all-day events', () {
      final ics = googleIcs
          .replaceAll('DTSTART:20261120T150000Z', 'DTSTART;VALUE=DATE:20261120')
          .replaceAll('DTEND:20261120T160000Z', 'DTEND;VALUE=DATE:20261121');
      final inv = Invite.parse(ics)!;
      expect(inv.allDay, isTrue);
      expect(inv.start, DateTime(2026, 11, 20));
      expect(inv.displayEnd, DateTime(2026, 11, 20));
    });

    test('ignores messages without a calendar part', () {
      expect(Invite.findIn(msg('From: a@x.com\r\nSubject: Hi')), isNull);
    });

    test('builds an iTIP REPLY', () {
      final inv = Invite.parse(googleIcs, myEmails: ['me@example.org'])!;
      final me = MailAddress('Me Myself', 'me@example.org');
      final ics = inv.buildReply(PartStat.tentative, me: me, now: DateTime.utc(2026, 11, 18, 8));
      expect(ics, contains('METHOD:REPLY'));
      expect(ics, contains('UID:abc123@google.com'));
      expect(ics, contains('SEQUENCE:2'));
      expect(ics, contains('DTSTAMP:20261118T080000Z'));
      expect(ics, contains('PARTSTAT=TENTATIVE'));
      expect(ics, contains(':mailto:me@example.org'));
      expect('ATTENDEE'.allMatches(ics), hasLength(1));

      final mail = inv.buildReplyMessage(PartStat.accepted, me: me, now: DateTime.utc(2026, 11, 18, 8));
      expect(mail.decodeSubject(), 'Accepted: Planning, Q1');
      expect(mail.to!.single.email, 'olga@example.com');
      final cal = Invite.calendarTexts(MimeMessage.parseFromText(mail.renderMessage())).single;
      expect(cal, contains('METHOD:REPLY'));
      expect(cal, contains('PARTSTAT=ACCEPTED'));
      expect(mail.renderMessage(), contains('method=REPLY'));
    });
  });

  group('threads', () {
    final a = msg('From: a@x.com\r\nMessage-ID: <1@x>\r\nDate: Mon, 16 Nov 2026 10:00:00 +0000\r\nSubject: Plan');
    final b = msg('From: b@x.com\r\nMessage-ID: <2@x>\r\nIn-Reply-To: <1@x>\r\nReferences: <1@x>\r\nDate: Mon, 16 Nov 2026 11:00:00 +0000\r\nSubject: Re: Plan');
    // Reply sent by me (found in Sent), without References.
    final c = msg('From: me@example.org\r\nMessage-ID: <3@x>\r\nIn-Reply-To: <2@x>\r\nDate: Mon, 16 Nov 2026 12:00:00 +0000\r\nSubject: Re: Plan');
    final other = msg('From: z@x.com\r\nMessage-ID: <9@x>\r\nDate: Tue, 17 Nov 2026 12:00:00 +0000\r\nSubject: Else');

    test('threadKeyOf matches replies', () {
      expect(MailService.threadKeyOf(b), MailService.threadKeyOf(a));
      expect(MailService.threadKeyOf(c), isNot(MailService.threadKeyOf(a)));
    });

    test('ThreadIndex links a reply that lacks References', () {
      final idx = ThreadIndex([a, b, c, other]);
      expect(idx.keyOf(c), idx.keyOf(a));
      expect(idx.keyOf(other), isNot(idx.keyOf(a)));
    });

    test('AppState conversations and collapse', () async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState(await SettingsStore.open());
      const cfg = AccountConfig(id: 'a', email: 'me@example.org', displayName: 'Me', imapHost: 'i', smtpHost: 's');
      final inbox = Mailbox(encodedName: 'INBOX', encodedPath: 'INBOX', pathSeparator: '/', flags: [MailboxFlag.inbox]);
      final sent = Mailbox(encodedName: 'Sent', encodedPath: 'Sent', pathSeparator: '/', flags: [MailboxFlag.sent]);
      state.debugLoad(data: [(account: cfg, mailboxes: [inbox], messages: [other, b, a], triage: const {})]);
      state.debugSetSent(state.sessions.first, [c], sent);

      final conv = state.conversationOf(b);
      expect(conv.map(ThreadIndex.messageIdOf), ['<1@x>', '<2@x>', '<3@x>']);
      expect(state.conversationSize(a), 3);
      expect(state.conversationSize(other), 1);
      final collapsed = state.collapseThreads([other, b, a]);
      expect(collapsed, [other, b]);
      expect(state.settings.groupConversations, isTrue);
    });
  });

  test('draftToOutgoing restores recipients, subject and body', () async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(await SettingsStore.open());
    const cfg = AccountConfig(id: 'a', email: 'me@example.org', displayName: 'Me', imapHost: 'i', smtpHost: 's');
    final drafts = Mailbox(encodedName: 'Drafts', encodedPath: 'Drafts', pathSeparator: '/', flags: [MailboxFlag.drafts]);
    final inbox = Mailbox(encodedName: 'INBOX', encodedPath: 'INBOX', pathSeparator: '/', flags: [MailboxFlag.inbox]);
    state.debugLoad(data: [(account: cfg, mailboxes: [inbox, drafts], messages: <MimeMessage>[], triage: const {})]);
    final draft = msg(
      'From: me@example.org\r\nTo: Ann <ann@x.com>, bob@x.com\r\nCc: cc@x.com\r\nBcc: hid@x.com\r\nSubject: Half done',
      'Dear Ann,\r\nsee below',
    );
    final out = await state.draftToOutgoing(draft);
    expect(out.to, contains('ann@x.com'));
    expect(out.to, contains('bob@x.com'));
    expect(out.cc, 'cc@x.com');
    expect(out.bcc, 'hid@x.com');
    expect(out.subject, 'Half done');
    expect(out.body, contains('see below'));
    expect(out.files, isEmpty);
    expect(identical(out.replacesDraft, draft), isTrue);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:hearthmail/models/search_plan.dart';
import 'package:hearthmail/services/ai/email_ai.dart';
import 'package:hearthmail/services/html_text.dart';
import 'package:hearthmail/services/mail_service.dart';

void main() {
  group('SearchPlan', () {
    test('builds IMAP criteria with OR-ed keywords and dates', () {
      final p = SearchPlan(
        keywords: const ['invoice', 'receipt', 'bill'],
        from: 'chase',
        since: DateTime(2026, 10, 1),
        before: DateTime(2026, 11, 1),
        unreadOnly: true,
      );
      expect(
        p.toImapCriteria(),
        'FROM "chase" SINCE 1-Oct-2026 BEFORE 1-Nov-2026 UNSEEN '
        '(OR TEXT "invoice" OR TEXT "receipt" TEXT "bill")',
      );
      expect(p.toGmailQuery(),
          'from:chase after:2026/10/01 before:2026/11/01 is:unread (invoice OR receipt OR bill)');
    });

    test('escapes quotes and handles empty plans', () {
      expect(const SearchPlan(keywords: ['say "hi"']).toImapCriteria(), r'TEXT "say \"hi\""');
      expect(const SearchPlan().toImapCriteria(), 'ALL');
    });

    test('parses model JSON leniently', () {
      final p = SearchPlan.fromJson({
        'keywords': ['flight', ' '],
        'from': '',
        'to': 'null',
        'since': '2026-11-01',
        'before': 'not a date',
      });
      expect(p.keywords, ['flight']);
      expect(p.from, isNull);
      expect(p.to, isNull);
      expect(p.since, DateTime(2026, 11, 1));
      expect(p.before, isNull);
    });
  });

  test('htmlToText keeps structure and drops styles', () {
    const html = '<html><head><style>p{color:red}</style></head><body>'
        '<p>Hello&nbsp;there</p><ul><li>One</li><li>Two</li></ul></body></html>';
    final t = htmlToText(html);
    expect(t, contains('Hello'));
    expect(t, contains('- One'));
    expect(t, isNot(contains('color')));
  });

  test('blockRemoteImages removes tracking images only', () {
    const html = '<p>Hi<img src="https://t.example.com/pixel.gif"><img src="cid:logo"></p>';
    final out = blockRemoteImages(html);
    expect(out, isNot(contains('pixel.gif')));
    expect(out, contains('cid:logo'));
  });

  test('cleanDraft strips preambles, subject lines and fences', () {
    expect(EmailAi.cleanDraft("Here's a draft:\nSubject: Hi\n\nHello Sam,\nThanks!"), 'Hello Sam,\nThanks!');
    expect(EmailAi.cleanDraft('```\nHello\n```'), 'Hello');
  });

  test('parseAddresses splits lists', () {
    final a = MailService.parseAddresses('Ann <ann@x.com>, bob@y.com; ');
    expect(a.map((e) => e.email), ['ann@x.com', 'bob@y.com']);
    expect(a.first.personalName, 'Ann');
  });

  test('markdownToPlain removes formatting marks', () {
    expect(MailService.markdownToPlain('**Due:** Friday\n## Notes\n[link](https://a.b)'),
        'Due: Friday\nNotes\nlink (https://a.b)');
  });
}

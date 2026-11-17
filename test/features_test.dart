import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen_mail/models/email_content.dart';
import 'package:lumen_mail/services/ai/email_ai.dart';
import 'package:lumen_mail/services/email_html.dart';
import 'package:lumen_mail/services/mail_service.dart';
import 'package:lumen_mail/services/user_data.dart';
import 'package:lumen_mail/services/vector_index.dart';

MimeMessage msg(String headers, [String body = 'Hello']) =>
    MimeMessage.parseFromText('${headers.trim()}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n$body\r\n');

void main() {
  group('EmailDocument', () {
    test('blocks scripts, handlers and remote images; keeps inline images', () {
      final doc = EmailDocument.fromHtml(
        '<html><head><script>alert(1)</script></head><body onload="x()">'
        '<a href="javascript:evil()">bad</a><img src="https://t.co/p.gif" width="1" height="1">'
        '<img src="https://cdn.x.com/hero.png" width="600"><img src="cid:logo@x"></body></html>',
        allowRemote: false,
        inlineImage: (cid) => cid == 'logo@x' ? 'data:image/png;base64,AAAA' : null,
      );
      expect(doc.html, isNot(contains('alert(1)')));
      expect(doc.html, isNot(contains('onload')));
      expect(doc.html, isNot(contains('javascript:')));
      expect(doc.html, isNot(contains('t.co/p.gif')));
      expect(doc.html, isNot(contains('hero.png')));
      expect(doc.html, contains('data-lm-blocked'));
      expect(doc.html, contains('data:image/png;base64,AAAA'));
      expect(doc.html, contains("script-src 'nonce-"));
      expect(doc.html, contains("img-src data: cid:;"));
      expect(doc.blockedImages, 2);
    });

    test('allows remote images when asked', () {
      final doc = EmailDocument.fromHtml('<img src="https://cdn.x.com/hero.png">', allowRemote: true);
      expect(doc.html, contains('hero.png'));
      expect(doc.html, contains('img-src data: cid: https: http:'));
    });

    test('folds Gmail quotes', () {
      final doc = EmailDocument.fromHtml(
          '<div>Sounds good!</div><div class="gmail_quote">On Mon, Ann wrote: a long quoted message with plenty of text here.</div>',
          allowRemote: false);
      expect(doc.html, contains('<details class="lm-quote">'));
      expect(doc.html.indexOf('lm-quote'), lessThan(doc.html.indexOf('gmail_quote">On Mon')));
    });

    test('plain text: links, quotes folded, signature dimmed', () {
      final html = EmailDocument.plainToHtml('Hi, see https://example.com/a?b=1.\n'
          'Mail me at bob@x.org\n-- \nBob\n\nOn Mon, Ann <ann@x.com> wrote:\n> first\n> > older\n> second');
      expect(html, contains('<a href="https://example.com/a?b=1">https://example.com/a?b=1</a>.'));
      expect(html, contains('<a href="mailto:bob@x.org">'));
      expect(html, contains('<span class="lm-sig">'));
      expect(html, contains('<details class="lm-quote">'));
      expect(html, contains('<blockquote>first\n<blockquote>older'));
    });

    test('plain text escapes HTML', () {
      expect(EmailDocument.plainToHtml('<b>not bold</b> & co'), '&lt;b&gt;not bold&lt;/b&gt; &amp; co');
    });
  });

  group('Languages.guess', () {
    test('recognizes common languages', () {
      expect(Languages.guess('Thanks for the quick turnaround! Could you push the review to next Tuesday? I am swamped until then.'), 'English');
      expect(Languages.guess('Sehr geehrter Herr Rivera, leider müssen wir Ihren Termin am Donnerstag absagen, da die Ärztin krank ist.'), 'German');
      expect(Languages.guess('Bonjour, nous avons bien reçu votre dossier. Pourriez-vous nous envoyer une copie de votre diplôme pour le 30 novembre ?'), 'French');
      expect(Languages.guess('बेटा, रविवार को मम्मी का जन्मदिन है। शाम को छह बजे वीडियो कॉल करेंगे।'), 'Hindi');
      expect(Languages.guess('お世話になっております。先日ご依頼いただいた見積書を添付いたします。'), 'Japanese');
    });

    test('is unsure about very short text', () {
      expect(Languages.guess('OK'), isNull);
    });
  });

  group('VectorIndex', () {
    test('finds the closest vectors and forgets removed ones', () {
      final index = VectorIndex.memory('m');
      final d = DateTime(2026);
      index.add(IndexedMail('a', 'INBOX', 1, d), [1, 0, 0]);
      index.add(IndexedMail('b', 'INBOX', 2, d), [0.8, 0.6, 0]);
      index.add(IndexedMail('c', 'INBOX', 3, d), [0, 0, 1]);
      final hits = index.search([1, 0.1, 0], minScore: 0.5);
      expect(hits.map((h) => h.$1.key), ['a', 'b']);
      index.remove('a');
      expect(index.contains('a'), isFalse);
      expect(index.search([1, 0.1, 0], minScore: 0.5).map((h) => h.$1.key), ['b']);
      expect(index.length, 2);
    });

    test('formats documents and queries for each model', () {
      final e = EmailContent(id: '1', from: 'Ann <ann@x.com>', subject: 'Flight', body: 'TP1153 to Lisbon', date: DateTime(2026, 12, 14));
      expect(const EmbeddingFormat('embeddinggemma:300m').document(e), startsWith('title: Flight | text: from: Ann'));
      expect(const EmbeddingFormat('embeddinggemma:300m').query('flight'), 'task: search result | query: flight');
      expect(const EmbeddingFormat('qwen3-embedding:0.6b').query('flight'), contains('Query: flight'));
    });
  });

  group('MailService helpers', () {
    test('parses unsubscribe headers', () {
      final m = msg('From: news@shop.com\r\nList-Unsubscribe: <mailto:u@shop.com?subject=stop>, <https://shop.com/u?id=1>\r\n'
          'List-Unsubscribe-Post: List-Unsubscribe=One-Click');
      final u = MailService.unsubscribeOf(m)!;
      expect(u.web.toString(), 'https://shop.com/u?id=1');
      expect(u.mail!.path, 'u@shop.com');
      expect(u.oneClick, isTrue);
      expect(MailService.unsubscribeOf(msg('From: a@b.com')), isNull);
    });

    test('flags forged senders but not real ones', () {
      expect(MailService.suspicionOf(msg('From: "PayPal Security" <alert@secure-pay-check.ru>')), isNotNull);
      expect(MailService.suspicionOf(msg('From: "support@apple.com" <x@mailer.biz>')), isNotNull);
      expect(MailService.suspicionOf(msg('From: "PayPal" <service@paypal.de>')), isNull);
      expect(MailService.suspicionOf(msg('From: "Priya" <priya@gmail.com>')), isNull);
    });

    test('groups a conversation', () {
      final first = msg('From: a@x.com\r\nMessage-ID: <1@x>\r\nSubject: Plan');
      final reply = msg('From: b@x.com\r\nMessage-ID: <2@x>\r\nIn-Reply-To: <1@x>\r\nReferences: <1@x>\r\nSubject: Re: Plan');
      final reply2 = msg('From: a@x.com\r\nMessage-ID: <3@x>\r\nIn-Reply-To: <2@x>\r\nReferences: <1@x> <2@x>\r\nSubject: Re: Re: Plan');
      expect(MailService.threadKeyOf(reply), MailService.threadKeyOf(first));
      expect(MailService.threadKeyOf(reply2), MailService.threadKeyOf(first));
      expect(MailService.normalizedSubject('Re: AW: Fwd: Plan'), 'plan');
    });
  });

  test('calendar export', () {
    final ics = EmailEvent(title: 'Dr. Schulz, dermatology', start: DateTime(2026, 11, 19, 8, 30), location: 'Berlin').toIcs();
    expect(ics, contains('DTSTART:20261119T083000'));
    expect(ics, contains('DTEND:20261119T093000'));
    expect(ics, contains(r'SUMMARY:Dr. Schulz\, dermatology'));
    final allDay = EmailEvent(title: 'Wedding', start: DateTime(2027, 3, 14), allDay: true).toIcs();
    expect(allDay, contains('DTSTART;VALUE=DATE:20270314'));
    expect(allDay, contains('DTEND;VALUE=DATE:20270315'));
  });

  test('contacts autocomplete and blocking', () {
    final d = UserData.memory();
    d.noteContact('priya@gmail.com', 'Priya Sharma', weight: 5);
    d.noteContact('prof.weber@uni.edu', 'Hans Weber');
    d.noteContact('noreply@shop.com', 'Shop');
    expect(d.suggestContacts('pri').first.$1, 'priya@gmail.com');
    expect(d.suggestContacts('sharma').first.$1, 'priya@gmail.com');
    expect(d.suggestContacts('weber').first.$1, 'prof.weber@uni.edu');
    expect(d.suggestContacts('noreply'), isEmpty);
    d.blocked.add('@spam.biz');
    expect(d.isBlocked('Anyone@SPAM.biz'), isTrue);
    expect(d.isBlocked('friend@ok.com'), isFalse);
  });
}

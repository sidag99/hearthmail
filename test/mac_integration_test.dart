import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearthmail/services/mail_service.dart';
import 'package:hearthmail/services/mailto.dart';
import 'package:hearthmail/services/print_message.dart';
import 'package:hearthmail/ui/app_menus.dart';
import 'package:material_ui/material_ui.dart';

List<String> _labels(List<PlatformMenuItem> items) {
  final out = <String>[];
  for (final i in items) {
    if (i is PlatformMenuItemGroup) {
      out.addAll(_labels(i.members));
    } else if (i is PlatformMenu) {
      out.add(i.label);
      out.addAll(_labels(i.menus));
    } else if (i is PlatformProvidedMenuItem) {
      out.add('<${i.type.name}>');
    } else {
      out.add(i.label);
    }
  }
  return out;
}

void main() {
  group('MailtoRequest', () {
    MailtoRequest p(String s) => MailtoRequest.parseString(s)!;

    test('simple address', () {
      expect(p('mailto:a@example.com').to, ['a@example.com']);
    });

    test('multiple addresses, cc, bcc, subject, body', () {
      final r = p('mailto:a@x.com,b@y.com?cc=c@x.com&bcc=d@x.com,e@x.com&subject=Hello%20World&body=Line1%0D%0ALine2');
      expect(r.to, ['a@x.com', 'b@y.com']);
      expect(r.cc, ['c@x.com']);
      expect(r.bcc, ['d@x.com', 'e@x.com']);
      expect(r.subject, 'Hello World');
      expect(r.body, 'Line1\nLine2');
    });

    test('to= header merges with path', () {
      expect(p('mailto:a@x.com?to=b@x.com').to, ['a@x.com', 'b@x.com']);
      expect(p('mailto:?to=b@x.com').to, ['b@x.com']);
    });

    test('percent-decoding incl. UTF-8, plus stays literal in values', () {
      final r = p('mailto:a%2Bb@x.com?subject=Caf%C3%A9%20%E2%9C%93&body=1+1%3D2');
      expect(r.to, ['a+b@x.com']);
      expect(r.subject, 'Café ✓');
      expect(r.body, '1+1=2');
    });

    test('scheme is case-insensitive; other schemes rejected', () {
      expect(MailtoRequest.parseString('MAILTO:a@x.com')!.to, ['a@x.com']);
      expect(MailtoRequest.parseString('https://example.com'), isNull);
      expect(MailtoRequest.parseString(''), isNull);
      expect(MailtoRequest.parse(Uri.parse('mailto:a@x.com?subject=Hi')) !.subject, 'Hi');
    });

    test('empty and malformed input does not throw', () {
      expect(p('mailto:').to, isEmpty);
      final r = p('mailto:a@x.com?subject=100%&body=%zz%41&&=x&novalue');
      expect(r.subject, '100%');
      expect(r.body, '%zzA');
    });

    test('header names are case-insensitive, fragment ignored, commas/semicolons', () {
      final r = p('mailto:a@x.com;b@x.com?Subject=S&CC=c@x.com#frag');
      expect(r.to, ['a@x.com', 'b@x.com']);
      expect(r.subject, 'S');
      expect(r.cc, ['c@x.com']);
    });

    test('mailto:// form', () {
      expect(p('mailto://a@x.com').to, ['a@x.com']);
    });
  });

  group('UrlEvents', () {
    test('buffers requests until someone listens', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final events = UrlEvents(channel: const MethodChannel('test/urls'));
      events.add(MailtoRequest.parseString('mailto:early@x.com')!);
      final got = <String>[];
      final sub = events.requests.listen((r) => got.add(r.to.first));
      await Future<void>.delayed(Duration.zero);
      events.add(MailtoRequest.parseString('mailto:late@x.com')!);
      await Future<void>.delayed(Duration.zero);
      expect(got, ['early@x.com', 'late@x.com']);
      await sub.cancel();
      events.dispose();
    });

    test('method call openUrl parses the URL', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('test/urls2');
      final events = UrlEvents(channel: channel);
      final first = events.requests.first;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        'test/urls2',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('openUrl', 'mailto:z@x.com?subject=Hi')),
        (_) {},
      );
      final r = await first;
      expect(r.to, ['z@x.com']);
      expect(r.subject, 'Hi');
      events.dispose();
    });
  });

  group('AppMenus', () {
    tearDown(() => AppMenus.debugForceEnabled = null);

    testWidgets('returns child unchanged off macOS', (tester) async {
      AppMenus.debugForceEnabled = false;
      await tester.pumpWidget(const MaterialApp(
        home: AppMenus(actions: AppMenuActions(), child: Text('hello')),
      ));
      expect(find.text('hello'), findsOneWidget);
      expect(find.byType(PlatformMenuBar), findsNothing);
    });

    testWidgets('renders child inside a PlatformMenuBar on macOS', (tester) async {
      AppMenus.debugForceEnabled = true;
      await tester.pumpWidget(const MaterialApp(
        home: AppMenus(actions: AppMenuActions(), child: Text('hello')),
      ));
      expect(find.text('hello'), findsOneWidget);
      expect(find.byType(PlatformMenuBar), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    test('exposes the Apple Mail style items; null callbacks disable', () {
      var replied = false;
      final menus = AppMenus.buildMenus(AppMenuActions(reply: () => replied = true));
      final labels = _labels(menus);
      for (final l in [
        'Hearthmail', 'File', 'Edit', 'View', 'Mailbox', 'Message', 'Window', 'Help',
        'About Hearthmail', 'Settings…', '<servicesSubmenu>', '<hide>', '<hideOtherApplications>',
        '<showAllApplications>', '<quit>', 'New Message', 'Print…', 'Undo', 'Redo', 'Cut', 'Copy',
        'Paste', 'Select All', 'Find', 'Hide Sidebar', 'Get All New Mail', 'New Mailbox…',
        'Rename Mailbox…', 'Delete Mailbox…', 'Reply', 'Reply All', 'Forward', 'Archive',
        'Move to Junk', 'Delete', 'Flag', 'Mark as Unread', 'Remind Me…', '<minimizeWindow>',
        '<zoomWindow>',
      ]) {
        expect(labels, contains(l));
      }
      PlatformMenuItem find(String label) {
        PlatformMenuItem? hit;
        void walk(List<PlatformMenuItem> l) {
          for (final i in l) {
            if (i is PlatformMenuItemGroup) {
              walk(i.members);
            } else if (i is PlatformMenu) {
              walk(i.menus);
            } else if (i.label == label) {
              hit = i;
            }
          }
        }

        walk(menus);
        return hit!;
      }

      expect(find('Reply').onSelected, isNotNull);
      find('Reply').onSelected!();
      expect(replied, isTrue);
      expect(find('Forward').onSelected, isNull);
      expect((find('Reply').shortcut! as SingleActivator).trigger, LogicalKeyboardKey.keyR);
    });

    test('sidebar label follows state', () {
      final labels = _labels(AppMenus.buildMenus(const AppMenuActions(sidebarVisible: false)));
      expect(labels, contains('Show Sidebar'));
      expect(labels, isNot(contains('Hide Sidebar')));
    });
  });

  group('print HTML', () {
    test('header block and body are assembled, scripts dropped', () {
      final out = buildPrintHtml(
        from: 'Ann <ann@x.com>',
        to: 'Bob <bob@x.com>',
        date: DateTime.utc(2026, 3, 4, 12),
        subject: 'Q1 <plan> & more',
        bodyDocument: '<html><head></head><body><p>Hi there</p><script>evil()</script>'
            '<details class="lm-quote"><summary>•••</summary>quoted</details></body></html>',
      );
      expect(out, contains('Q1 &lt;plan&gt; &amp; more'));
      expect(out, contains('From:'));
      expect(out, contains('Ann &lt;ann@x.com&gt;'));
      expect(out, contains('To:'));
      expect(out, isNot(contains('Cc:')));
      expect(out, contains('Date:'));
      expect(out, contains('Hi there'));
      expect(out, isNot(contains('evil()')));
      expect(out, contains('open'));
      expect(out.indexOf('lm-print-head"'), lessThan(out.indexOf('Hi there')));
    });

    test('printHtmlFor blocks remote images from a real message', () {
      final m = MimeMessage.parseFromText(
        'From: Ann <ann@x.com>\r\nTo: bob@x.com\r\nSubject: Hi\r\nDate: Wed, 4 Mar 2026 12:00:00 +0000\r\n'
        'Content-Type: text/html; charset=utf-8\r\n\r\n'
        '<p>Body</p><img src="https://tracker.example/p.png" width="200" height="100">',
      );
      final out = printHtmlFor(m);
      expect(out, contains('Body'));
      expect(out, contains('Ann'));
      expect(out, isNot(contains('https://tracker.example/p.png')));
      expect(out, isNot(contains('<script')));
    });
  });

  group('mailbox protection', () {
    Mailbox box(String name, List<MailboxFlag> flags) => Mailbox(
          encodedName: name,
          encodedPath: name,
          flags: flags,
          pathSeparator: '/',
        );

    test('special folders are protected, user folders are not', () {
      expect(MailService.isProtectedMailbox(box('INBOX', [MailboxFlag.inbox])), isTrue);
      expect(MailService.isProtectedMailbox(box('Sent', [MailboxFlag.sent])), isTrue);
      expect(MailService.isProtectedMailbox(box('Drafts', [MailboxFlag.drafts])), isTrue);
      expect(MailService.isProtectedMailbox(box('Trash', [MailboxFlag.trash])), isTrue);
      expect(MailService.isProtectedMailbox(box('Junk', [MailboxFlag.junk])), isTrue);
      expect(MailService.isProtectedMailbox(box('All Mail', [MailboxFlag.all])), isTrue);
      expect(MailService.isProtectedMailbox(box('Inbox', [])), isTrue);
      expect(MailService.isProtectedMailbox(box('Receipts', [])), isFalse);
    });

    test('child paths use the parent separator', () {
      final parent = Mailbox(encodedName: 'Work', encodedPath: 'Work', flags: [], pathSeparator: '.');
      expect(MailService.childPath('Q1', parent), 'Work.Q1');
      expect(MailService.childPath('Q1', null), 'Q1');
    });
  });
}

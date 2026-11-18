import 'package:flutter/gestures.dart';
// ignore_for_file: invalid_use_of_visible_for_testing_member
// Renders the real app screens with sample mail and canned AI output, and
// saves them as PNGs in screenshots/. No mail account or Ollama needed.
// Run: flutter test tool/screenshots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearthmail/main.dart';
import 'package:hearthmail/models/account_config.dart';
import 'package:hearthmail/models/triage.dart';
import 'package:hearthmail/services/ai/ai_provider.dart';
import 'package:hearthmail/services/ai/email_ai.dart';
import 'package:hearthmail/services/mail_service.dart';
import 'package:hearthmail/services/settings_store.dart';
import 'package:hearthmail/state/app_state.dart';
import 'package:hearthmail/ui/account_setup_page.dart';
import 'package:hearthmail/ui/compose_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CannedAi extends AiProvider {
  @override
  String get name => 'Canned';
  @override
  Future<List<String>> listModels() async => ['gemma4:12b-mlx'];
  @override
  Stream<String> chat(List<AiMessage> messages,
      {required String model, double temperature = 0.4, Map<String, dynamic>? jsonSchema}) async* {
    final sys = messages.first.content;
    if (jsonSchema != null && sys.startsWith('You brief a busy person')) {
      // One canned line per email, in the order the prompt lists them.
      final n = RegExp(r'^\[\d+\]', multiLine: true).allMatches(messages.last.content).length;
      const canned = [
        ('attention', 'Send Sarah the headcount and cloud forecast for the budget review.', 'reply', 'Thursday'),
        ('attention', 'Send Prof. Ruiz a revised proposal with two datasets.', 'reply', 'Monday Nov 23'),
        ('attention', 'Tell Mom which day your Thanksgiving flight lands.', 'reply', ''),
        ('fyi', 'Spring registration opens 30 November at 8 AM.', 'none', ''),
      ];
      final items = [
        for (var i = 0; i < n; i++)
          if (i < canned.length)
            '{"index": $i, "group": "${canned[i].$1}", "takeaway": "${canned[i].$2}", "action": "${canned[i].$3}", "due": "${canned[i].$4}"}'
          else
            '{"index": $i, "group": "skip", "takeaway": "A routine update.", "action": "none", "due": ""}',
      ];
      yield '{"items": [${items.join(', ')}]}';
      return;
    }
    if (jsonSchema != null && sys.contains('Suggest exactly 3')) {
      yield '{"replies": ["I\'ll have the headcount and cloud forecast to you by Thursday EOD, and I\'ll join Friday\'s meeting.", '
          '"Numbers coming Thursday. I\'ll dial in to Friday\'s review on Zoom.", '
          '"Quick question: should the cloud forecast cover Q1 as well, or just Q4?"]}';
      return;
    }
    yield '**TL;DR:** Sarah needs your team\'s headcount and cloud spend forecast by Thursday EOD for Friday\'s Q4 budget review.\n\n'
        '**Action items:**\n- Send updated headcount and cloud spend forecast by Thu, Nov 19\n- Join the budget review Fri 2pm (Room 4B or Zoom)\n\n'
        '**Key dates & numbers:**\n- Nov 19: data deadline\n- Nov 20, 2:00 PM: review meeting';
  }
}

final now = DateTime.now();
var _uid = 100;

MimeMessage mail(String name, String email, String subject, String body,
    {required Duration ago, bool seen = true, bool flagged = false}) {
  final b = MessageBuilder()
    ..from = [MailAddress(name, email)]
    ..to = [const MailAddress('Alex Rivera', 'alex@example.com')]
    ..subject = subject
    ..date = now.subtract(ago)
    ..text = body;
  final m = MimeMessage.parseFromText(b.buildMimeMessage().renderMessage());
  m.uid = _uid--;
  m.isSeen = seen;
  m.isFlagged = flagged;
  return m;
}

final key = GlobalKey();
final outDir = Directory('screenshots')..createSync();

Future<void> loadFonts() async {
  final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/homebrew/share/flutter'}/bin/cache/artifacts/material_fonts';
  Future<ByteData> f(String n) async => ByteData.sublistView(File('$fonts/$n').readAsBytesSync());
  final roboto = FontLoader('Roboto');
  for (final w in ['Regular', 'Medium', 'Bold', 'Light']) {
    roboto.addFont(f('Roboto-$w.ttf'));
  }
  await roboto.load();
  await (FontLoader('MaterialIcons')..addFont(f('MaterialIcons-Regular.otf'))).load();
}

Future<void> snap(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 300));
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('${outDir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<AppState> sampleState() async {
  SharedPreferences.setMockInitialValues({});
  final state = AppState(await SettingsStore.open());
  final messages = [
    mail('Sarah Chen', 'sarah.chen@acme-corp.com', 'Q4 budget review — need your numbers by Thursday',
        'Hi Alex,\n\nWe are finalizing the Q4 budget review with finance on Friday at 2pm. Could you send me your team\'s updated '
        'headcount and the cloud spend forecast by end of day Thursday (Nov 19)?\n\nAlso, can you join the Friday meeting? '
        'It is in room 4B, or on Zoom if you are remote.\n\nThanks!\nSarah',
        ago: const Duration(minutes: 40), seen: false),
    mail('Mom', 'linda@example.com', 'Thanksgiving plans?',
        'Hi beta, are you coming home for Thanksgiving? Let me know which day your flight lands so Dad can pick you up. Love, Mom',
        ago: const Duration(hours: 3), seen: false),
    mail('Amazon.com', 'shipment-tracking@amazon.com', 'Your package has shipped: Logitech MX Keys',
        'Your order #112-4482913 has shipped and will arrive Wednesday, November 18.', ago: const Duration(hours: 9)),
    mail('Delta Air Lines', 'deltaairlines@t.delta.com', 'Your trip confirmation: SFO → BOS, Nov 25',
        'Confirmation HX7Q2P. Flight DL 1432 departs SFO Wednesday Nov 25 at 7:05am, arrives BOS 3:41pm.',
        ago: const Duration(days: 1), flagged: true),
    mail('Chase', 'no-reply@chase.com', 'Your credit card statement is ready',
        'Your statement balance is \$1,284.33. Minimum payment of \$35 is due December 8, 2026.', ago: const Duration(days: 2)),
    mail('The Verge', 'newsletter@theverge.com', 'Verge Daily: The best gadgets of 2026',
        'Today: our picks for the best gadgets of the year, a review of the new Pixel, and why everyone is talking about local AI.',
        ago: const Duration(days: 2, hours: 5)),
    mail('GitHub', 'noreply@github.com', '[hearthmail] CI passed on main',
        'All checks have passed for commit 4f2a9c1.', ago: const Duration(days: 3)),
  ];
  Triage t(MailCategory c, MailPriority p, [bool reply = false]) =>
      Triage(category: c, priority: p, needsReply: reply);
  final triage = [
    t(MailCategory.work, MailPriority.high, true),
    t(MailCategory.personal, MailPriority.high, true),
    t(MailCategory.shopping, MailPriority.normal),
    t(MailCategory.travel, MailPriority.normal),
    t(MailCategory.finance, MailPriority.high),
    t(MailCategory.newsletter, MailPriority.low),
    t(MailCategory.notification, MailPriority.low),
  ];
  final uni = [
    mail('Prof. Elena Ruiz', 'eruiz@cs.university.edu', 'CS 6120 project proposal feedback',
        'Hi Alex,\n\nI read your proposal on local LLM email triage. Strong idea. Please narrow the evaluation to two datasets '
        'and send a revised version by Monday Nov 23.\n\nBest,\nProf. Ruiz',
        ago: const Duration(hours: 1), seen: false),
    mail('Registrar', 'registrar@university.edu', 'Spring 2027 registration opens Nov 30',
        'Your registration window opens Monday, November 30 at 8:00 AM.', ago: const Duration(hours: 20)),
  ];
  final side = [
    mail('Stripe', 'receipts@stripe.com', 'Your receipt from Figma #2231-0097',
        'Amount paid \$15.00. Figma Professional, monthly.', ago: const Duration(hours: 5)),
  ];
  Mailbox box(String name, String path, MailboxFlag f) =>
      Mailbox(encodedName: name, encodedPath: path, flags: [f], pathSeparator: '/');
  List<Mailbox> gmailBoxes() => [
        box('INBOX', 'INBOX', MailboxFlag.inbox),
        box('Drafts', '[Gmail]/Drafts', MailboxFlag.drafts),
        box('Sent Mail', '[Gmail]/Sent Mail', MailboxFlag.sent),
        box('All Mail', '[Gmail]/All Mail', MailboxFlag.all),
        box('Trash', '[Gmail]/Trash', MailboxFlag.trash),
      ];
  state.debugLoad(
    data: [
      (
        account: const AccountConfig(
            id: 'alex@example.com', email: 'alex@example.com', displayName: 'Alex Rivera', imapHost: 'imap.gmail.com', smtpHost: 'smtp.gmail.com'),
        mailboxes: gmailBoxes(),
        messages: messages,
        triage: {for (var i = 0; i < messages.length; i++) MailService.keyOf(messages[i], 'INBOX'): triage[i]},
      ),
      (
        account: const AccountConfig(
            id: 'alex@student.example.edu',
            email: 'alex@student.example.edu',
            displayName: 'Alex Rivera',
            imapHost: 'outlook.office365.com',
            smtpHost: 'smtp.office365.com',
            authType: AuthType.microsoft),
        mailboxes: [
          box('INBOX', 'INBOX', MailboxFlag.inbox),
          box('Sent Items', 'Sent Items', MailboxFlag.sent),
          box('Archive', 'Archive', MailboxFlag.archive),
          box('Deleted Items', 'Deleted Items', MailboxFlag.trash),
        ],
        messages: uni,
        triage: {
          MailService.keyOf(uni[0], 'INBOX'): t(MailCategory.work, MailPriority.high, true),
          MailService.keyOf(uni[1], 'INBOX'): t(MailCategory.notification, MailPriority.normal),
        },
      ),
      (
        account: const AccountConfig(
            id: 'alex.builds@example.com', email: 'alex.builds@example.com', displayName: 'Alex Rivera', imapHost: 'imap.gmail.com', smtpHost: 'smtp.gmail.com'),
        mailboxes: gmailBoxes(),
        messages: side,
        triage: {MailService.keyOf(side[0], 'INBOX'): t(MailCategory.finance, MailPriority.normal)},
      ),
    ],
    ai: EmailAi(provider: CannedAi(), fastModel: 'gemma4:12b-mlx', writingModel: 'gemma4:12b-mlx', userName: 'Alex Rivera'),
    selected: messages.first,
  );
  return state;
}

Widget app(AppState state, {Widget? home, Brightness brightness = Brightness.light}) =>
    ChangeNotifierProvider.value(
      value: state,
      child: RepaintBoundary(
        key: key,
        child: home == null
            ? const HearthmailApp()
            : MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: HearthmailApp.buildTheme(brightness),
                home: home,
              ),
      ),
    );

void main() {
  setUpAll(loadFonts);

  void size(WidgetTester tester, double w, double h) {
    tester.view.physicalSize = Size(w, h);
    tester.view.devicePixelRatio = 1;
  }

  testWidgets('home with AI summary and quick replies', (tester) async {
    size(tester, 1440, 900);
    final state = await sampleState();
    await tester.pumpWidget(app(state));
    await tester.tap(find.text('Summarize'));
    await tester.pump();
    await tester.tap(find.byTooltip('AI Tools'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quick Replies').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 50));
    await snap(tester, '1_home');
  });

  testWidgets('right-click menu on an email', (tester) async {
    size(tester, 1440, 900);
    final state = await sampleState();
    await tester.pumpWidget(app(state));
    final tile = find.text('Prof. Elena Ruiz');
    await tester.tap(tile, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    for (final label in ['Reply', 'Forward', 'Remind me…', 'Move to Junk', 'Add sender to VIPs', 'Block sender…']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await snap(tester, '8_context_menu');
    await tester.tap(find.text('Add sender to VIPs'));
    await tester.pumpAndSettle();
    expect(state.userData.vips, contains('eruiz@cs.university.edu'));
  });

  testWidgets('home in dark mode, priority view', (tester) async {
    size(tester, 1440, 900);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    final state = await sampleState();
    state.setView(const MailView.priority());
    await tester.pumpWidget(app(state));
    await snap(tester, '2_dark_priority');
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
  });

  testWidgets('composer with AI tools', (tester) async {
    size(tester, 1200, 800);
    final state = await sampleState();
    await tester.pumpWidget(app(state,
        home: const ComposePage(
            initialBody: 'Hi Mr. Patel,\n\nThe kitchen sink is leaking. Could you please arrange for a plumber to come by '
                'this week?\n\n- I\'m home any evening after **5pm**\n- The leak is under the sink, near the pipe joint\n\nThanks,\nAlex')));
    await tester.enterText(find.byType(TextField).first, 'Mr. Patel <landlord@example.com>');
    await snap(tester, '3_compose');
  });

  testWidgets('first-run account setup', (tester) async {
    size(tester, 1200, 800);
    final state = await sampleState();
    await tester.pumpWidget(app(state, home: const AccountSetupPage(isFirstRun: true)));
    await snap(tester, '4_setup');
    await tester.tap(find.text('Sign in with Microsoft'));
    await tester.pump();
    await snap(tester, '6_microsoft_setup');
  });

  testWidgets('composer replying from the university account', (tester) async {
    size(tester, 1200, 800);
    final state = await sampleState();
    final uniMail = state.sessions[1].inboxMessages.first;
    await tester.pumpWidget(app(state, home: ComposePage(replyTo: uniMail, initialBody: 'Hi Prof. Ruiz,\n\nThanks, will do.\n\nAlex')));
    await snap(tester, '7_reply_from_uni');
  });

  for (final (w, h) in [(1100.0, 760.0), (820.0, 640.0)]) {
    testWidgets('window at ${w.toInt()}×${h.toInt()} fits', (tester) async {
      size(tester, w, h);
      final state = await sampleState();
      await tester.pumpWidget(app(state));
      await tester.pump(const Duration(milliseconds: 100));
      await snap(tester, '9_window_${w.toInt()}');
    });
  }

  testWidgets('view options menu', (tester) async {
    size(tester, 1440, 900);
    final state = await sampleState();
    await tester.pumpWidget(app(state));
    await tester.tap(find.byTooltip('View Options'));
    await tester.pumpAndSettle();
    expect(find.text('Show Mail Categories'), findsOneWidget);
    await snap(tester, '10_view_options');
    await tester.tap(find.text('Show Mail Categories'));
    await tester.pumpAndSettle();
    expect(state.settings.showCategories, isTrue);
  });

  testWidgets('catch me up with actions', (tester) async {
    size(tester, 1440, 900);
    final state = await sampleState();
    await tester.pumpWidget(app(state));
    await tester.tap(find.byTooltip('Catch me up'));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Needs You'), findsOneWidget);
    expect(find.text('Reply'), findsWidgets);
    await snap(tester, '11_catch_up');
  });

  testWidgets('phone-width layout', (tester) async {
    size(tester, 390, 844);
    final state = await sampleState();
    state.selected = null;
    await tester.pumpWidget(app(state));
    await snap(tester, '5_phone');
  });
}

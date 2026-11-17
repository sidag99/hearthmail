// Live check of every AI feature against the local Ollama server.
// Run: dart run tool/ai_smoke.dart [model]
import 'dart:io';

import 'package:hearthmail/models/email_content.dart';
import 'package:hearthmail/services/ai/email_ai.dart';
import 'package:hearthmail/services/ai/ollama_provider.dart';

final emails = [
  EmailContent(
    id: 'a',
    from: 'Sarah Chen <sarah.chen@acme-corp.com>',
    subject: 'Q4 budget review — need your numbers by Thursday',
    date: DateTime(2026, 11, 16, 9, 30),
    isUnread: true,
    body: 'Hi Alex,\n\nWe are finalizing the Q4 budget review with finance on Friday at 2pm. '
        'Could you send me your team\'s updated headcount and the cloud spend forecast by end of day Thursday (Nov 19)? '
        'Also, can you join the Friday meeting? It is in room 4B, or on Zoom if you are remote.\n\n'
        'Thanks!\nSarah',
  ),
  EmailContent(
    id: 'b',
    from: 'Amazon.com <shipment-tracking@amazon.com>',
    subject: 'Your package has shipped: Logitech MX Keys',
    date: DateTime(2026, 11, 15),
    body: 'Your order #112-4482913 has shipped and will arrive Wednesday, November 18. Track your package in Your Orders.',
  ),
  EmailContent(
    id: 'c',
    from: 'The Verge <newsletter@theverge.com>',
    subject: 'Verge Daily: The best gadgets of 2026',
    date: DateTime(2026, 11, 16),
    body: 'Today: our picks for the best gadgets of the year, a review of the new Pixel, and why everyone is talking about local AI. Unsubscribe anytime.',
  ),
  EmailContent(
    id: 'd',
    from: 'Chase <no-reply@chase.com>',
    subject: 'Your credit card statement is ready',
    date: DateTime(2026, 11, 14),
    body: 'Your statement balance is \$1,284.33. Minimum payment of \$35 is due December 8, 2026.',
  ),
  EmailContent(
    id: 'e',
    from: 'Mom <linda@example.com>',
    subject: 'Thanksgiving plans?',
    date: DateTime(2026, 11, 13),
    isUnread: true,
    body: 'Hi beta, are you coming home for Thanksgiving? Let me know which day your flight lands so Dad can pick you up. Love, Mom',
  ),
  EmailContent(
    id: 'f',
    from: 'Delta Air Lines <deltaairlines@t.delta.com>',
    subject: 'Your trip confirmation: SFO → BOS, Nov 25',
    date: DateTime(2026, 11, 10),
    body: 'Confirmation number HX7Q2P. Flight DL 1432 departs San Francisco (SFO) Wednesday Nov 25 at 7:05am, arrives Boston (BOS) 3:41pm.',
  ),
];

Future<void> main(List<String> args) async {
  final provider = OllamaProvider();
  final models = await provider.listModels();
  stdout.writeln('Models: $models');
  final model = args.isNotEmpty ? args.first : models.first;
  final ai = EmailAi(
    provider: provider,
    fastModel: model,
    writingModel: model,
    userName: 'Alex Rivera',
    clock: () => DateTime(2026, 11, 17, 10),
  );
  stdout.writeln('Using $model\n');

  Future<void> step(String name, Future<Object?> Function() f) async {
    final sw = Stopwatch()..start();
    try {
      final r = await f();
      stdout.writeln('=== $name (${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s)\n$r\n');
    } catch (e) {
      stdout.writeln('=== $name FAILED: $e\n');
      exitCode = 1;
    }
  }

  await step('warm-up', () => ai.suggestSubject('Hello, lunch tomorrow?'));
  await step('summarize', () => ai.summarize(emails[0]).join());
  await step('quick replies', () => ai.quickReplies(emails[0]));
  await step('draft reply', () => ai.draftReply(emails[0], instruction: 'yes to the numbers, but I can only join Friday on zoom').join());
  await step('triage', () async {
    final r = await ai.triage(emails);
    return r.entries.map((e) => '${e.key}: ${e.value.category.name}, ${e.value.priority.name}, reply=${e.value.needsReply}').join('\n');
  });
  await step('plan search', () async {
    final p = await ai.planSearch('when does my flight to boston leave');
    return '${p.describe()}\nIMAP: ${p.toImapCriteria()}\nGmail: ${p.toGmailQuery()}';
  });
  await step('plan search 2', () async {
    final p = await ai.planSearch('bills from chase last month');
    return '${p.describe()}\nIMAP: ${p.toImapCriteria()}';
  });
  await step('rank', () => ai.rankResults('when does my flight to boston leave', emails));
  await step('answer', () => ai.answerFromEmails('when does my flight to boston leave', [emails[5], emails[4]]).join());
  await step('compose', () => ai.compose('tell landlord the kitchen sink leaks, ask for plumber this week, I am home after 5pm', to: 'Mr. Patel').join());
  await step('rewrite formal', () => ai.rewrite('hey can u send me the doc asap, need it for tmrw thx', RewriteStyle.formal).join());
  await step('digest', () => ai.digest(emails).join());
  provider.close();
}

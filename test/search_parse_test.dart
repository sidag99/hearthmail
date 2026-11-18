import 'package:flutter_test/flutter_test.dart';
import 'package:hearthmail/models/search_plan.dart';

void main() {
  test('typed words must all match', () {
    final p = SearchPlan.parse('invoice march');
    expect(p.keywords, ['invoice', 'march']);
    expect(p.toImapCriteria(), 'TEXT "invoice" TEXT "march"');
    expect(p.toGmailQuery(), 'invoice march');
  });

  test('operators and phrases', () {
    final p = SearchPlan.parse('from:sarah subject:"Q4 budget" has:attachment is:unread after:2026-11-01 "cloud spend"');
    expect(p.from, 'sarah');
    expect(p.subject, 'Q4 budget');
    expect(p.hasAttachment, isTrue);
    expect(p.unreadOnly, isTrue);
    expect(p.since, DateTime(2026, 11, 1));
    expect(p.keywords, ['cloud spend']);
    expect(p.toImapCriteria(), contains('FROM "sarah"'));
    expect(p.toImapCriteria(), contains('SUBJECT "Q4 budget"'));
  });

  test('a colon that is not an operator stays a word', () {
    expect(SearchPlan.parse('meeting 10:30').keywords, ['meeting', '10:30']);
  });
}

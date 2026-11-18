import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearthmail/services/mail_service.dart';

Mailbox box(String name, [List<MailboxFlag> flags = const []]) =>
    Mailbox(encodedName: name, encodedPath: name, flags: flags, pathSeparator: '/');

void main() {
  test('finds mailboxes by special-use flag first', () {
    final boxes = [box('INBOX', [MailboxFlag.inbox]), box('Sent'), box('Gesendet', [MailboxFlag.sent])];
    expect(MailService.roleMailbox(boxes, MailboxRole.sent)?.name, 'Gesendet');
    expect(MailService.roleMailbox(boxes, MailboxRole.inbox)?.name, 'INBOX');
  });

  test('falls back to the usual names', () {
    final boxes = [box('INBOX', [MailboxFlag.inbox]), box('Deleted Items'), box('Junk E-mail'), box('Drafts')];
    expect(MailService.roleMailbox(boxes, MailboxRole.trash)?.name, 'Deleted Items');
    expect(MailService.roleMailbox(boxes, MailboxRole.junk)?.name, 'Junk E-mail');
    expect(MailService.roleMailbox(boxes, MailboxRole.drafts)?.name, 'Drafts');
    expect(MailService.roleMailbox(boxes, MailboxRole.archive), isNull);
  });

  test('sent mail lists its recipients', () {
    final m = MimeMessage()
      ..to = [const MailAddress('Sam Lee', 'sam@example.com'), const MailAddress(null, 'jo@example.com')];
    expect(MailService.recipientNames(m), 'Sam Lee, jo@example.com');
    expect(MailService.recipientNames(MimeMessage()), 'No Recipients');
  });
}

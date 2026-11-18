import 'package:flutter_test/flutter_test.dart';
import 'package:hearthmail/services/mail_service.dart';

void main() {
  test('typed line breaks are kept', () {
    final h = MailService.bodyToHtml('Hi Sam,\n\nThanks!\nAlex\n-- \nAlex Rivera\n123 Main St');
    expect(h, contains('Thanks!<br />\nAlex'));
    expect(h, contains('Alex Rivera<br />\n123 Main St'));
  });

  test('lists and bold still format', () {
    final h = MailService.bodyToHtml('Plan:\n- one\n- **two**');
    expect(h, contains('<li>one</li>'));
    expect(h, contains('<strong>two</strong>'));
  });

  test('typed HTML is shown as text', () {
    final h = MailService.bodyToHtml('Use <b>tags</b> and <script>alert(1)</script> please');
    expect(h, isNot(contains('<script>')));
    expect(h, isNot(contains('<b>')));
  });
}

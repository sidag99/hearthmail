import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearthmail/models/triage.dart';
import 'package:hearthmail/services/mail_service.dart';
import 'package:hearthmail/services/message_cache.dart';
import 'package:hearthmail/services/notification_rules.dart';
import 'package:hearthmail/services/settings_store.dart';

MimeMessage msg(int uid, {String body = 'Hello there', List<String> flags = const [], int day = 1, String? subject}) {
  final m = MimeMessage.parseFromText(
    'From: Ann <ann@example.com>\r\nTo: me@example.com\r\nSubject: ${subject ?? 'Message $uid'}\r\n'
    'Message-ID: <$uid@example.com>\r\nDate: Mon, ${day.toString().padLeft(2, '0')} Jun 2026 10:00:00 +0000\r\n'
    'Content-Type: text/plain; charset=utf-8\r\n\r\n$body\r\n',
  );
  m.uid = uid;
  m.flags = [...flags];
  return m;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('hm_cache_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('MessageCache', () {
    test('round-trips messages, uid, flags and metadata', () async {
      final cache = await MessageCache.open('acc', dir: dir);
      await cache.save(
        [msg(7, flags: [MessageFlags.seen, MessageFlags.flagged], day: 2), msg(5, day: 1)],
        uidValidity: 42,
        path: 'INBOX',
      );
      final back = await (await MessageCache.open('acc', dir: dir)).load();
      expect(back.uidValidity, 42);
      expect(back.path, 'INBOX');
      expect(back.messages.map((m) => m.uid), [7, 5]);
      final first = back.messages.first;
      expect(first.isSeen, isTrue);
      expect(first.isFlagged, isTrue);
      expect(back.messages.last.isSeen, isFalse);
      expect(first.decodeSubject(), 'Message 7');
      expect(first.decodeTextPlainPart(), contains('Hello there'));
      expect(MailService.senderOf(first)?.email, 'ann@example.com');
      expect(MailService.hasBody(first), isTrue);
      expect(MailService.keyOf(first, 'INBOX'), '<7@example.com>');
    });

    test('keeps only headers for bodies over the size limit', () async {
      final cache = await MessageCache.open('acc', dir: dir, maxBodyBytes: 1000);
      await cache.save([msg(1, body: 'x' * 5000), msg(2)]);
      final back = (await cache.load()).messages;
      final big = back.firstWhere((m) => m.uid == 1);
      final small = back.firstWhere((m) => m.uid == 2);
      expect(MessageCache.isStub(big), isTrue);
      expect(MailService.hasBody(big), isFalse); // so opening it fetches the body
      expect(big.decodeSubject(), 'Message 1');
      expect(MailService.senderOf(big)?.email, 'ann@example.com');
      expect(big.decodeDate(), isNotNull);
      expect(MessageCache.isStub(small), isFalse);
      expect(MailService.hasBody(small), isTrue);
    });

    test('envelope-only messages keep sender, subject and date', () async {
      final m = MimeMessage.fromEnvelope(
        Envelope(
          date: DateTime.utc(2026, 6, 3, 8),
          subject: 'Big one',
          from: [const MailAddress('Bob', 'bob@example.com')],
          messageId: '<big@example.com>',
        ),
        uid: 9,
        flags: [],
      );
      final cache = await MessageCache.open('acc', dir: dir);
      await cache.save([m]);
      final back = (await cache.load()).messages.single;
      expect(MessageCache.isStub(back), isTrue);
      expect(MailService.senderOf(back)?.email, 'bob@example.com');
      expect(MailService.subjectOf(back), 'Big one');
      expect(back.decodeDate()?.toUtc(), DateTime.utc(2026, 6, 3, 8));
    });

    test('evicts the oldest beyond maxMessages', () async {
      final cache = await MessageCache.open('acc', dir: dir, maxMessages: 3);
      await cache.save([for (var i = 1; i <= 6; i++) msg(i, day: i)]);
      final back = (await cache.load()).messages;
      expect(back.map((m) => m.uid), [6, 5, 4]);
    });

    test('flag changes are written without losing the body', () async {
      final cache = await MessageCache.open('acc', dir: dir);
      final m = msg(3);
      await cache.save([m]);
      m.isSeen = true;
      await cache.save([m]);
      final back = (await cache.load()).messages.single;
      expect(back.isSeen, isTrue);
      expect(MailService.hasBody(back), isTrue);
    });

    test('removed messages disappear on the next save; clear deletes the file', () async {
      final cache = await MessageCache.open('acc', dir: dir);
      final a = msg(1), b = msg(2);
      await cache.save([a, b]);
      await cache.save([b]);
      expect((await cache.load()).messages.map((m) => m.uid), [2]);
      await cache.clear();
      expect((await cache.load()).messages, isEmpty);
      expect(dir.listSync(), isEmpty);
    });

    test('a corrupt file is an empty cache', () async {
      final cache = await MessageCache.open('acc', dir: dir);
      await cache.save([msg(1)]);
      for (final f in dir.listSync().whereType<File>()) {
        f.writeAsStringSync('{not json');
      }
      expect((await cache.load()).messages, isEmpty);
    });
  });

  group('shouldNotify', () {
    bool ok({
      bool enabled = true,
      bool seen = false,
      bool muted = false,
      bool blocked = false,
      MailCategory? category,
      DateTime? received,
    }) =>
        shouldNotify(
          enabled: enabled,
          isSeen: seen,
          isMuted: muted,
          isBlocked: blocked,
          category: category,
          received: received,
          now: DateTime.utc(2026, 6, 2, 12),
        );

    test('notifies for plain unread mail', () => expect(ok(), isTrue));
    test('respects the setting', () => expect(ok(enabled: false), isFalse));
    test('skips read, muted and blocked', () {
      expect(ok(seen: true), isFalse);
      expect(ok(muted: true), isFalse);
      expect(ok(blocked: true), isFalse);
    });
    test('skips promotions and newsletters only', () {
      expect(ok(category: MailCategory.promotion), isFalse);
      expect(ok(category: MailCategory.newsletter), isFalse);
      expect(ok(category: MailCategory.personal), isTrue);
      expect(ok(category: MailCategory.finance), isTrue);
    });
    test('skips mail older than a day', () {
      expect(ok(received: DateTime.utc(2026, 6, 2, 8)), isTrue);
      expect(ok(received: DateTime.utc(2026, 5, 30)), isFalse);
    });
    test('payload round-trips, even with odd account ids', () {
      for (final id in ['acc1', 'a|b', '1|2|3']) {
        final p = parseNotificationPayload(notificationPayload(id, 77));
        expect(p?.accountId, id);
        expect(p?.uid, 77);
      }
      expect(parseNotificationPayload(null), isNull);
      expect(parseNotificationPayload('garbage'), isNull);
      expect(parseNotificationPayload('x|acc'), isNull);
    });
  });

  test('AppSettings.notifications defaults on and survives JSON and copyWith', () {
    const s = AppSettings();
    expect(s.notifications, isTrue);
    final off = s.copyWith(notifications: false);
    expect(off.notifications, isFalse);
    expect(AppSettings.fromJson(off.toJson()).notifications, isFalse);
    expect(AppSettings.fromJson(<String, dynamic>{}).notifications, isTrue);
  });
}

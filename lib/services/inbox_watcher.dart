import 'dart:async';
import 'dart:math';

import 'package:enough_mail/enough_mail.dart';

import 'mail_service.dart';

/// Watches one account's Inbox for changes using IMAP IDLE (enough_mail's
/// `startPolling` uses IDLE when the server supports it, and falls back to
/// periodic polling otherwise).
///
/// It runs on its own connection, so it never blocks the account's main,
/// serialized connection. When something happens it only calls
/// [onActivity]; the app then runs its normal refresh.
class InboxWatcher {
  InboxWatcher({
    required this.connect,
    required this.onActivity,
    this.lostGrace = const Duration(seconds: 90),
    this.minBackoff = const Duration(seconds: 5),
    this.maxBackoff = const Duration(minutes: 5),
  });

  /// Creates a fresh, not yet connected service for this account (or null
  /// if credentials are unavailable).
  final Future<MailService?> Function() connect;
  final void Function() onActivity;

  /// How long the library may try to reconnect on its own before the
  /// watcher throws the connection away and starts over.
  final Duration lostGrace;
  final Duration minBackoff;
  final Duration maxBackoff;

  bool _stopped = true;
  MailService? _service;
  StreamSubscription<MailEvent>? _sub;
  Timer? _graceTimer;
  Completer<void>? _restart;

  bool get running => !_stopped;

  void start() {
    if (!_stopped) return;
    _stopped = false;
    unawaited(_loop());
  }

  Future<void> stop() async {
    _stopped = true;
    _graceTimer?.cancel();
    final r = _restart;
    if (r != null && !r.isCompleted) r.complete();
    await _teardown();
  }

  Future<void> _teardown() async {
    await _sub?.cancel();
    _sub = null;
    final svc = _service;
    _service = null;
    if (svc != null) {
      try {
        await svc.client.stopPollingIfNeeded();
      } catch (_) {}
      await svc.disconnect();
    }
  }

  Future<void> _loop() async {
    var backoff = minBackoff;
    while (!_stopped) {
      final restart = _restart = Completer<void>();
      try {
        final svc = await connect();
        if (svc == null || _stopped) {
          await svc?.disconnect();
          if (svc == null) throw StateError('no credentials');
          return;
        }
        _service = svc;
        await svc.connect();
        await svc.client.selectInbox();
        _sub = svc.client.eventStream.listen((e) {
          if (e is MailLoadEvent || e is MailVanishedEvent || e is MailUpdateEvent) {
            onActivity();
          } else if (e is MailConnectionLostEvent) {
            // The library retries on its own; give it a while.
            _graceTimer?.cancel();
            _graceTimer = Timer(lostGrace, () {
              if (!restart.isCompleted) restart.complete();
            });
          } else if (e is MailConnectionReEstablishedEvent) {
            _graceTimer?.cancel();
            onActivity(); // catch up on whatever arrived meanwhile
          }
        });
        await svc.client.startPolling();
        backoff = minBackoff;
        await restart.future;
      } catch (_) {
        // Fall through to back off and retry.
      }
      _graceTimer?.cancel();
      await _teardown();
      if (_stopped) return;
      await Future<void>.delayed(backoff);
      backoff = Duration(seconds: min(backoff.inSeconds * 2, maxBackoff.inSeconds));
    }
  }
}

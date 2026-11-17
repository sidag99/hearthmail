import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A parsed `mailto:` URL (RFC 6068).
@immutable
class MailtoRequest {
  const MailtoRequest({
    this.to = const [],
    this.cc = const [],
    this.bcc = const [],
    this.subject = '',
    this.body = '',
  });

  final List<String> to;
  final List<String> cc;
  final List<String> bcc;
  final String subject;
  final String body;

  /// Parses `mailto:a@x.com,b@y.com?cc=…&subject=…&body=…`. Returns null for
  /// other schemes. Never throws: malformed percent-escapes are kept literally.
  static MailtoRequest? parse(Uri uri) => parseString(uri.toString());

  static MailtoRequest? parseString(String raw) {
    final text = raw.trim();
    if (text.length < 7 || text.substring(0, 7).toLowerCase() != 'mailto:') return null;
    var rest = text.substring(7);
    // Some senders write mailto://addr.
    if (rest.startsWith('//')) rest = rest.substring(2);
    final hash = rest.indexOf('#');
    if (hash >= 0) rest = rest.substring(0, hash);
    final q = rest.indexOf('?');
    final path = q < 0 ? rest : rest.substring(0, q);
    final query = q < 0 ? '' : rest.substring(q + 1);

    final to = <String>[..._addresses(path)];
    final cc = <String>[];
    final bcc = <String>[];
    var subject = '';
    var body = '';
    for (final pair in query.split('&')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      final key = _decode(eq < 0 ? pair : pair.substring(0, eq)).toLowerCase();
      final value = eq < 0 ? '' : pair.substring(eq + 1);
      switch (key) {
        case 'to':
          to.addAll(_addresses(value));
        case 'cc':
          cc.addAll(_addresses(value));
        case 'bcc':
          bcc.addAll(_addresses(value));
        case 'subject':
          subject = _decode(value);
        case 'body':
          // RFC 6068: line breaks are %0D%0A; normalize to \n.
          body = _decode(value).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      }
    }
    return MailtoRequest(to: to, cc: cc, bcc: bcc, subject: subject, body: body);
  }

  static List<String> _addresses(String encoded) => [
        for (final part in _decode(encoded).split(RegExp(r'[,;]')))
          if (part.trim().isNotEmpty) part.trim(),
      ];

  /// Percent-decoding as UTF-8. A `+` stays literal (RFC 6068 is not form
  /// encoding). Invalid escapes are kept as typed.
  static String _decode(String s) {
    final out = <int>[];
    for (var i = 0; i < s.length;) {
      if (s.codeUnitAt(i) == 0x25 && i + 2 < s.length) {
        final v = int.tryParse(s.substring(i + 1, i + 3), radix: 16);
        if (v != null) {
          out.add(v);
          i += 3;
          continue;
        }
      }
      // Copy the rune as UTF-8.
      final end = (s.codeUnitAt(i) >= 0xD800 && s.codeUnitAt(i) <= 0xDBFF && i + 1 < s.length) ? i + 2 : i + 1;
      out.addAll(utf8.encode(s.substring(i, end)));
      i = end;
    }
    return utf8.decode(out, allowMalformed: true);
  }

  @override
  bool operator ==(Object other) =>
      other is MailtoRequest &&
      listEquals(to, other.to) &&
      listEquals(cc, other.cc) &&
      listEquals(bcc, other.bcc) &&
      subject == other.subject &&
      body == other.body;

  @override
  int get hashCode => Object.hash(Object.hashAll(to), Object.hashAll(cc), Object.hashAll(bcc), subject, body);

  @override
  String toString() => 'MailtoRequest(to: $to, cc: $cc, bcc: $bcc, subject: $subject)';
}

/// URLs the OS hands to the app (mailto: links), delivered over the
/// `hearthmail/urls` channel. URLs that arrive before anyone listens (cold
/// launch via a link) are buffered and replayed to the first listener.
class UrlEvents {
  UrlEvents({MethodChannel? channel}) : _channel = channel ?? const MethodChannel(_channelName) {
    _channel.setMethodCallHandler(_onCall);
    _controller = StreamController<MailtoRequest>(onListen: _flush);
  }

  static const _channelName = 'hearthmail/urls';

  final MethodChannel _channel;
  late final StreamController<MailtoRequest> _controller;
  final _pending = <MailtoRequest>[];

  /// Single-subscription stream; anything buffered is replayed on listen.
  Stream<MailtoRequest> get requests => _controller.stream;

  /// Tells the native side Dart is ready, so it sends URLs queued at launch.
  /// Call once after creating the instance.
  Future<void> start() async {
    try {
      await _channel.invokeMethod<void>('ready');
    } on MissingPluginException {
      // Not on macOS.
    } on PlatformException {
      // Ignore: nothing queued.
    }
  }

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method != 'openUrl') return null;
    final arg = call.arguments;
    final req = arg is String ? MailtoRequest.parseString(arg) : null;
    if (req == null) return false;
    add(req);
    return true;
  }

  /// Feeds a request in (also used by tests).
  void add(MailtoRequest req) {
    if (_controller.hasListener) {
      _controller.add(req);
    } else {
      _pending.add(req);
    }
  }

  void _flush() {
    final queued = List.of(_pending);
    _pending.clear();
    for (final r in queued) {
      _controller.add(r);
    }
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    _controller.close();
  }
}

Future<bool> _invokeBool(String method) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return false;
  try {
    return await const MethodChannel(UrlEvents._channelName).invokeMethod<bool>(method) ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// Makes Hearthmail the default handler for mailto: links (macOS 12+).
Future<bool> setAsDefaultMailApp() => _invokeBool('setDefaultMailApp');

/// Whether Hearthmail is currently the default mailto: handler.
Future<bool> isDefaultMailApp() => _invokeBool('isDefaultMailApp');

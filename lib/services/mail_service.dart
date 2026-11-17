import 'dart:io';
import 'dart:math';

import 'package:enough_mail/enough_mail.dart';
import 'package:markdown/markdown.dart' as md;

import '../models/account_config.dart';
import '../models/email_content.dart';
import '../models/search_plan.dart';
import 'html_text.dart';
import 'oauth.dart';

/// How an account proves who it is.
sealed class MailCredentials {
  const MailCredentials();
}

class PasswordCredentials extends MailCredentials {
  const PasswordCredentials(this.password);
  final String password;
}

class OAuthCredentials extends MailCredentials {
  const OAuthCredentials(this.token, this.client, {this.onTokenRefreshed});
  final OauthToken token;
  final OAuthClient client;

  /// Called with each refreshed token so it can be saved.
  final Future<void> Function(OauthToken token)? onTokenRefreshed;
}

/// Everything that talks to one account's mail server (IMAP to read, SMTP
/// to send).
///
/// IMAP acts on whichever folder is currently selected, so every operation
/// names its folder and runs one at a time. Otherwise a background refresh
/// of the Inbox could slip in between "select Sent" and "delete message 12",
/// and the wrong message would be deleted.
class MailService {
  MailService(this.config, MailCredentials credentials)
      : client = MailClient(
          _account(config, credentials),
          // Messages up to this size are downloaded whole when listing, so
          // previews and AI sorting work without extra round trips.
          downloadSizeLimit: 256 * 1024,
          defaultResponseTimeout: const Duration(seconds: 30),
          defaultWriteTimeout: const Duration(seconds: 10),
          refresh: credentials is OAuthCredentials
              ? (_, expired) => credentials.client.refresh(expired.refreshToken)
              : null,
          onConfigChanged: credentials is OAuthCredentials
              ? (account) async {
                  final auth = account.incoming.authentication;
                  if (auth is OauthAuthentication) {
                    await credentials.onTokenRefreshed?.call(auth.token);
                  }
                }
              : null,
        );

  static MailAccount _account(AccountConfig c, MailCredentials cred) {
    final name = c.displayName.isEmpty ? c.email : c.displayName;
    final inSocket = c.imapUsesStartTls ? SocketType.starttls : SocketType.ssl;
    final outSocket = c.smtpUsesStartTls ? SocketType.starttls : SocketType.ssl;
    return switch (cred) {
      PasswordCredentials(:final password) => MailAccount.fromManualSettings(
          name: name,
          email: c.email,
          userName: c.displayName,
          loginName: c.loginName,
          password: password,
          incomingHost: c.imapHost,
          incomingPort: c.imapPort,
          incomingSocketType: inSocket,
          outgoingHost: c.smtpHost,
          outgoingPort: c.smtpPort,
          outgoingSocketType: outSocket,
          outgoingClientDomain: 'localhost',
        ),
      OAuthCredentials(:final token) => MailAccount.fromManualSettingsWithAuth(
          name: name,
          email: c.email,
          userName: c.displayName,
          auth: OauthAuthentication(c.loginName, token),
          incomingHost: c.imapHost,
          incomingPort: c.imapPort,
          incomingSocketType: inSocket,
          outgoingHost: c.smtpHost,
          outgoingPort: c.smtpPort,
          outgoingSocketType: outSocket,
          outgoingClientDomain: 'localhost',
        ),
    };
  }

  final AccountConfig config;
  final MailClient client;

  MailAddress get me => MailAddress(
      config.displayName.isEmpty ? null : config.displayName, config.email);

  Future<void> _tail = Future.value();

  /// Runs [op] after every earlier operation on this account has finished.
  /// If the connection dropped (sleep, Wi-Fi change), reconnects once and retries.
  Future<T> _serial<T>(Future<T> Function() op) {
    Future<T> run() async {
      try {
        return await op();
      } catch (e) {
        if (!_looksLikeConnectionLoss(e)) rethrow;
        await _reconnect();
        return op();
      }
    }

    final result = _tail.then((_) => run());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  static bool _looksLikeConnectionLoss(Object e) {
    final s = e.toString().toLowerCase();
    return e is SocketException ||
        s.contains('connection') ||
        s.contains('socket') ||
        s.contains('not connected') ||
        s.contains('broken pipe') ||
        s.contains('closed');
  }

  Future<void> _reconnect() async {
    try {
      await client.disconnect();
    } catch (_) {}
    await client.connect(timeout: const Duration(seconds: 30));
  }

  Future<Mailbox> _ensure(Mailbox box) async {
    final current = client.selectedMailbox;
    if (current != null && current.path == box.path) return current;
    return client.selectMailbox(box);
  }

  Future<void> connect() => client.connect(timeout: const Duration(seconds: 30));

  Future<void> disconnect() async {
    try {
      await client.disconnect();
    } catch (_) {}
  }

  /// Folders in a sensible order (Inbox, Drafts, Sent, …, then the rest).
  Future<List<Mailbox>> mailboxes() => _serial(() async {
        final boxes = await client.listMailboxes(order: const [
          MailboxFlag.inbox,
          MailboxFlag.flagged,
          MailboxFlag.drafts,
          MailboxFlag.sent,
          MailboxFlag.archive,
          MailboxFlag.all,
          MailboxFlag.junk,
          MailboxFlag.trash,
        ]);
        return boxes.where((b) => !b.isNotSelectable).toList();
      });

  /// Newest messages first. [page] starts at 1.
  Future<List<MimeMessage>> fetchPage(Mailbox box, {int page = 1, int count = 40}) => _serial(() async {
        // Always re-select so the message count is current.
        final selected = await client.selectMailbox(box);
        if (selected.messagesExists == 0) return <MimeMessage>[];
        final maxPage = (selected.messagesExists / count).ceil();
        if (page > maxPage) return <MimeMessage>[];
        final msgs = await client.fetchMessages(
          mailbox: selected,
          count: count,
          page: page,
          fetchPreference: FetchPreference.fullWhenWithinSize,
        );
        msgs.sort((a, b) => _date(b).compareTo(_date(a)));
        return msgs;
      });

  /// Downloads the full body of a message that was only partially fetched.
  Future<MimeMessage> ensureFull(Mailbox box, MimeMessage m) async {
    if (hasBody(m)) return m;
    return _serial(() async {
      await _ensure(box);
      return client.fetchMessageContents(m, responseTimeout: const Duration(seconds: 60));
    });
  }

  static bool hasBody(MimeMessage m) =>
      m.decodeTextPlainPart() != null || m.decodeTextHtmlPart() != null;

  /// The folder to search for "all my mail": Gmail's All Mail if present.
  Mailbox? searchFolder(List<Mailbox> boxes) {
    if (config.isGmail) {
      for (final b in boxes) {
        if (b.hasFlag(MailboxFlag.all)) return b;
      }
    }
    for (final b in boxes) {
      if (b.isInbox) return b;
    }
    return boxes.isEmpty ? null : boxes.first;
  }

  /// Server-side search in [box]. On Gmail it uses Gmail's own search
  /// engine (X-GM-RAW); elsewhere standard IMAP SEARCH.
  Future<List<MimeMessage>> search(Mailbox box, SearchPlan plan, {int limit = 40}) => _serial(() async {
        await _ensure(box);
        final imap = client.lowLevelIncomingMailClient as ImapClient;
        final String criteria;
        if (config.isGmail && !plan.isEmpty) {
          final raw = plan.toGmailQuery().replaceAll(r'\', '').replaceAll('"', r'\"');
          criteria = 'X-GM-RAW "$raw"';
        } else {
          criteria = plan.toImapCriteria();
        }
        final result = await imap.uidSearchMessages(
          searchCriteria: criteria,
          responseTimeout: const Duration(seconds: 60),
        );
        final ids = result.matchingSequence?.toList() ?? const <int>[];
        if (ids.isEmpty) return <MimeMessage>[];
        final newest = [...ids]..sort();
        final picked = newest.sublist(max(0, newest.length - limit));
        final msgs = await client.fetchMessageSequence(
          MessageSequence.fromIds(picked, isUid: true),
          mailbox: box,
          fetchPreference: FetchPreference.fullWhenWithinSize,
        );
        msgs.sort((a, b) => _date(b).compareTo(_date(a)));
        return msgs;
      });

  Future<void> setSeen(Mailbox box, MimeMessage m, bool seen) => _serial(() async {
        await _ensure(box);
        final seq = MessageSequence.fromMessage(m);
        seen ? await client.markSeen(seq) : await client.markUnseen(seq);
        m.isSeen = seen;
      });

  Future<void> setFlagged(Mailbox box, MimeMessage m, bool flagged) => _serial(() async {
        await _ensure(box);
        final seq = MessageSequence.fromMessage(m);
        flagged ? await client.markFlagged(seq) : await client.markUnflagged(seq);
        m.isFlagged = flagged;
      });

  Future<void> delete(Mailbox box, MimeMessage m) => _serial(() async {
        await _ensure(box);
        await client.deleteMessage(m);
      });

  Future<void> archive(Mailbox box, MimeMessage m) => _serial(() async {
        final boxes = client.mailboxes ?? await client.listMailboxes();
        final target = client.getMailbox(MailboxFlag.archive, boxes) ??
            client.getMailbox(MailboxFlag.all, boxes);
        if (target == null) {
          throw MailException(client, 'This account has no Archive folder.');
        }
        if (target.path == box.path) throw MailException(client, 'Already archived.');
        await _ensure(box);
        // On Gmail, moving from Inbox to "All Mail" removes the Inbox label,
        // which is exactly what Gmail's own Archive button does.
        await client.moveMessage(m, target);
      });

  /// Fetches specific messages by UID (used to open semantic search hits).
  Future<List<MimeMessage>> fetchByUids(Mailbox box, List<int> uids) => _serial(() async {
        if (uids.isEmpty) return <MimeMessage>[];
        await _ensure(box);
        final msgs = await client.fetchMessageSequence(
          MessageSequence.fromIds(uids, isUid: true),
          mailbox: box,
          fetchPreference: FetchPreference.fullWhenWithinSize,
        );
        msgs.sort((a, b) => _date(b).compareTo(_date(a)));
        return msgs;
      });

  /// Moves a message to another folder.
  Future<void> moveTo(Mailbox box, MimeMessage m, Mailbox target) => _serial(() async {
        if (target.path == box.path) return;
        await _ensure(box);
        await client.moveMessage(m, target);
      });

  /// Moves a message to the Junk/Spam folder (on Gmail this also trains
  /// Gmail's spam filter).
  Future<void> junk(Mailbox box, MimeMessage m) => _serial(() async {
        final boxes = client.mailboxes ?? await client.listMailboxes();
        final target = client.getMailbox(MailboxFlag.junk, boxes);
        if (target == null) throw MailException(client, 'This account has no Junk folder.');
        if (target.path == box.path) return;
        await _ensure(box);
        await client.moveMessage(m, target);
      });

  /// Moves a message back to the Inbox (e.g. when a snooze ends elsewhere).
  Future<void> moveToInbox(Mailbox box, MimeMessage m) => _serial(() async {
        final boxes = client.mailboxes ?? await client.listMailboxes();
        final target = client.getMailbox(MailboxFlag.inbox, boxes);
        if (target == null || target.path == box.path) return;
        await _ensure(box);
        await client.moveMessage(m, target);
      });

  /// Downloads one attachment's contents.
  Future<MimePart> fetchPart(Mailbox box, MimeMessage m, String fetchId) async {
    final local = m.getPart(fetchId);
    if (local != null && local.decodeContentBinary() != null) return local;
    return _serial(() async {
      await _ensure(box);
      return client.fetchMessagePart(m, fetchId, responseTimeout: const Duration(minutes: 2));
    });
  }

  /// Builds an outgoing message. [markdownBody] may contain light Markdown,
  /// which is sent as formatted HTML alongside a plain-text version.
  MimeMessage build({
    required List<MailAddress> to,
    List<MailAddress> cc = const [],
    List<MailAddress> bcc = const [],
    required String subject,
    required String markdownBody,
    MimeMessage? inReplyTo,
    String? inReplyToId,
    String? references,
    List<File> files = const [],
    List<MimePart> forwardedParts = const [],
  }) {
    final html = '<div style="font-family: -apple-system, Helvetica, Arial, sans-serif; font-size: 14px; line-height: 1.5">'
        '${md.markdownToHtml(markdownBody, extensionSet: md.ExtensionSet.gitHubWeb)}</div>';
    final plain = markdownToPlain(markdownBody);
    final hasAttachments = files.isNotEmpty || forwardedParts.isNotEmpty;
    final MessageBuilder builder;
    if (hasAttachments) {
      builder = MessageBuilder.prepareMultipartMixedMessage()..addMultipartAlternative(plainText: plain, htmlText: html);
    } else {
      builder = MessageBuilder.prepareMultipartAlternativeMessage(plainText: plain, htmlText: html);
    }
    builder
      ..from = [me]
      ..to = to
      ..cc = cc.isEmpty ? null : cc
      ..bcc = bcc.isEmpty ? null : bcc
      ..subject = subject;
    if (inReplyTo != null) {
      builder.originalMessage = inReplyTo;
    } else if (inReplyToId != null && inReplyToId.isNotEmpty) {
      builder.setHeader('In-Reply-To', inReplyToId);
      builder.setHeader('References', [?references, inReplyToId].join(' ').trim());
    }
    for (final p in forwardedParts) {
      builder.addPart(mimePart: p);
    }
    for (final f in files) {
      final type = MediaType.guessFromFileName(f.path);
      builder.addBinary(f.readAsBytesSync(), type, filename: f.uri.pathSegments.last);
    }
    return builder.buildMimeMessage();
  }

  /// Sends a built message. Sending also appends a copy to Sent over IMAP.
  Future<void> sendBuilt(MimeMessage message, {MimeMessage? inReplyTo, Mailbox? inReplyToBox}) async {
    await _serial(() => client.sendMessage(message, supportUnicode: true));
    if (inReplyTo != null && inReplyToBox != null) {
      try {
        await _serial(() async {
          await _ensure(inReplyToBox);
          await client.markAnswered(MessageSequence.fromMessage(inReplyTo));
          inReplyTo.isAnswered = true;
        });
      } catch (_) {}
    }
  }

  /// The Sent folder (Gmail: "Sent Mail"), if the server has one.
  Mailbox? sentMailbox(List<Mailbox> boxes) {
    for (final b in boxes) {
      if (b.hasFlag(MailboxFlag.sent)) return b;
    }
    for (final b in boxes) {
      final n = b.name.toLowerCase();
      if (n == 'sent' || n == 'sent mail' || n == 'sent items') return b;
    }
    return null;
  }

  /// Removes a draft that was replaced by a newer version.
  Future<void> deleteDraft(Mailbox drafts, MimeMessage draft) => _serial(() async {
        await _ensure(drafts);
        await client.deleteMessage(draft, expunge: true);
      });

  /// Saves an unfinished message to the account's Drafts folder.
  Future<void> saveDraft(MimeMessage message) => _serial(() => client.saveDraftMessage(message));

  /// Convenience wrapper: build and send in one go.
  Future<void> send({
    required List<MailAddress> to,
    List<MailAddress> cc = const [],
    List<MailAddress> bcc = const [],
    required String subject,
    required String markdownBody,
    MimeMessage? inReplyTo,
    Mailbox? inReplyToBox,
  }) =>
      sendBuilt(
        build(to: to, cc: cc, bcc: bcc, subject: subject, markdownBody: markdownBody, inReplyTo: inReplyTo),
        inReplyTo: inReplyTo,
        inReplyToBox: inReplyToBox,
      );

  /// The newest messages of [box] after skipping [skip], oldest pages last.
  /// Used by the background search indexer (on its own connection).
  Future<List<MimeMessage>> fetchRange(Mailbox box, {required int skip, required int count, bool headersOnly = false}) =>
      _serial(() async {
        final selected = await client.selectMailbox(box);
        final total = selected.messagesExists;
        final end = total - skip;
        if (end < 1) return <MimeMessage>[];
        final start = max(1, end - count + 1);
        final msgs = await client.fetchMessageSequence(
          MessageSequence.fromRange(start, end),
          mailbox: selected,
          fetchPreference: headersOnly ? FetchPreference.envelope : FetchPreference.fullWhenWithinSize,
        );
        return msgs;
      });

  // ------------------------------------------------------------ helpers

  static DateTime _date(MimeMessage m) =>
      m.decodeDate() ?? DateTime.fromMillisecondsSinceEpoch(0);

  static DateTime? dateOf(MimeMessage m) => m.decodeDate();

  static String subjectOf(MimeMessage m) {
    final s = m.decodeSubject() ?? m.envelope?.subject ?? '';
    return s.trim().isEmpty ? '(no subject)' : s.trim();
  }

  static MailAddress? senderOf(MimeMessage m) {
    final f = m.from ?? m.envelope?.from;
    return (f == null || f.isEmpty) ? null : f.first;
  }

  static String senderName(MimeMessage m) {
    final a = senderOf(m);
    if (a == null) return 'Unknown sender';
    final n = a.personalName?.trim() ?? '';
    return n.isNotEmpty ? n : a.email;
  }

  /// Friendly names for display ("Alex Rivera, bob@y.com").
  static String displayList(List<MailAddress>? list) => (list ?? const [])
      .map((a) => (a.personalName?.trim().isNotEmpty ?? false) ? a.personalName!.trim() : a.email)
      .join(', ');

  /// Full addresses, suitable for editing and re-parsing.
  static String addressList(List<MailAddress>? list) =>
      (list ?? const []).map((a) => a.toString()).join(', ');

  static final _textCache = Expando<String>();

  /// Best plain-text version of the body (cached per message, since
  /// converting HTML is too slow to repeat on every list repaint).
  static String bodyText(MimeMessage m) {
    final cached = _textCache[m];
    if (cached != null) return cached;
    var text = '';
    final plain = m.decodeTextPlainPart();
    if (plain != null && plain.trim().isNotEmpty) {
      text = plain.trim();
    } else {
      final html = m.decodeTextHtmlPart();
      if (html != null) text = htmlToText(html);
    }
    if (text.isNotEmpty) _textCache[m] = text;
    return text;
  }

  /// A stable key for caching AI results about this message.
  static String keyOf(MimeMessage m, String mailboxPath) {
    final id = m.getHeaderValue('message-id') ?? m.envelope?.messageId;
    if (id != null && id.trim().isNotEmpty) return id.trim();
    return '$mailboxPath#${m.uid ?? m.sequenceId}';
  }

  static EmailContent toContent(MimeMessage m, String mailboxPath) => EmailContent(
        id: keyOf(m, mailboxPath),
        from: senderOf(m)?.toString() ?? 'Unknown',
        to: addressList(m.to ?? m.envelope?.to),
        subject: subjectOf(m),
        date: dateOf(m),
        body: bodyText(m),
        isUnread: !m.isSeen,
      );

  /// The ways this email offers to unsubscribe (RFC 2369 / RFC 8058).
  static Unsubscribe? unsubscribeOf(MimeMessage m) {
    final raw = m.getHeaderValue('list-unsubscribe');
    if (raw == null || raw.trim().isEmpty) return null;
    Uri? web;
    Uri? mail;
    for (final match in RegExp(r'<([^>]+)>').allMatches(raw)) {
      final u = Uri.tryParse(match[1]!.trim());
      if (u == null) continue;
      if (u.scheme == 'mailto') {
        mail ??= u;
      } else if (u.scheme == 'https' || u.scheme == 'http') {
        web ??= u;
      }
    }
    if (web == null && mail == null) return null;
    final post = (m.getHeaderValue('list-unsubscribe-post') ?? '').toLowerCase().contains('one-click');
    return Unsubscribe(web: web, mail: mail, oneClick: post && web?.scheme == 'https');
  }

  static const _brands = [
    'paypal', 'apple', 'icloud', 'amazon', 'microsoft', 'outlook', 'google', 'gmail', 'netflix', 'dhl', 'fedex',
    'spotify', 'instagram', 'facebook', 'whatsapp', 'linkedin', 'dropbox', 'docusign', 'coinbase', 'binance',
  ];

  /// A plain reason if the sender looks forged (display name pretending to
  /// be another address or a well-known company). Null if nothing stands out.
  static String? suspicionOf(MimeMessage m) {
    final from = senderOf(m);
    if (from == null) return null;
    final domain = from.email.contains('@') ? from.email.split('@').last.toLowerCase() : '';
    final name = (from.personalName ?? '').toLowerCase();
    if (domain.isEmpty || name.isEmpty) return null;
    final shown = RegExp(r'[\w.+-]+@([\w-]+\.[\w.-]+)').firstMatch(name);
    if (shown != null && shown[1] != domain && !domain.endsWith('.${shown[1]}')) {
      return 'The sender name shows ${shown[0]}, but it was really sent from ${from.email}.';
    }
    for (final b in _brands) {
      if (RegExp('\\b$b\\b').hasMatch(name) && !domain.contains(b)) {
        return 'It says it is from "${from.personalName}", but it was sent from $domain.';
      }
    }
    return null;
  }

  /// A key shared by every message of one conversation: the root of
  /// References, else In-Reply-To, else the message's own ID.
  ///
  /// A reply made by [build] (also when read back from Sent) carries the
  /// original's References plus its ID, so it gets the same key. When some
  /// client left out References, `ThreadIndex` (threads.dart) links
  /// messages through all the IDs they mention and is more reliable.
  static String threadKeyOf(MimeMessage m) {
    final idPattern = RegExp(r'<[^<>\s]+>');
    final refs = (m.getHeaderValue('references') ?? '').trim();
    final first = idPattern.firstMatch(refs)?.group(0);
    if (first != null) return first;
    final irt = (m.getHeaderValue('in-reply-to') ?? m.envelope?.inReplyTo ?? '').trim();
    if (irt.isNotEmpty) return idPattern.firstMatch(irt)?.group(0) ?? irt;
    final own = (m.getHeaderValue('message-id') ?? m.envelope?.messageId ?? '').trim();
    return own.isNotEmpty
        ? (idPattern.firstMatch(own)?.group(0) ?? own)
        : 'subject:${normalizedSubject(subjectOf(m))}';
  }

  static String normalizedSubject(String s) =>
      s.replaceAll(RegExp(r'^\s*((re|fwd?|aw|wg|sv|vs|tr|rif)\s*(\[\d+\])?\s*:\s*)+', caseSensitive: false), '').trim().toLowerCase();

  /// Turns light Markdown into tidy plain text for the text/plain part.
  static String markdownToPlain(String markdown) => markdown
      .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m[1]!)
      .replaceAllMapped(RegExp(r'__(.+?)__'), (m) => m[1]!)
      .replaceAllMapped(RegExp(r'^#{1,6}\s+', multiLine: true), (_) => '')
      .replaceAllMapped(RegExp(r'\[(.+?)\]\((.+?)\)'), (m) => '${m[1]} (${m[2]})');

  /// Parses `Ann <ann@x.com>, bob@y.com` into addresses; throws on bad input.
  static List<MailAddress> parseAddresses(String input) {
    final parts = input
        .split(RegExp(r'[,;]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);
    return [for (final p in parts) MailAddress.parse(p)];
  }
}

/// How to leave a mailing list.
class Unsubscribe {
  const Unsubscribe({this.web, this.mail, this.oneClick = false});

  /// A web page (or, with [oneClick], an endpoint that unsubscribes on POST).
  final Uri? web;
  final Uri? mail;
  final bool oneClick;
}

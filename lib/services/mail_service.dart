import 'dart:math' as math;
import 'dart:io';
import 'dart:math';

import 'package:enough_mail/enough_mail.dart';
import 'package:markdown/markdown.dart' as md;

import '../models/account_config.dart';
import '../models/email_content.dart';
import '../models/search_plan.dart';
import 'html_text.dart';
import 'message_cache.dart';
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
/// Reverses a move or delete (for the Undo button).
typedef UndoAction = Future<void> Function();

/// The standard mailboxes Mail combines across accounts ("All Sent", …).
enum MailboxRole {
  inbox('All Inboxes', 'Inbox'),
  drafts('All Drafts', 'Drafts'),
  sent('All Sent', 'Sent'),
  archive('All Archive', 'Archive'),
  junk('All Junk', 'Junk'),
  trash('All Trash', 'Trash');

  const MailboxRole(this.combinedLabel, this.label);
  final String combinedLabel;
  final String label;
}

class MailService {
  MailService(this.config, MailCredentials credentials, {int? downloadSizeLimit = 256 * 1024})
      : client = MailClient(
          _account(config, credentials),
          // Messages up to this size are downloaded whole when listing, so
          // previews and AI sorting work without extra round trips.
          // (A connection that only watches for new mail passes null.)
          downloadSizeLimit: downloadSizeLimit,
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
  /// Runs [op] after the previous one. If the connection dropped it
  /// reconnects and tries once more, unless [retry] is false (sending:
  /// the server may already have accepted the message).
  Future<T> _serial<T>(Future<T> Function() op, {bool retry = true}) {
    Future<T> run() async {
      try {
        return await op();
      } catch (e) {
        if (!retry || !_looksLikeConnectionLoss(e)) rethrow;
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

  /// Special-use folders can neither be renamed nor deleted.
  static bool isProtectedMailbox(Mailbox b) =>
      b.isInbox ||
      b.isSent ||
      b.isDrafts ||
      b.isTrash ||
      b.isJunk ||
      b.isArchive ||
      b.hasFlag(MailboxFlag.all) ||
      b.hasFlag(MailboxFlag.flagged) ||
      b.name.toUpperCase() == 'INBOX';

  /// Full IMAP path for a new folder called [name] under [parent] (or the root).
  static String childPath(String name, Mailbox? parent) =>
      parent == null ? name : '${parent.path}${parent.pathSeparator}$name';

  /// Creates a folder (a subfolder of [parent] when given).
  Future<Mailbox> createMailbox(String name, {Mailbox? parent}) => _serial(() async {
        final sep = parent?.pathSeparator ?? '/';
        if (name.contains(sep)) throw ArgumentError('A folder name cannot contain "$sep".');
        return client.createMailbox(name, parentMailbox: parent);
      });

  /// Renames [box] within its parent folder.
  Future<void> renameMailbox(Mailbox box, String newName) => _serial(() async {
        if (isProtectedMailbox(box)) throw StateError('"${box.name}" is a system folder and cannot be renamed.');
        final sep = box.pathSeparator;
        if (newName.contains(sep)) throw ArgumentError('A folder name cannot contain "$sep".');
        final i = box.path.lastIndexOf(sep);
        final newPath = i < 0 ? newName : '${box.path.substring(0, i)}$sep$newName';
        final imap = client.lowLevelIncomingMailClient as ImapClient;
        await imap.renameMailbox(box, newPath);
      });

  /// Deletes [box] and everything in it.
  Future<void> deleteMailbox(Mailbox box) => _serial(() async {
        if (isProtectedMailbox(box)) throw StateError('"${box.name}" is a system folder and cannot be deleted.');
        await client.deleteMailbox(box);
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
      !MessageCache.isStub(m) && (m.decodeTextPlainPart() != null || m.decodeTextHtmlPart() != null);

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

  /// Apple Mail's flag colours, stored as the $MailFlagBit0-2 keywords so
  /// they match Mail on the Mac, iPhone and iPad.
  static const flagColorNames = ['Red', 'Orange', 'Yellow', 'Green', 'Blue', 'Purple', 'Gray'];
  static const _flagBits = [r'$MailFlagBit0', r'$MailFlagBit1', r'$MailFlagBit2'];

  /// The flag colour index (0 = red … 6 = gray) of a flagged message.
  static int flagColorOf(MimeMessage m) {
    final flags = m.flags ?? const <String>[];
    var v = 0;
    for (var i = 0; i < 3; i++) {
      if (flags.any((f) => f.toLowerCase() == _flagBits[i].toLowerCase())) v |= 1 << i;
    }
    return v.clamp(0, 6);
  }

  /// Flags [m] with a colour.
  Future<void> setFlagColor(Mailbox box, MimeMessage m, int color) => _serial(() async {
        await _ensure(box);
        final seq = MessageSequence.fromMessage(m);
        final on = [r'\Flagged', for (var i = 0; i < 3; i++) if (color & (1 << i) != 0) _flagBits[i]];
        final off = [for (var i = 0; i < 3; i++) if (color & (1 << i) == 0) _flagBits[i]];
        await client.store(seq, on, action: StoreAction.add);
        if (off.isNotEmpty) await client.store(seq, off, action: StoreAction.remove);
        final flags = [...?m.flags]..removeWhere((f) => _flagBits.any((b) => b.toLowerCase() == f.toLowerCase()));
        m.flags = [...flags, ...on.where((f) => !flags.contains(f))];
        m.isFlagged = true;
      });

  /// An account's mailbox for [role]: by the server's special-use flag,
  /// else by its usual name.
  static Mailbox? roleMailbox(List<Mailbox> boxes, MailboxRole role) {
    Mailbox? pick(MailboxFlag flag, Set<String> names) =>
        boxes.where((b) => b.hasFlag(flag)).firstOrNull ??
        boxes.where((b) => !b.isNotSelectable && names.contains(b.name.toLowerCase())).firstOrNull;
    return switch (role) {
      MailboxRole.inbox => boxes.where((b) => b.isInbox).firstOrNull,
      MailboxRole.drafts => pick(MailboxFlag.drafts, const {'drafts', 'draft'}),
      MailboxRole.sent => pick(MailboxFlag.sent, const {'sent', 'sent mail', 'sent items', 'sent messages'}),
      MailboxRole.archive => pick(MailboxFlag.archive, const {'archive', 'archives'}),
      MailboxRole.junk => pick(MailboxFlag.junk, const {'junk', 'spam', 'junk e-mail', 'junk email'}),
      MailboxRole.trash => pick(MailboxFlag.trash, const {'trash', 'deleted items', 'deleted messages', 'bin'}),
    };
  }

  static bool isTrash(Mailbox box) =>
      box.hasFlag(MailboxFlag.trash) || const ['trash', 'deleted items', 'deleted messages', 'bin'].contains(box.name.toLowerCase());

  static bool isJunk(Mailbox box) =>
      box.hasFlag(MailboxFlag.junk) || const ['junk', 'spam', 'junk e-mail', 'junk email'].contains(box.name.toLowerCase());

  /// Turns a library move result into an undo action, when the server
  /// reported where the message went.
  UndoAction? _undoMove(MoveResult r) => r.canUndo && r.targetSequence != null
      ? () => _serial(() async {
            await client.undoMoveMessages(r);
          })
      : null;

  /// Moves to Trash. In Trash itself it deletes for good, like Mail.
  Future<UndoAction?> delete(Mailbox box, MimeMessage m) => _serial(() async {
        await _ensure(box);
        if (isTrash(box)) {
          await client.deleteMessage(m, expunge: true);
          return null;
        }
        final r = await client.deleteMessage(m);
        return r.canUndo && r.targetSequence != null
            ? () => _serial(() async {
                  await client.undoDeleteMessages(r);
                })
            : null;
      });

  Future<UndoAction?> archive(Mailbox box, MimeMessage m) => _serial(() async {
        final boxes = client.mailboxes ?? await client.listMailboxes();
        var target = client.getMailbox(MailboxFlag.archive, boxes) ??
            (config.isGmail ? client.getMailbox(MailboxFlag.all, boxes) : null) ??
            boxes.where((b) => b.name.toLowerCase() == 'archive').firstOrNull;
        // Like Mail: make an Archive mailbox on servers that have none.
        target ??= config.isGmail ? null : await client.createMailbox('Archive');
        if (target == null) {
          throw MailException(client, 'This account has no Archive folder.');
        }
        if (target.path == box.path) throw MailException(client, 'Already archived.');
        await _ensure(box);
        // On Gmail, moving from Inbox to "All Mail" removes the Inbox label,
        // which is exactly what Gmail's own Archive button does.
        return _undoMove(await client.moveMessage(m, target));
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
  Future<UndoAction?> moveTo(Mailbox box, MimeMessage m, Mailbox target) => _serial(() async {
        if (target.path == box.path) return null;
        await _ensure(box);
        return _undoMove(await client.moveMessage(m, target));
      });

  /// Moves a message to the Junk/Spam folder (on Gmail this also trains
  /// Gmail's spam filter).
  Future<UndoAction?> junk(Mailbox box, MimeMessage m) => _serial(() async {
        final boxes = client.mailboxes ?? await client.listMailboxes();
        final target = client.getMailbox(MailboxFlag.junk, boxes) ?? boxes.where(isJunk).firstOrNull;
        if (target == null) throw MailException(client, 'This account has no Junk folder.');
        if (target.path == box.path) return null;
        await _ensure(box);
        return _undoMove(await client.moveMessage(m, target));
      });

  /// "Not Junk": back to the Inbox.
  Future<UndoAction?> notJunk(Mailbox box, MimeMessage m) => _serial(() async {
        final boxes = client.mailboxes ?? await client.listMailboxes();
        final inbox = client.getMailbox(MailboxFlag.inbox, boxes) ?? boxes.where((b) => b.isInbox).firstOrNull;
        if (inbox == null || inbox.path == box.path) return null;
        await _ensure(box);
        return _undoMove(await client.moveMessage(m, inbox));
      });

  /// Current flags of already-loaded messages (read, flagged, colours), so
  /// changes made on other devices show up. Messages missing from the
  /// answer were deleted or moved elsewhere. Returns UID -> flags.
  Future<Map<int, List<String>>> fetchFlags(Mailbox box, List<int> uids) => _serial(() async {
        if (uids.isEmpty) return <int, List<String>>{};
        await _ensure(box);
        final imap = client.lowLevelIncomingMailClient as ImapClient;
        final out = <int, List<String>>{};
        // Batches keep each command short.
        for (var i = 0; i < uids.length; i += 500) {
          final part = uids.sublist(i, math.min(i + 500, uids.length));
          final r = await imap.uidFetchMessages(MessageSequence.fromIds(part, isUid: true), '(UID FLAGS)');
          for (final m in r.messages) {
            if (m.uid != null) out[m.uid!] = m.flags ?? const [];
          }
        }
        return out;
      });

  /// Unread counts for the folders besides the Inbox (IMAP STATUS), for the
  /// sidebar. Sent, Drafts, Trash and All Mail are skipped, as in Mail.
  Future<Map<String, int>> unreadCounts(List<Mailbox> boxes) => _serial(() async {
        final imap = client.lowLevelIncomingMailClient as ImapClient;
        final out = <String, int>{};
        // Drafts show how many there are (like Mail), not how many are unread.
        final drafts = roleMailbox(boxes, MailboxRole.drafts);
        if (drafts != null) {
          try {
            final st = await imap.statusMailbox(drafts, [StatusFlags.messages]);
            out[drafts.path] = st.messagesExists;
          } catch (_) {}
        }
        for (final b in boxes) {
          if (b.isInbox || b.isNotSelectable || isTrash(b) || b.path == drafts?.path ||
              b.hasFlag(MailboxFlag.sent) || b.hasFlag(MailboxFlag.drafts) || b.hasFlag(MailboxFlag.all)) {
            continue;
          }
          try {
            final st = await imap.statusMailbox(b, [StatusFlags.unseen]);
            out[b.path] = st.messagesUnseen;
          } catch (_) {
            // Some servers refuse STATUS on special folders; skip them.
          }
        }
        return out;
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
        '${bodyToHtml(markdownBody)}</div>';
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

  /// Gmail and Microsoft 365 file mail sent over SMTP in Sent themselves;
  /// saving another copy would show it twice.
  bool get _serverSavesSent {
    final host = config.imapHost.toLowerCase();
    return config.isGmail || host.contains('office365') || host.contains('outlook.') || host.contains('hotmail');
  }

  /// Sends a built message, then files a copy in Sent where the server
  /// doesn't do that itself. A failure to file the copy never turns a
  /// delivered message into a "failed" send.
  Future<void> sendBuilt(MimeMessage message, {MimeMessage? inReplyTo, Mailbox? inReplyToBox}) async {
    await _serial(() => client.sendMessage(message, supportUnicode: true, appendToSent: false), retry: false);
    if (!_serverSavesSent) {
      try {
        await _serial(() async {
          final boxes = client.mailboxes ?? await client.listMailboxes();
          final sent = sentMailbox(boxes);
          if (sent != null) await client.appendMessage(message, sent, flags: [MessageFlags.seen]);
        });
      } catch (_) {
        // Delivered; only the Sent copy is missing.
      }
    }
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
  /// The Drafts folder, if the server has one.
  Mailbox? draftsMailbox(List<Mailbox> boxes) {
    for (final b in boxes) {
      if (b.hasFlag(MailboxFlag.drafts)) return b;
    }
    for (final b in boxes) {
      if (const {'drafts', 'draft'}.contains(b.name.toLowerCase())) return b;
    }
    return null;
  }

  /// Saves [message] to Drafts and returns where it went and its UID (when
  /// the server reports it), so a later save can replace it.
  Future<({Mailbox box, int? uid})> saveDraft(MimeMessage message) => _serial(() async {
        final boxes = client.mailboxes ?? await client.listMailboxes();
        final drafts = draftsMailbox(boxes);
        if (drafts == null) throw Exception('This account has no Drafts folder.');
        final code = await client.appendMessage(message, drafts, flags: [MessageFlags.draft, MessageFlags.seen]);
        final ids = code?.targetSequence.toList() ?? const <int>[];
        return (box: drafts, uid: ids.isEmpty ? null : ids.last);
      });

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

  /// Who a sent message or draft is to, for the message list (like Mail's
  /// Sent mailbox, which lists recipients instead of yourself).
  static String recipientNames(MimeMessage m) {
    final to = [...?m.to, ...?m.cc];
    if (to.isEmpty) return 'No Recipients';
    return to.map((a) => (a.personalName?.trim().isNotEmpty ?? false) ? a.personalName!.trim() : a.email).join(', ');
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
  /// The HTML part of a message the user typed. Light Markdown (**bold**,
  /// lists, links) becomes formatting, but line breaks stay exactly where
  /// they were typed and raw HTML is shown as text, never run.
  static String bodyToHtml(String text) {
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    final out = <String>[];
    final listItem = RegExp(r'^\s*([-*+]|\d+[.)])\s');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final next = i + 1 < lines.length ? lines[i + 1] : '';
      // A Markdown hard break (two trailing spaces) keeps single newlines,
      // except where the next line starts a list item.
      final keepBreak = line.trim().isNotEmpty && next.trim().isNotEmpty && !listItem.hasMatch(next);
      out.add(keepBreak ? '${line.trimRight()}  ' : line);
    }
    return md.markdownToHtml(out.join('\n'), extensionSet: md.ExtensionSet.gitHubWeb, encodeHtml: true)
        // Only the formatting we generate, never HTML typed into the message.
        .replaceAllMapped(RegExp(r'<(?!/?(p|br|strong|em|ul|ol|li|a|code|pre|blockquote|h[1-6]|hr|del|table|thead|tbody|tr|th|td)\b)'), (_) => '&lt;');
  }

  static String markdownToPlain(String markdown) => markdown
      .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m[1]!)
      .replaceAllMapped(RegExp(r'__(.+?)__'), (m) => m[1]!)
      .replaceAllMapped(RegExp(r'^#{1,6}\s+', multiLine: true), (_) => '')
      .replaceAllMapped(RegExp(r'\[(.+?)\]\((.+?)\)'), (m) => '${m[1]} (${m[2]})');

  /// Splits `A <a@x>, "Doe, Jo" <j@x>; b@y` into single addresses,
  /// keeping commas inside quoted names.
  static List<String> splitAddresses(String text) {
    final out = <String>[];
    final buf = StringBuffer();
    var quoted = false;
    for (final ch in text.split('')) {
      if (ch == '"') quoted = !quoted;
      if (!quoted && (ch == ',' || ch == ';')) {
        if (buf.toString().trim().isNotEmpty) out.add(buf.toString().trim());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    if (buf.toString().trim().isNotEmpty) out.add(buf.toString().trim());
    return out;
  }

  /// Parses `Ann <ann@x.com>, bob@y.com` into addresses; throws on bad input.
  static List<MailAddress> parseAddresses(String input) {
    final out = <MailAddress>[];
    for (final p in splitAddresses(input)) {
      final a = MailAddress.parse(p);
      if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(a.email)) throw FormatException('Not an email address: $p');
      out.add(a);
    }
    return out;
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

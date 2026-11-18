import 'dart:async';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/brief.dart';
import '../models/triage.dart';
import '../services/mail_service.dart';
import '../state/app_state.dart';
import 'mac_style.dart';
import 'message_view.dart' show openReply, snoozeChoices;

/// Opens "Catch me up": the unread mail sorted into what needs you, what is
/// worth knowing and what you can skip, with an action on every row.
Future<void> showCatchUp(BuildContext context) {
  final state = context.read<AppState>();
  // In one account's inbox, catch up on just that account.
  final account = state.view.kind == ViewKind.folder && state.folderBox?.isInbox == true ? state.folderSession : null;
  final all = account?.inboxMessages ?? state.allInboxMessages;
  final unread = all.where((m) => !m.isSeen).take(40).toList();
  final source = unread.length >= 3 ? unread : all.take(20).toList();
  if (source.isEmpty || state.ai == null) return Future.value();
  return showDialog<void>(
    context: context,
    builder: (_) => ChangeNotifierProvider.value(
      value: state,
      child: _CatchUpDialog(
          messages: source, onlyUnread: unread.length >= 3, host: context, account: account?.config.email),
    ),
  );
}

/// Briefings already made this session, so reopening is instant.
final _cache = <String, BriefItem>{};

class _CatchUpDialog extends StatefulWidget {
  const _CatchUpDialog({required this.messages, required this.onlyUnread, required this.host, this.account});

  /// Set when catching up on one account only.
  final String? account;
  final List<MimeMessage> messages;
  final bool onlyUnread;

  /// The window behind the dialog, for opening a reply after closing it.
  final BuildContext host;

  @override
  State<_CatchUpDialog> createState() => _CatchUpDialogState();
}

class _CatchUpDialogState extends State<_CatchUpDialog> {
  final _items = <MimeMessage, BriefItem>{};

  /// Rows the user dealt with, and what they did ("Archived", …).
  final _done = <MimeMessage, String>{};
  int _pending = 0;
  bool _showSkipped = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  String _id(AppState s, MimeMessage m) => s.contentOf(m).id;

  Future<void> _load() async {
    final state = context.read<AppState>();
    final todo = <MimeMessage>[];
    for (final m in widget.messages) {
      final hit = _cache[_id(state, m)];
      if (hit != null) {
        _items[m] = hit;
      } else {
        todo.add(m);
      }
    }
    setState(() => _pending = todo.length);
    // Small batches so rows appear while the rest are still being read.
    for (var i = 0; i < todo.length && mounted; i += 8) {
      final batch = todo.sublist(i, (i + 8).clamp(0, todo.length));
      final contents = [for (final m in batch) state.contentOf(m)];
      Map<String, BriefItem> got;
      try {
        got = await state.ai!.briefing(contents);
      } catch (e) {
        got = {};
        _error = 'The AI could not read some emails, so they are sorted by their labels.';
      }
      if (!mounted) return;
      setState(() {
        for (var j = 0; j < batch.length; j++) {
          final item = got[contents[j].id] ?? _fallback(state, batch[j]);
          if (got.containsKey(contents[j].id)) _cache[contents[j].id] = item;
          _items[batch[j]] = item;
        }
        _pending -= batch.length;
      });
    }
  }

  /// Used when the AI fails: sort by the inbox triage labels instead.
  BriefItem _fallback(AppState state, MimeMessage m) {
    final t = state.triageOf(m);
    final group = t == null
        ? BriefGroup.fyi
        : t.priority == MailPriority.high || t.needsReply
            ? BriefGroup.attention
            : t.priority == MailPriority.low
                ? BriefGroup.skip
                : BriefGroup.fyi;
    return BriefItem(
      group: group,
      takeaway: MailService.subjectOf(m),
      action: t?.needsReply == true ? BriefAction.reply : BriefAction.none,
    );
  }

  List<MimeMessage> _in(BriefGroup g) => [
        for (final m in widget.messages)
          if (_items[m]?.group == g) m,
      ];

  Future<void> _act(MimeMessage m, String label, Future<void> Function() f) async {
    setState(() => _done[m] = label);
    try {
      await f();
    } catch (_) {
      if (mounted) setState(() => _done.remove(m));
    }
  }

  Future<void> _markRead(AppState s, MimeMessage m) async {
    if (!m.isSeen) await s.toggleRead(m);
  }

  void _open(AppState s, MimeMessage m) {
    Navigator.of(context).pop();
    unawaited(s.openMessage(m));
  }

  void _reply(AppState s, MimeMessage m) {
    Navigator.of(context).pop();
    unawaited(s.openMessage(m));
    openReply(widget.host, m);
  }

  Future<void> _remind(AppState s, MimeMessage m, BuildContext anchor) async {
    final box = anchor.findRenderObject() as RenderBox?;
    final at = box?.localToGlobal(Offset(0, box.size.height)) ?? Offset.zero;
    final when = await showMenu<DateTime>(
        popUpAnimationStyle: AnimationStyle.noAnimation,
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, 0),
      items: [
        for (final (label, time) in snoozeChoices()) PopupMenuItem(value: time, height: 32, child: Text(label)),
      ],
    );
    if (when != null) await _act(m, 'Reminder set', () => s.snooze(m, when));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = MacColors.of(context);
    final attention = _in(BriefGroup.attention);
    final fyi = _in(BriefGroup.fyi);
    final skip = _in(BriefGroup.skip);
    final openSkip = skip.where((m) => !_done.containsKey(m)).toList();
    final read = _items.length;
    final subtitle = _pending > 0
        ? 'Reading ${widget.messages.length} emails… ($read done)'
        : '${widget.account == null ? '' : '${widget.account} · '}'
            '${widget.messages.length} ${widget.onlyUnread ? 'unread' : 'recent'} · '
            '${attention.length} need${attention.length == 1 ? 's' : ''} you';

    return Dialog(
      backgroundColor: c.window,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 680),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 10, 12),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Catch Me Up', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.label)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(fontSize: 12, color: c.secondaryLabel)),
                ]),
              ),
              if (_pending > 0)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5)),
                ),
              ToolButton(icon: CupertinoIcons.xmark, tooltip: 'Close', onPressed: () => Navigator.of(context).pop()),
            ]),
          ),
          const Hairline(),
          Flexible(
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 12), children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                  child: Text(_error!, style: TextStyle(fontSize: 12, color: c.secondaryLabel)),
                ),
              if (attention.isNotEmpty) ...[
                const _Header('Needs You'),
                for (final m in attention) _row(state, m, primary: true),
              ],
              if (fyi.isNotEmpty) ...[
                const _Header('Worth Knowing'),
                for (final m in fyi) _row(state, m),
              ],
              if (skip.isNotEmpty) ...[
                _Header(
                  'Can Skip · ${skip.length}',
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    TextButton(
                      onPressed: openSkip.isEmpty
                          ? null
                          : () {
                              for (final m in openSkip) {
                                unawaited(_act(m, 'Read', () => _markRead(state, m)));
                              }
                            },
                      child: const Text('Mark All Read'),
                    ),
                    TextButton(
                      onPressed: openSkip.isEmpty
                          ? null
                          : () {
                              for (final m in openSkip) {
                                unawaited(_act(m, 'Archived', () => state.archiveMessage(m)));
                              }
                            },
                      child: const Text('Archive All'),
                    ),
                    ToolButton(
                      icon: _showSkipped ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down,
                      tooltip: _showSkipped ? 'Hide' : 'Show',
                      size: 13,
                      onPressed: () => setState(() => _showSkipped = !_showSkipped),
                    ),
                  ]),
                ),
                if (_showSkipped)
                  for (final m in skip) _row(state, m, compact: true),
              ],
              if (_items.isEmpty && _pending > 0)
                Padding(
                  padding: const EdgeInsets.all(28),
                  child: Center(child: Text('Reading your inbox…', style: TextStyle(fontSize: 13, color: c.tertiaryLabel))),
                ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _row(AppState state, MimeMessage m, {bool primary = false, bool compact = false}) {
    final c = MacColors.of(context);
    final item = _items[m]!;
    final done = _done[m];
    final sender = MailService.senderName(m);
    final dim = done != null;
    final mainLabel = item.action == BriefAction.reply ? 'Reply' : 'Open';
    final main = item.action == BriefAction.reply ? () => _reply(state, m) : () => _open(state, m);

    return InkWell(
      onTap: () => _open(state, m),
      hoverColor: c.hover,
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, compact ? 6 : 9, 12, compact ? 6 : 9),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(
            child: Opacity(
              opacity: dim ? 0.45 : 1,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(sender,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.label)),
                  ),
                  if (item.due.isNotEmpty && !compact) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(4)),
                      child: Text('Due ${item.due}', style: TextStyle(fontSize: 11, color: c.secondaryLabel)),
                    ),
                  ],
                ]),
                const SizedBox(height: 2),
                Text(
                  compact ? MailService.subjectOf(m) : item.takeaway,
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: c.secondaryLabel, height: 1.3),
                ),
              ]),
            ),
          ),
          const SizedBox(width: 10),
          if (done != null)
            Text(done, style: TextStyle(fontSize: 12, color: c.tertiaryLabel))
          else ...[
            if (!compact)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: primary
                    ? FilledButton(
                        onPressed: main,
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          minimumSize: const Size(0, 26),
                          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                        ),
                        child: Text(mainLabel),
                      )
                    : TextButton(onPressed: main, child: Text(mainLabel)),
              ),
            if (!compact)
              Builder(
                builder: (bc) => ToolButton(
                  icon: CupertinoIcons.alarm,
                  tooltip: 'Remind Me',
                  size: 15,
                  onPressed: () => _remind(state, m, bc),
                ),
              ),
            ToolButton(
              icon: CupertinoIcons.archivebox,
              tooltip: 'Archive',
              size: 15,
              onPressed: () => _act(m, 'Archived', () => state.archiveMessage(m)),
            ),
            if (!m.isSeen)
              ToolButton(
                icon: CupertinoIcons.checkmark_circle,
                tooltip: 'Mark as Read',
                size: 15,
                onPressed: () => _act(m, 'Read', () => _markRead(state, m)),
              ),
          ],
        ]),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title, {this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 2),
      child: Row(children: [
        Expanded(
          child: Text(title, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c.secondaryLabel)),
        ),
        ?trailing,
      ]),
    );
  }
}

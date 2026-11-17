import 'package:enough_mail/enough_mail.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/mail_service.dart';
import '../services/threads.dart';
import '../state/app_state.dart';

/// The earlier messages of [message]'s conversation, as quiet one-line rows
/// that open in place to show the plain-text body. Shows nothing when the
/// message starts its conversation. Mount it above the message body.
class ConversationHistory extends StatefulWidget {
  const ConversationHistory(this.message, {super.key});

  final MimeMessage message;

  @override
  State<ConversationHistory> createState() => _ConversationHistoryState();
}

class _ConversationHistoryState extends State<ConversationHistory> {
  /// Message-IDs (or identity hash) of the rows that are open.
  final _open = <Object>{};
  bool _showAll = false;

  static const _collapsedLimit = 5;

  Object _id(MimeMessage m) => ThreadIndex.messageIdOf(m) ?? identityHashCode(m);

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final all = state.conversationOf(widget.message);
    final here = ThreadIndex.messageIdOf(widget.message);
    var at = all.indexWhere((m) => identical(m, widget.message) || (here != null && ThreadIndex.messageIdOf(m) == here));
    if (at < 0) at = all.length;
    final earlier = all.sublist(0, at);
    if (earlier.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final hairline = scheme.outlineVariant.withValues(alpha: 0.6);
    final hidden = !_showAll && earlier.length > _collapsedLimit ? earlier.length - _collapsedLimit : 0;
    final shown = hidden > 0 ? earlier.sublist(hidden) : earlier;
    final mine = {for (final a in state.accounts) a.email.toLowerCase()};

    return Container(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: hairline, width: 0.5))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Text(
              earlier.length == 1 ? '1 earlier message' : '${earlier.length} earlier messages',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
          if (hidden > 0)
            _Row(
              onTap: () => setState(() => _showAll = true),
              hairline: hairline,
              child: Text('Show $hidden more', style: TextStyle(fontSize: 13, color: scheme.primary)),
            ),
          for (final m in shown)
            _HistoryRow(
              key: ValueKey(_id(m)),
              message: m,
              open: _open.contains(_id(m)),
              fromMe: mine.contains(MailService.senderOf(m)?.email.toLowerCase()),
              hairline: hairline,
              onToggle: () => setState(() => _open.contains(_id(m)) ? _open.remove(_id(m)) : _open.add(_id(m))),
            ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.child, required this.onTap, required this.hairline});
  final Widget child;
  final VoidCallback onTap;
  final Color hairline;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: hairline, width: 0.5))),
          child: child,
        ),
      );
}

class _HistoryRow extends StatefulWidget {
  const _HistoryRow({
    super.key,
    required this.message,
    required this.open,
    required this.fromMe,
    required this.hairline,
    required this.onToggle,
  });

  final MimeMessage message;
  final bool open, fromMe;
  final Color hairline;
  final VoidCallback onToggle;

  @override
  State<_HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends State<_HistoryRow> {
  String? _body;

  @override
  void didUpdateWidget(_HistoryRow old) {
    super.didUpdateWidget(old);
    if (widget.open && _body == null) _load();
  }

  @override
  void initState() {
    super.initState();
    if (widget.open) _load();
  }

  Future<void> _load() async {
    final text = await context.read<AppState>().conversationBody(widget.message);
    if (mounted) setState(() => _body = text);
  }

  /// First readable line, skipping quoted replies.
  static String snippet(String text) {
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('>')) continue;
      if (RegExp(r'^On .+wrote:$').hasMatch(t)) break;
      return t;
    }
    return '';
  }

  static String shortDate(DateTime? d) {
    if (d == null) return '';
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) return DateFormat.jm().format(d);
    if (d.year == now.year) return DateFormat.MMMd().format(d);
    return DateFormat.yMMMd().format(d);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    final cached = _body ?? (MailService.hasBody(m) ? MailService.bodyText(m) : null);
    final name = widget.fromMe ? 'Me' : MailService.senderName(m);
    return InkWell(
      onTap: widget.onToggle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: widget.hairline, width: 0.5))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Icon(widget.open ? Icons.expand_more : Icons.chevron_right, size: 14, color: muted),
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                if (!widget.open)
                  Expanded(
                    child: Text(
                      cached == null ? '' : snippet(cached),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: muted),
                    ),
                  )
                else
                  const Spacer(),
                const SizedBox(width: 8),
                Text(shortDate(MailService.dateOf(m)), style: TextStyle(fontSize: 12, color: muted)),
              ],
            ),
            if (widget.open)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 6, 0, 4),
                child: cached == null
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 1.5, color: muted),
                      )
                    : SelectableText(
                        cached.isEmpty ? '(no text)' : cached,
                        style: const TextStyle(fontSize: 13, height: 1.4),
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

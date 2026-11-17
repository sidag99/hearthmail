import 'package:enough_mail/enough_mail.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/triage.dart';
import '../services/mail_service.dart';
import '../services/user_data.dart';
import '../state/app_state.dart';
import 'compose_page.dart';
import 'sidebar.dart';
import 'widgets/ai_widgets.dart';

String formatListDate(DateTime? d) {
  if (d == null) return '';
  final local = d.toLocal();
  final now = DateTime.now();
  if (local.year == now.year && local.month == now.month && local.day == now.day) {
    return DateFormat.jm().format(local);
  }
  if (now.difference(local).inDays < 6) return DateFormat.E().format(local);
  if (local.year == now.year) return DateFormat.MMMd().format(local);
  return DateFormat.yMMMd().format(local);
}

class MessageListPane extends StatelessWidget {
  const MessageListPane({super.key, required this.searchFocus, this.onOpen});

  final FocusNode searchFocus;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final list = state.visibleMessages;
    final theme = Theme.of(context);

    final title = switch (state.view.kind) {
      ViewKind.allInboxes => state.sessions.length > 1 ? 'All Inboxes' : 'Inbox',
      ViewKind.folder => state.folderBox == null
          ? ''
          : '${state.folderBox!.isInbox ? 'Inbox' : state.folderBox!.name} · ${state.folderSession?.config.email ?? ''}',
      ViewKind.priority => 'Priority',
      ViewKind.needsReply => 'Needs reply',
      ViewKind.category => state.view.category!.label,
      ViewKind.search => 'Search',
      ViewKind.vip => 'VIPs',
      ViewKind.snoozed => 'Reminders',
      ViewKind.scheduled => 'Scheduled',
      ViewKind.followUp => 'Follow up',
    };
    final special = state.view.kind == ViewKind.scheduled || state.view.kind == ViewKind.followUp;

    return Column(children: [
      _SearchBar(focus: searchFocus),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(children: [
          Expanded(child: Text(title, style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis)),
          if (state.loadingMessages)
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          if (!special && list.any((m) => !m.isSeen))
            IconButton(
              icon: const Icon(Icons.done_all, size: 18),
              tooltip: 'Mark all as read',
              onPressed: state.markAllRead,
            ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: 'Refresh',
            onPressed: state.refresh,
          ),
        ]),
      ),
      if (state.view.kind == ViewKind.search) _SearchHeader(state: state),
      if (!special && state.view.kind != ViewKind.search)
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Row(children: [
            for (final f in ListFilter.values)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(switch (f) {
                    ListFilter.all => 'All',
                    ListFilter.unread => 'Unread',
                    ListFilter.flagged => 'Flagged',
                    ListFilter.attachments => 'Attachments',
                  }),
                  selected: state.listFilter == f,
                  onSelected: (_) => state.setFilter(f),
                ),
              ),
          ]),
        ),
      Expanded(
        child: switch (state.view.kind) {
          ViewKind.scheduled => _ScheduledList(state: state),
          ViewKind.followUp => _FollowUpList(state: state),
          _ => _buildList(context, state, list),
        },
      ),
    ]);
  }

  Widget _buildList(BuildContext context, AppState state, List<MimeMessage> list) {
    final theme = Theme.of(context);
    final failed = state.sessions.where((s) => s.status == ConnectionStatus.failed).toList();
    final noneConnected = !state.sessions.any((s) => s.connected);
    if (list.isEmpty && (state.anyConnecting || state.loadingMessages)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (noneConnected && failed.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.cloud_off, size: 32, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            for (final s in failed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('${s.config.email}: ${s.error ?? 'Not connected'}', textAlign: TextAlign.center),
              ),
            const SizedBox(height: 4),
            FilledButton.tonal(
              onPressed: () {
                for (final s in failed) {
                  state.reconnect(s);
                }
              },
              child: const Text('Try again'),
            ),
          ]),
        ),
      );
    }
    if (list.isEmpty) {
      final empty = switch (state.view.kind) {
        ViewKind.search => state.searching ? '' : 'No results',
        ViewKind.allInboxes || ViewKind.folder => 'No messages',
        _ => state.sorting ? 'Sorting your inbox…' : 'Nothing here',
      };
      return Center(child: Text(empty, style: theme.textTheme.bodyMedium));
    }
    final canLoadMore = state.canLoadMore;
    final showAccount = state.sessions.length > 1 && state.view.kind != ViewKind.folder;
    final swipe = MediaQuery.sizeOf(context).width < 700;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (canLoadMore && n.metrics.pixels > n.metrics.maxScrollExtent - 400) {
          state.loadMore();
        }
        return false;
      },
      child: ListView.separated(
        itemCount: list.length + (canLoadMore ? 1 : 0),
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
        itemBuilder: (context, i) {
          if (i >= list.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
            );
          }
          final m = list[i];
          final owner = state.sessionOf(m);
          final z = state.snoozeOf(m);
          final tile = MessageTile(
            message: m,
            triage: state.triageOf(m),
            account: showAccount && owner != null ? AccountBadge(config: owner.config, index: state.indexOf(owner)) : null,
            selected: identical(state.selected, m),
            vip: state.isVipMessage(m),
            reminder: z == null ? null : (z.isDue ? 'Reminder' : 'Snoozed'),
            suspicious: MailService.suspicionOf(m) != null || state.triageOf(m)?.suspicious == true,
            onTap: () {
              state.openMessage(m);
              onOpen?.call();
            },
          );
          if (!swipe) return tile;
          // Phone-style swipes: right to archive, left to delete.
          return Dismissible(
            key: ObjectKey(m),
            background: Container(
              color: const Color(0xFF30A46C),
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 20),
              child: const Icon(Icons.archive_outlined, color: Colors.white),
            ),
            secondaryBackground: Container(
              color: const Color(0xFFE5484D),
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              child: const Icon(Icons.delete_outline, color: Colors.white),
            ),
            onDismissed: (dir) =>
                dir == DismissDirection.startToEnd ? state.archiveMessage(m) : state.deleteMessage(m),
            child: tile,
          );
        },
      ),
    );
  }
}

class _SearchBar extends StatefulWidget {
  const _SearchBar({required this.focus});
  final FocusNode focus;

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  final _controller = TextEditingController();
  bool _useAi = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final ai = _useAi && state.aiReady;
    if (state.view.kind != ViewKind.search && state.searchQuery.isEmpty && _controller.text.isNotEmpty && !widget.focus.hasFocus) {
      _controller.clear();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: TextField(
        controller: _controller,
        focusNode: widget.focus,
        textInputAction: TextInputAction.search,
        onSubmitted: (q) => state.search(q, useAi: ai),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
          prefixIcon: Icon(ai ? Icons.auto_awesome : Icons.search, size: 18, color: ai ? scheme.primary : null),
          hintText: ai ? 'Ask anything, e.g. "flight to Boston"' : 'Search ${state.searchScopeLabel}',
          suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
            if (_controller.text.isNotEmpty || state.view.kind == ViewKind.search)
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                tooltip: 'Clear search',
                onPressed: () {
                  _controller.clear();
                  state.clearSearch();
                  setState(() {});
                },
              ),
            Tooltip(
              message: ai ? 'AI search is on' : 'AI search is off',
              child: Switch(
                value: ai,
                onChanged: state.aiReady ? (v) => setState(() => _useAi = v) : null,
              ),
            ),
          ]),
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
  }
}

class _SearchHeader extends StatefulWidget {
  const _SearchHeader({required this.state});
  final AppState state;

  @override
  State<_SearchHeader> createState() => _SearchHeaderState();
}

class _SearchHeaderState extends State<_SearchHeader> {
  String? _answeredFor;
  bool _showAnswer = false;

  static final _question = RegExp(
      r'^(who|what|when|where|why|how|which|did|do|does|is|are|was|were|has|have|can|should)\b',
      caseSensitive: false);

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final theme = Theme.of(context);
    final q = state.searchQuery;
    final done = !state.searching && state.searchResults.isNotEmpty;
    if (done && state.lastSearchWasAi && _answeredFor != q) {
      _answeredFor = q;
      _showAnswer = q.endsWith('?') || _question.hasMatch(q);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (state.searching) ...[
            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
          ],
          Expanded(child: Text(state.searchStatus, style: theme.textTheme.bodySmall)),
          if (done && state.aiReady && !_showAnswer)
            TextButton.icon(
              icon: const Icon(Icons.auto_awesome, size: 14),
              label: const Text('Ask AI'),
              onPressed: () => setState(() => _showAnswer = true),
            ),
        ]),
        if (done && _showAnswer && state.aiReady) ...[
          const SizedBox(height: 6),
          AiCard(
            key: ValueKey('answer:$q'),
            title: 'Answer',
            onClose: () => setState(() => _showAnswer = false),
            child: AiStreamView(
              placeholder: 'Reading the top results…',
              start: () => state.ai!.answerFromEmails(
                q,
                [for (final m in state.searchResults.take(6)) state.contentOf(m)],
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.message,
    required this.triage,
    required this.selected,
    required this.onTap,
    this.account,
    this.vip = false,
    this.reminder,
    this.suspicious = false,
  });

  final MimeMessage message;
  final Widget? account;
  final bool vip;
  final String? reminder;
  final bool suspicious;
  final Triage? triage;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unread = !message.isSeen;
    final body = MailService.bodyText(message).replaceAll(RegExp(r'\s+'), ' ').trim();
    final t = triage;

    return Material(
      color: selected ? scheme.secondaryContainer.withValues(alpha: 0.7) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 16,
              child: Padding(
                padding: const EdgeInsets.only(top: 5),
                child: unread
                    ? Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                      )
                    : null,
              ),
            ),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  if (vip)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(Icons.star_rounded, size: 14, color: Color(0xFFFFB224)),
                    ),
                  Expanded(
                    child: Text(
                      MailService.senderName(message),
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: unread ? FontWeight.w700 : FontWeight.w500),
                    ),
                  ),
                  if (message.isFlagged)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(Icons.flag, size: 14, color: Color(0xFFF76B15)),
                    ),
                  if (message.hasAttachments())
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(Icons.attach_file, size: 14, color: scheme.onSurfaceVariant),
                    ),
                  Text(formatListDate(MailService.dateOf(message)),
                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                ]),
                const SizedBox(height: 2),
                Text(
                  MailService.subjectOf(message),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: unread ? FontWeight.w600 : FontWeight.normal,
                    color: scheme.onSurface,
                  ),
                ),
                if (body.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ],
                if (account != null || reminder != null || suspicious || (t != null && (t.priority == MailPriority.high || t.needsReply || t.category != MailCategory.other))) ...[
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    if (reminder != null) _Tag(reminder!, const Color(0xFF8E4EC6)),
                    if (suspicious) const _Tag('Suspicious', Color(0xFFE5484D)),
                    if (t != null) ...[
                    if (t.priority == MailPriority.high) const _Tag('Priority', Color(0xFFE5484D)),
                    if (t.needsReply && !message.isAnswered) _Tag('Needs reply', scheme.primary),
                    if (t.category != MailCategory.other) _Tag(t.category.label, categoryColor(t.category)),
                    ],
                    ?account,
                  ]),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, this.color);
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: color)),
      );
}


class _ScheduledList extends StatelessWidget {
  const _ScheduledList({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final items = state.userData.scheduled;
    final theme = Theme.of(context);
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Nothing scheduled. In a new message, use the clock next to Send to send it later.',
              textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
        ),
      );
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
      itemBuilder: (context, i) {
        final m = items[i];
        return ListTile(
          leading: const Icon(Icons.schedule_send),
          title: Text(m.subject.isEmpty ? '(no subject)' : m.subject, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('To ${m.to}\n${DateFormat('E d MMM, HH:mm').format(m.sendAt)} · ${state.sessionById(m.accountId)?.config.email ?? ''}',
              maxLines: 2),
          isThreeLine: true,
          trailing: Wrap(children: [
            IconButton(icon: const Icon(Icons.send, size: 18), tooltip: 'Send now', onPressed: () => state.sendScheduledNow(m)),
            IconButton(icon: const Icon(Icons.close, size: 18), tooltip: 'Cancel', onPressed: () => state.cancelScheduled(m)),
          ]),
        );
      },
    );
  }
}

class _FollowUpList extends StatelessWidget {
  const _FollowUpList({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final due = state.dueFollowUps;
    final waiting = state.userData.followUps.where((f) => !due.contains(f)).toList()..sort((a, b) => a.due.compareTo(b.due));
    final theme = Theme.of(context);
    if (due.isEmpty && waiting.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('No follow-ups. When writing, use the bell to be reminded if nobody replies.',
              textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
        ),
      );
    }
    Widget tile(FollowUp f, bool isDue) => ListTile(
          leading: Icon(isDue ? Icons.notification_important_outlined : Icons.hourglass_empty,
              color: isDue ? theme.colorScheme.primary : null),
          title: Text(f.subject, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(isDue
              ? 'No reply from ${f.to} yet'
              : 'Waiting for ${f.to} · reminder ${DateFormat('E d MMM').format(f.due)}'),
          trailing: Wrap(children: [
            if (isDue)
              TextButton(
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => ComposePage(followUpOf: f))),
                child: const Text('Follow up'),
              ),
            IconButton(icon: const Icon(Icons.close, size: 18), tooltip: 'Dismiss', onPressed: () => state.dismissFollowUp(f)),
          ]),
        );
    return ListView(children: [
      for (final f in due) tile(f, true),
      if (waiting.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('WAITING', style: theme.textTheme.labelSmall),
        ),
      for (final f in waiting) tile(f, false),
    ]);
  }
}

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/triage.dart';
import '../services/mail_service.dart';
import '../services/user_data.dart';
import '../state/app_state.dart';
import 'compose_page.dart';
import 'mac_style.dart';
import 'message_view.dart' show showMessageMenu;
import 'sidebar.dart';
import 'widgets/ai_widgets.dart';

/// Dates the way Mail shows them: time today, "Yesterday", weekday this
/// week, otherwise a short date.
String formatListDate(DateTime? d) {
  if (d == null) return '';
  final local = d.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return DateFormat.jm().format(local);
  if (diff == 1) return 'Yesterday';
  if (diff < 7) return DateFormat.EEEE().format(local);
  return DateFormat('d/M/yy').format(local);
}

String _viewTitle(AppState state) => switch (state.view.kind) {
      ViewKind.allInboxes => state.sessions.length > 1 ? 'All Inboxes' : 'Inbox',
      ViewKind.folder => state.folderBox == null ? '' : (state.folderBox!.isInbox ? 'Inbox' : state.folderBox!.name),
      ViewKind.priority => 'Priority',
      ViewKind.needsReply => 'Needs Reply',
      ViewKind.category => state.view.category!.label,
      ViewKind.search => 'Search',
      ViewKind.vip => 'VIPs',
      ViewKind.snoozed => 'Reminders',
      ViewKind.scheduled => 'Send Later',
      ViewKind.followUp => 'Follow Up',
      ViewKind.flagged => 'Flagged',
    };

class MessageListPane extends StatelessWidget {
  const MessageListPane({
    super.key,
    required this.searchFocus,
    this.onOpen,
    this.showSearch = false,
    this.onCompose,
    this.onCatchUp,
    this.leading,
  });

  /// Shown before the title (the sidebar button on phones).
  final Widget? leading;

  final FocusNode searchFocus;
  final VoidCallback? onOpen;

  /// On narrow windows the search field lives here instead of the toolbar.
  final bool showSearch;
  final VoidCallback? onCompose;
  final VoidCallback? onCatchUp;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final list = state.visibleMessages;
    final c = MacColors.of(context);
    final special = state.view.kind == ViewKind.scheduled || state.view.kind == ViewKind.followUp;
    final total = special ? state.unreadFor(state.view) : list.length;
    final unread = special ? 0 : list.where((m) => !m.isSeen).length;
    final subtitle = state.view.kind == ViewKind.folder && state.sessions.length > 1
        ? state.folderSession?.config.email ?? ''
        : '${NumberFormat.decimalPattern().format(total)} ${total == 1 ? 'message' : 'messages'}'
            '${unread > 0 ? ', $unread unread' : ''}';
    final showCategories = state.categoriesEnabled &&
        (state.view.kind == ViewKind.allInboxes || (state.view.kind == ViewKind.folder && state.folderBox?.isInbox == true));

    return ColoredBox(
      color: c.window,
      child: Column(children: [
        // Title + counts, sitting in the window's title bar like Mail.
        SizedBox(
          height: kToolbarHeight52,
          child: Padding(
            padding: EdgeInsets.only(left: leading == null ? 16 : 6, right: 6),
            child: Row(children: [
              ?leading,
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_viewTitle(state),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c.label)),
                  Text(subtitle,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: c.secondaryLabel)),
                ]),
              ),
              if (state.loadingMessages)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                ),
              if (!special) _FilterButton(state: state),
              if (onCatchUp != null && state.aiReady)
                ToolButton(icon: CupertinoIcons.sparkles, tooltip: 'Catch me up', onPressed: onCatchUp),
              if (onCompose != null)
                ToolButton(icon: CupertinoIcons.square_pencil, tooltip: 'New Message (⌘N)', onPressed: onCompose),
            ]),
          ),
        ),
        const Hairline(),
        if (showSearch) Padding(padding: const EdgeInsets.fromLTRB(10, 8, 10, 4), child: MailSearchField(focus: searchFocus)),
        if (state.view.kind == ViewKind.search) _SearchHeader(state: state),
        if (showCategories) _CategoryBar(state: state),
        Expanded(
          child: switch (state.view.kind) {
            ViewKind.scheduled => _ScheduledList(state: state),
            ViewKind.followUp => _FollowUpList(state: state),
            _ => _buildList(context, state, list),
          },
        ),
      ]),
    );
  }

  Widget _buildList(BuildContext context, AppState state, List<MimeMessage> list) {
    final c = MacColors.of(context);
    final failed = state.sessions.where((s) => s.status == ConnectionStatus.failed).toList();
    final noneConnected = !state.sessions.any((s) => s.connected);
    if (list.isEmpty && (state.anyConnecting || state.loadingMessages)) {
      return const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (noneConnected && failed.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(CupertinoIcons.wifi_exclamationmark, size: 28, color: c.secondaryLabel),
            const SizedBox(height: 10),
            for (final s in failed)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('${s.config.email}: ${s.error ?? 'Not connected'}',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: c.secondaryLabel)),
              ),
            const SizedBox(height: 6),
            OutlinedButton(
              onPressed: () {
                for (final s in failed) {
                  state.reconnect(s);
                }
              },
              child: const Text('Try Again'),
            ),
          ]),
        ),
      );
    }
    if (list.isEmpty) {
      final empty = switch (state.view.kind) {
        ViewKind.search => state.searching ? '' : 'No Results',
        ViewKind.allInboxes || ViewKind.folder =>
          state.categoriesEnabled && state.inboxCategory != InboxCategory.all ? 'No Messages in ${state.inboxCategory.label}' : 'No Messages',
        _ => state.sorting ? 'Sorting your inbox…' : 'No Messages',
      };
      return Center(child: Text(empty, style: TextStyle(fontSize: 15, color: c.tertiaryLabel, fontWeight: FontWeight.w500)));
    }
    final canLoadMore = state.canLoadMore;
    final showAccount = state.sessions.length > 1 && state.view.kind != ViewKind.folder;
    final phone = MediaQuery.sizeOf(context).width < 700;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (canLoadMore && n.metrics.pixels > n.metrics.maxScrollExtent - 400) state.loadMore();
        return false;
      },
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        itemCount: list.length + (canLoadMore ? 1 : 0),
        itemBuilder: (context, i) {
          if (i >= list.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5))),
            );
          }
          final m = list[i];
          final owner = state.sessionOf(m);
          final z = state.snoozeOf(m);
          final selected = identical(state.selected, m);
          final next = i + 1 < list.length ? list[i + 1] : null;
          final tile = MessageTile(
            message: m,
            triage: state.triageOf(m),
            accountColor: showAccount && owner != null ? accountColor(state.indexOf(owner)) : null,
            selected: selected,
            // Like Mail, no separator touches the selection highlight.
            showSeparator: !selected && (next == null || !identical(state.selected, next)),
            vip: state.isVipMessage(m),
            reminder: z != null && z.isDue,
            suspicious: MailService.suspicionOf(m) != null || state.triageOf(m)?.suspicious == true,
            onTap: () {
              state.openMessage(m);
              onOpen?.call();
            },
          );
          final withMenu = GestureDetector(
            onSecondaryTapDown: (d) => showMessageMenu(context, m, d.globalPosition),
            onLongPressStart: phone ? (d) => showMessageMenu(context, m, d.globalPosition) : null,
            child: tile,
          );
          if (!phone) return withMenu;
          // Phone-style swipes: right to archive, left to delete.
          return Dismissible(
            key: ObjectKey(m),
            background: Container(
              color: const Color(0xFF34C759),
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 20),
              child: const Icon(CupertinoIcons.archivebox, color: Colors.white),
            ),
            secondaryBackground: Container(
              color: const Color(0xFFFF3B30),
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              child: const Icon(CupertinoIcons.trash, color: Colors.white),
            ),
            onDismissed: (dir) => dir == DismissDirection.startToEnd ? state.archiveMessage(m) : state.deleteMessage(m),
            child: withMenu,
          );
        },
      ),
    );
  }
}

/// Mail's filter button with a menu of filters.
class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    final active = state.listFilter != ListFilter.all;
    return ToolbarItem(
      child: PopupMenuButton<ListFilter>(
        tooltip: active ? 'Filtered by ${_label(state.listFilter)}' : 'Filter',
        initialValue: state.listFilter,
        onSelected: state.setFilter,
        itemBuilder: (_) => [
          for (final f in ListFilter.values)
            CheckedPopupMenuItem(value: f, checked: state.listFilter == f, height: 32, child: Text(_label(f))),
        ],
        child: SizedBox(
          width: 32,
          height: 28,
          child: Icon(
            active ? CupertinoIcons.line_horizontal_3_decrease_circle_fill : CupertinoIcons.line_horizontal_3_decrease_circle,
            size: 18,
            color: active ? c.accent : c.secondaryLabel,
          ),
        ),
      ),
    );
  }

  static String _label(ListFilter f) => switch (f) {
        ListFilter.all => 'All Messages',
        ListFilter.unread => 'Unread',
        ListFilter.flagged => 'Flagged',
        ListFilter.attachments => 'Has Attachments',
      };
}

/// Primary · Transactions · Updates · Promotions, like Mail's categories.
class _CategoryBar extends StatelessWidget {
  const _CategoryBar({required this.state});
  final AppState state;

  static IconData _icon(InboxCategory c) => switch (c) {
        InboxCategory.primary => CupertinoIcons.person_fill,
        InboxCategory.transactions => CupertinoIcons.cart_fill,
        InboxCategory.updates => CupertinoIcons.chat_bubble_2_fill,
        InboxCategory.promotions => CupertinoIcons.tag_fill,
        InboxCategory.all => CupertinoIcons.tray_fill,
      };

  static Color _color(InboxCategory c) => switch (c) {
        InboxCategory.primary => const Color(0xFF007AFF),
        InboxCategory.transactions => const Color(0xFF34C759),
        InboxCategory.updates => const Color(0xFFAF52DE),
        InboxCategory.promotions => const Color(0xFFFF2D55),
        InboxCategory.all => const Color(0xFF8E8E93),
      };

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      child: Row(children: [
        for (final cat in InboxCategory.values)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Builder(builder: (context) {
              final selected = state.inboxCategory == cat;
              final unread = cat == InboxCategory.all ? 0 : state.unreadInCategory(cat);
              final color = _color(cat);
              return Tooltip(
                message: unread > 0 ? '${cat.label} · $unread unread' : cat.label,
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => state.setInboxCategory(cat),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    height: 28,
                    padding: EdgeInsets.symmetric(horizontal: selected ? 10 : 9),
                    decoration: BoxDecoration(color: selected ? color : c.fill, borderRadius: BorderRadius.circular(14)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_icon(cat), size: 14, color: selected ? Colors.white : c.secondaryLabel),
                      if (selected) ...[
                        const SizedBox(width: 5),
                        Text(cat.label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)),
                      ] else if (unread > 0) ...[
                        const SizedBox(width: 3),
                        Container(width: 5, height: 5, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                      ],
                    ]),
                  ),
                ),
              );
            }),
          ),
      ]),
    );
  }
}

/// The search field (with the ✨ switch for AI search).
class MailSearchField extends StatefulWidget {
  const MailSearchField({super.key, required this.focus});
  final FocusNode focus;

  @override
  State<MailSearchField> createState() => _MailSearchFieldState();
}

class _MailSearchFieldState extends State<MailSearchField> {
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
    final c = MacColors.of(context);
    final ai = _useAi && state.aiReady;
    if (state.view.kind != ViewKind.search && state.searchQuery.isEmpty && _controller.text.isNotEmpty && !widget.focus.hasFocus) {
      _controller.clear();
    }
    return MacSearchField(
      controller: _controller,
      focusNode: widget.focus,
      hint: ai ? 'Ask or search' : 'Search',
      onSubmitted: (q) => state.search(q, useAi: ai),
      onChanged: (_) => setState(() {}),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (_controller.text.isNotEmpty || state.view.kind == ViewKind.search)
          InkWell(
            onTap: () {
              _controller.clear();
              state.clearSearch();
              setState(() {});
            },
            child: Icon(CupertinoIcons.xmark_circle_fill, size: 14, color: c.tertiaryLabel),
          ),
        if (state.aiReady)
          Tooltip(
            message: ai ? 'AI search is on: understands questions and meaning' : 'AI search is off: exact words only',
            child: InkWell(
              onTap: () => setState(() => _useAi = !_useAi),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Icon(CupertinoIcons.sparkles, size: 14, color: ai ? c.accent : c.tertiaryLabel),
              ),
            ),
          ),
      ]),
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
    final c = MacColors.of(context);
    final q = state.searchQuery;
    final done = !state.searching && state.searchResults.isNotEmpty;
    if (done && state.lastSearchWasAi && _answeredFor != q) {
      _answeredFor = q;
      _showAnswer = q.endsWith('?') || _question.hasMatch(q);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 12, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (state.searching) ...[
            const SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 1.5)),
            const SizedBox(width: 8),
          ],
          Expanded(child: Text(state.searchStatus, style: TextStyle(fontSize: 11, color: c.secondaryLabel))),
          if (done && state.aiReady && !_showAnswer)
            TextButton.icon(
              icon: const Icon(CupertinoIcons.sparkles, size: 12),
              label: const Text('Answer'),
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
              start: () => state.ai!.answerFromEmails(q, [for (final m in state.searchResults.take(6)) state.contentOf(m)]),
            ),
          ),
        ],
      ]),
    );
  }
}

/// One row of the message list, laid out like Mail's.
class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.message,
    required this.triage,
    required this.selected,
    required this.onTap,
    this.accountColor,
    this.vip = false,
    this.reminder = false,
    this.suspicious = false,
    this.showSeparator = true,
  });

  final MimeMessage message;
  final Color? accountColor;
  final Triage? triage;
  final bool selected;
  final VoidCallback onTap;
  final bool vip;
  final bool reminder;
  final bool suspicious;
  final bool showSeparator;

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    final unread = !message.isSeen;
    final body = MailService.bodyText(message).replaceAll(RegExp(r'\s+'), ' ').trim();
    final t = triage;
    final fg = selected ? Colors.white : c.label;
    final fg2 = selected ? Colors.white.withValues(alpha: 0.85) : c.secondaryLabel;
    final needsReply = t != null && t.needsReply && !message.isAnswered;

    Widget badge(IconData i, Color color, [String? tip]) {
      final icon = Icon(i, size: 12, color: selected ? Colors.white : color);
      return Padding(padding: const EdgeInsets.only(left: 4), child: tip == null ? icon : Tooltip(message: tip, child: icon));
    }

    return Column(mainAxisSize: MainAxisSize.min, children: [
      Material(
        color: selected ? c.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          hoverColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 10, 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Gutter: unread dot, VIP star or replied arrow.
              SizedBox(
                width: 20,
                child: Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Center(
                    child: unread
                        ? Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(color: selected ? Colors.white : c.accent, shape: BoxShape.circle),
                          )
                        : vip
                            ? Icon(CupertinoIcons.star_fill, size: 11, color: selected ? Colors.white : c.secondaryLabel)
                            : message.isAnswered
                                ? Icon(CupertinoIcons.arrowshape_turn_up_left_fill,
                                    size: 10, color: selected ? Colors.white : c.tertiaryLabel)
                                : null,
                  ),
                ),
              ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    if (vip && unread)
                      Padding(padding: const EdgeInsets.only(right: 4), child: Icon(CupertinoIcons.star_fill, size: 11, color: fg2)),
                    Expanded(
                      child: Text(
                        MailService.senderName(message),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg),
                      ),
                    ),
                    if (accountColor != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(color: selected ? Colors.white : accountColor, shape: BoxShape.circle),
                        ),
                      ),
                    const SizedBox(width: 6),
                    Text(formatListDate(MailService.dateOf(message)), style: TextStyle(fontSize: 12, color: fg2)),
                  ]),
                  const SizedBox(height: 1),
                  Row(children: [
                    Expanded(
                      child: Text(MailService.subjectOf(message),
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: fg)),
                    ),
                    if (suspicious) badge(CupertinoIcons.exclamationmark_triangle_fill, const Color(0xFFFF3B30), 'Looks suspicious'),
                    if (reminder) badge(CupertinoIcons.alarm, const Color(0xFFAF52DE), 'Reminder'),
                    if (t?.priority == MailPriority.high) badge(CupertinoIcons.exclamationmark_circle_fill, const Color(0xFFFF3B30), 'Priority'),
                    if (needsReply) badge(CupertinoIcons.arrowshape_turn_up_left_fill, c.accent, 'Needs reply'),
                    if (message.hasAttachments()) badge(CupertinoIcons.paperclip, c.secondaryLabel),
                    if (message.isFlagged) badge(CupertinoIcons.flag_fill, const Color(0xFFFF9500)),
                  ]),
                  if (body.isNotEmpty) ...[
                    const SizedBox(height: 1),
                    Text(body, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: fg2, height: 1.3)),
                  ],
                ]),
              ),
            ]),
          ),
        ),
      ),
      if (showSeparator) const Hairline(indent: 24),
    ]);
  }
}

class _ScheduledList extends StatelessWidget {
  const _ScheduledList({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final items = state.userData.scheduled;
    final c = MacColors.of(context);
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Nothing scheduled.\nUse the clock next to Send to send a message later.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: c.tertiaryLabel)),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: items.length,
      separatorBuilder: (_, _) => const Hairline(indent: 24),
      itemBuilder: (context, i) {
        final m = items[i];
        return ListTile(
          leading: Icon(CupertinoIcons.clock, size: 16, color: c.accent),
          title: Text(m.subject.isEmpty ? '(no subject)' : m.subject, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
              'To ${m.to}\n${DateFormat('E d MMM, HH:mm').format(m.sendAt)} · ${state.sessionById(m.accountId)?.config.email ?? ''}',
              maxLines: 2),
          isThreeLine: true,
          trailing: Wrap(children: [
            ToolButton(icon: CupertinoIcons.paperplane, tooltip: 'Send Now', onPressed: () => state.sendScheduledNow(m)),
            ToolButton(icon: CupertinoIcons.xmark, tooltip: 'Cancel', onPressed: () => state.cancelScheduled(m)),
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
    final c = MacColors.of(context);
    if (due.isEmpty && waiting.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('No follow-ups.\nWhen writing, use the bell to be reminded if nobody replies.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: c.tertiaryLabel)),
        ),
      );
    }
    Widget tile(FollowUp f, bool isDue) => ListTile(
          leading: Icon(isDue ? CupertinoIcons.bell_fill : CupertinoIcons.hourglass,
              size: 16, color: isDue ? c.accent : c.secondaryLabel),
          title: Text(f.subject, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(isDue ? 'No reply from ${f.to} yet' : 'Waiting for ${f.to} · reminder ${DateFormat('E d MMM').format(f.due)}'),
          trailing: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (isDue)
              TextButton(
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ComposePage(followUpOf: f))),
                child: const Text('Follow Up'),
              ),
            ToolButton(icon: CupertinoIcons.xmark, tooltip: 'Dismiss', onPressed: () => state.dismissFollowUp(f)),
          ]),
        );
    return ListView(children: [
      for (final f in due) tile(f, true),
      if (waiting.isNotEmpty) const SectionTitle('Waiting'),
      for (final f in waiting) tile(f, false),
    ]);
  }
}

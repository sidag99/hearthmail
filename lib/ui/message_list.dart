import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/triage.dart';
import '../services/mail_service.dart';
import '../services/user_data.dart';
import '../state/app_state.dart';
import 'compose_page.dart';
import 'mac_style.dart';
import 'message_view.dart' show openDraft, showMessageMenu;
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
      ViewKind.combined => state.view.role!.combinedLabel,
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
    this.titleInset = 0,
  });

  /// Shown before the title (the sidebar button on phones).
  final Widget? leading;

  /// Room on the left for the window's traffic lights when this pane is
  /// the leftmost one.
  final double titleInset;

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
            padding: EdgeInsets.only(left: titleInset + (leading == null ? 16 : 6), right: 6),
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
              _ViewOptionsButton(state: state),
              if (onCatchUp != null && state.aiReady)
                ToolButton(icon: CupertinoIcons.sparkles, tooltip: 'Catch me up', onPressed: onCatchUp, color: c.secondaryLabel),
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
          final z = state.snoozeOf(m);
          final selected = state.isSelected(m);
          final next = i + 1 < list.length ? list[i + 1] : null;
          final tile = MessageTile(
            message: m,
            outgoing: state.isOutgoing(m),
            triage: state.triageOf(m),
            showPhoto: state.settings.showContactPhotos,
            threadCount: state.settings.groupConversations ? state.conversationSize(m) : 1,
            selected: selected,
            // Like Mail, no separator touches the selection highlight.
            showSeparator: !selected && (next == null || !state.isSelected(next)),
            vip: state.isVipMessage(m),
            reminder: z != null && z.isDue,
            suspicious: MailService.suspicionOf(m) != null || state.triageOf(m)?.suspicious == true,
            onTap: () {
              // ⌘-click adds or removes, ⇧-click selects a range, like Mail.
              final keys = HardwareKeyboard.instance;
              state.clickMessage(m, toggle: keys.isMetaPressed || keys.isControlPressed, range: keys.isShiftPressed);
              onOpen?.call();
            },
          );
          final withMenu = GestureDetector(
            // Like Mail: double-click a draft to keep writing it.
            onDoubleTap: state.isDraft(m) ? () => openDraft(context, m) : null,
            onSecondaryTapDown: (d) => showMessageMenu(context, m, d.globalPosition),
            onLongPressStart: phone ? (d) => showMessageMenu(context, m, d.globalPosition) : null,
            child: tile,
          );
          if (!phone) {
            // Drag onto a mailbox in the sidebar to move (all selected).
            final dragged = state.isSelected(m) && state.hasMulti ? state.targets : [m];
            return Draggable<List<MimeMessage>>(
              data: dragged,
              dragAnchorStrategy: pointerDragAnchorStrategy,
              feedback: _DragBadge(count: dragged.length, subject: MailService.subjectOf(m)),
              child: withMenu,
            );
          }
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
        popUpAnimationStyle: AnimationStyle.noAnimation,
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
            active ? CupertinoIcons.line_horizontal_3_decrease_circle_fill : CupertinoIcons.line_horizontal_3_decrease,
            size: active ? 18 : 16,
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

enum _ViewOption { categories, priority, photos, about, ascending, descending }

/// Mail's View > Sort By choices: (setting value, label, natural direction ascending?).
const _sortChoices = [
  ('date', 'Date', false),
  ('from', 'From', true),
  ('subject', 'Subject', true),
  ('unread', 'Unread', true),
  ('flagged', 'Flags', true),
  ('attachments', 'Attachments', true),
];

/// Mail's ⋯ view options menu.
class _ViewOptionsButton extends StatelessWidget {
  const _ViewOptionsButton({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    final s = state.settings;
    return ToolbarItem(
      child: PopupMenuButton<Object>(
        popUpAnimationStyle: AnimationStyle.noAnimation,
        tooltip: 'View Options',
        onSelected: (o) => switch (o) {
          // Picking a sort key also picks its natural direction, like Mail.
          (String key, bool natural) => state.updateSettings(s.copyWith(sortBy: key, sortAscending: natural)),
          _ViewOption.ascending => state.updateSettings(s.copyWith(sortAscending: true)),
          _ViewOption.descending => state.updateSettings(s.copyWith(sortAscending: false)),
          _ViewOption.categories => state.updateSettings(s.copyWith(showCategories: !s.showCategories)),
          _ViewOption.priority => state.updateSettings(s.copyWith(priorityFirst: !s.priorityFirst)),
          _ViewOption.photos => state.updateSettings(s.copyWith(showContactPhotos: !s.showContactPhotos)),
          _ViewOption.about => _aboutCategories(context),
          _ => null,
        },
        itemBuilder: (_) => [
          CheckedPopupMenuItem(
              value: _ViewOption.categories, checked: s.showCategories, height: 32, child: const Text('Show Mail Categories')),
          CheckedPopupMenuItem(
              value: _ViewOption.priority, checked: s.priorityFirst, height: 32, child: const Text('Show Priority Messages')),
          CheckedPopupMenuItem(
              value: _ViewOption.photos, checked: s.showContactPhotos, height: 32, child: const Text('Show Contact Photo')),
          const PopupMenuDivider(),
          for (final (key, label, natural) in _sortChoices)
            CheckedPopupMenuItem(value: (key, natural), checked: s.sortBy == key, height: 30, child: Text('Sort by $label')),
          const PopupMenuDivider(),
          CheckedPopupMenuItem(value: _ViewOption.ascending, checked: s.sortAscending, height: 30, child: const Text('Ascending')),
          CheckedPopupMenuItem(value: _ViewOption.descending, checked: !s.sortAscending, height: 30, child: const Text('Descending')),
          const PopupMenuDivider(),
          const PopupMenuItem(value: _ViewOption.about, height: 32, child: Text('About Categories…')),
        ],
        child: SizedBox(width: 32, height: 28, child: Icon(CupertinoIcons.ellipsis_circle, size: 17, color: c.secondaryLabel)),
      ),
    );
  }

  static void _aboutCategories(BuildContext context) => showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('About Categories'),
          content: const SizedBox(
            width: 360,
            child: Text('Categories sort your inbox into Primary, Transactions, Updates and Promotions. '
                'Sorting is done by the AI on this Mac, and your mail never leaves it.\n\n'
                'VIPs, flagged mail and anything important always stays in Primary. '
                'Show Priority Messages moves important unread mail to the top of the list.'),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
        ),
      );
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
              return Tooltip(
                message: unread > 0 ? '${cat.label} · $unread unread' : cat.label,
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => state.setInboxCategory(cat),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    height: 28,
                    padding: EdgeInsets.symmetric(horizontal: selected ? 10 : 9),
                    decoration: BoxDecoration(color: selected ? c.fill : Colors.transparent, borderRadius: BorderRadius.circular(14)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_icon(cat), size: 14, color: selected ? c.label : c.secondaryLabel),
                      if (selected) ...[
                        const SizedBox(width: 5),
                        Text(cat.label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.label)),
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
    this.showPhoto = false,
    this.threadCount = 1,
    this.vip = false,
    this.reminder = false,
    this.suspicious = false,
    this.showSeparator = true,
    this.outgoing = false,
  });

  final MimeMessage message;

  /// Sent or draft: show who it is to instead of the sender.
  final bool outgoing;
  final bool showPhoto;

  /// Messages in this conversation (shown as a count when more than one).
  final int threadCount;
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
    final who = outgoing ? MailService.recipientNames(message) : MailService.senderName(message);
    final fg = selected ? Colors.white : c.label;
    final fg2 = selected ? Colors.white.withValues(alpha: 0.85) : c.secondaryLabel;
    final needsReply = t != null && t.needsReply && !message.isAnswered;

    // Status icons stay gray, like Mail; only the flag keeps its color.
    Widget badge(IconData i, [String? tip, Color? color]) {
      final icon = Icon(i, size: 12, color: selected ? Colors.white : color ?? c.tertiaryLabel);
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
              if (showPhoto)
                Padding(
                  padding: const EdgeInsets.only(right: 8, top: 1),
                  child: InitialsAvatar(who, size: 30),
                ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    if (vip && unread)
                      Padding(padding: const EdgeInsets.only(right: 4), child: Icon(CupertinoIcons.star_fill, size: 11, color: fg2)),
                    Expanded(
                      child: Text(
                        who,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg),
                      ),
                    ),
                    if (threadCount > 1)
                      Container(
                        margin: const EdgeInsets.only(left: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        decoration: BoxDecoration(
                          border: Border.all(color: selected ? Colors.white70 : c.tertiaryLabel, width: 0.8),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('$threadCount', style: TextStyle(fontSize: 10.5, color: fg2)),
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
                    if (suspicious) badge(CupertinoIcons.exclamationmark_triangle, 'Looks suspicious'),
                    if (reminder) badge(CupertinoIcons.alarm, 'Reminder'),
                    if (t?.priority == MailPriority.high) badge(CupertinoIcons.exclamationmark, 'Priority'),
                    if (needsReply) badge(CupertinoIcons.arrowshape_turn_up_left, 'Needs reply'),
                    if (message.hasAttachments()) badge(CupertinoIcons.paperclip),
                    if (message.isFlagged)
                      badge(CupertinoIcons.flag_fill, null, kFlagColors[MailService.flagColorOf(message)]),
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
          leading: Icon(m.error == null ? CupertinoIcons.clock : CupertinoIcons.exclamationmark_circle,
              size: 16, color: m.error == null ? c.accent : Theme.of(context).colorScheme.error),
          title: Text(m.subject.isEmpty ? '(no subject)' : m.subject, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
              m.error != null
                  ? 'To ${m.to}\nNot sent: ${m.error}'
                  : 'To ${m.to}\n${DateFormat('E d MMM, HH:mm').format(m.sendAt)} · ${state.sessionById(m.accountId)?.config.email ?? ''}',
              maxLines: 2,
              style: m.error == null ? null : TextStyle(color: Theme.of(context).colorScheme.error)),
          isThreeLine: true,
          trailing: Wrap(children: [
            ToolButton(icon: CupertinoIcons.pencil, tooltip: 'Edit', onPressed: () => state.editScheduled(m)),
            ToolButton(icon: CupertinoIcons.paperplane, tooltip: m.error == null ? 'Send Now' : 'Try Again', onPressed: () => state.sendScheduledNow(m)),
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


/// What follows the pointer while dragging messages.
class _DragBadge extends StatelessWidget {
  const _DragBadge({required this.count, required this.subject});
  final int count;
  final String subject;

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    return Material(
      color: c.window,
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(CupertinoIcons.envelope, size: 14, color: c.accent),
          const SizedBox(width: 6),
          Flexible(
            child: Text(count == 1 ? subject : '$count messages',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.label)),
          ),
        ]),
      ),
    );
  }
}

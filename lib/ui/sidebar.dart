import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:macos_window_utils/widgets/transparent_macos_sidebar.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/account_config.dart';
import '../models/triage.dart';
import '../services/mail_service.dart' show MailboxRole;
import '../state/app_state.dart';
import 'account_setup_page.dart';
import 'mac_style.dart';

Color categoryColor(MailCategory c) => switch (c) {
      MailCategory.personal => const Color(0xFFE5484D),
      MailCategory.work => const Color(0xFF3E63DD),
      MailCategory.finance => const Color(0xFF30A46C),
      MailCategory.shopping => const Color(0xFFF76B15),
      MailCategory.travel => const Color(0xFF0090FF),
      MailCategory.newsletter => const Color(0xFF8E4EC6),
      MailCategory.promotion => const Color(0xFFD6409F),
      MailCategory.social => const Color(0xFF12A594),
      MailCategory.notification => const Color(0xFF8D8D86),
      MailCategory.other => const Color(0xFF8D8D86),
    };

/// A distinct color per account, used for its dot in lists.
Color accountColor(int index) => const [
      Color(0xFF007AFF),
      Color(0xFF34C759),
      Color(0xFFFF9500),
      Color(0xFFAF52DE),
      Color(0xFFFF2D55),
      Color(0xFF5AC8FA),
      Color(0xFFFFCC00),
      Color(0xFF8E8E93),
    ][index % 8];

IconData mailboxIcon(Mailbox b) {
  if (b.isInbox) return CupertinoIcons.tray;
  if (b.isSent) return CupertinoIcons.paperplane;
  if (b.isDrafts) return CupertinoIcons.doc_text;
  if (b.isTrash) return CupertinoIcons.trash;
  if (b.isJunk) return CupertinoIcons.exclamationmark_octagon;
  if (b.isArchive) return CupertinoIcons.archivebox;
  if (b.hasFlag(MailboxFlag.all)) return CupertinoIcons.tray_full;
  if (b.hasFlag(MailboxFlag.flagged)) return CupertinoIcons.flag;
  return CupertinoIcons.folder;
}

/// The Mail-style source list: Favorites, Smart Mailboxes, then each
/// account with its mailboxes. Translucent over the desktop on macOS.
class Sidebar extends StatefulWidget {
  const Sidebar({super.key, this.onNavigate, this.onSettings});

  final VoidCallback? onSettings;

  /// Called after the user picks something (closes the drawer on phones).
  final VoidCallback? onNavigate;

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  final _collapsed = <String>{};
  final _expandedAccounts = <String>{};

  /// Open combined mailboxes; All Inboxes starts open, like Mail.
  final _openGroups = <String>{'role.inbox'};

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = MacColors.of(context);
    final multi = state.sessions.length > 1;

    Widget row({
      required IconData icon,
      required String label,
      required bool selected,
      required VoidCallback onTap,
      Color? iconColor,
      int count = 0,
      int indent = 0,
      void Function(List<MimeMessage>)? onDrop,
      bool? expanded,
      VoidCallback? onToggle,
    }) =>
        _SidebarRow(
          icon: icon,
          label: label,
          selected: selected,
          iconColor: iconColor ?? c.accent,
          count: count,
          indent: indent,
          onDrop: onDrop,
          expanded: expanded,
          onToggle: onToggle,
          onTap: () {
            onTap();
            widget.onNavigate?.call();
          },
        );

    bool open(String key) => !_collapsed.contains(key);
    void toggle(String key) => setState(() => _collapsed.contains(key) ? _collapsed.remove(key) : _collapsed.add(key));

    // Drop messages on a mailbox to move them (same account only).
    void Function(List<MimeMessage>)? dropInto(AccountSession s, Mailbox b) => b.isNotSelectable
        ? null
        : (ms) {
            final mine = [for (final m in ms) if (state.sessionOf(m) == s) m];
            if (mine.length < ms.length) state.toast('Messages can only be moved within the same account.');
            if (mine.isNotEmpty) state.moveMessages(mine, b);
          };

    // Like Mail with several accounts: "All Inboxes", "All Sent", … each
    // opens to one row per account.
    List<Widget> combined(MailboxRole role, IconData icon) {
      final owners = state.sessionsWith(role);
      if (owners.isEmpty) return const [];
      final key = 'role.${role.name}';
      final expanded = _openGroups.contains(key);
      final view = role == MailboxRole.inbox ? const MailView.allInboxes() : MailView.combined(role);
      return [
        row(
          icon: icon,
          label: role.combinedLabel,
          selected: state.view == view,
          count: state.unreadFor(view),
          expanded: expanded,
          onToggle: () => setState(() => expanded ? _openGroups.remove(key) : _openGroups.add(key)),
          onTap: () => state.openCombined(role),
        ),
        if (expanded)
          for (final s in owners)
            () {
              final b = state.roleBox(s, role)!;
              return row(
                icon: icon,
                label: s.config.email,
                indent: 1,
                onDrop: dropInto(s, b),
                selected: state.view == MailView.folder(s.id, b.path),
                count: b.isInbox ? state.unreadFor(MailView.folder(s.id, b.path)) : state.folderUnread(s, b),
                onTap: () => state.openFolder(s, b),
              );
            }(),
      ];
    }

    final list = ListView(
      padding: EdgeInsets.only(top: useMacWindow ? kToolbarHeight52 : 8, bottom: 12),
      children: [
        _SidebarHeader(text: 'Favorites', open: open('fav'), onToggle: () => toggle('fav')),
        if (open('fav')) ...[
          if (multi)
            ...combined(MailboxRole.inbox, CupertinoIcons.tray)
          else
            row(
              icon: CupertinoIcons.tray,
              label: 'Inbox',
              selected: state.view == const MailView.allInboxes(),
              count: state.unreadFor(const MailView.allInboxes()),
              onTap: () => state.setView(const MailView.allInboxes()),
            ),
          if (state.userData.vips.isNotEmpty)
            row(
              icon: CupertinoIcons.star,
              label: 'VIPs',
              selected: state.view == const MailView.vip(),
              count: state.unreadFor(const MailView.vip()),
              onTap: () => state.setView(const MailView.vip()),
            ),
          row(
            icon: CupertinoIcons.flag,
            iconColor: const Color(0xFFFF9500),
            label: 'Flagged',
            selected: state.view == const MailView.flagged(),
            count: state.unreadFor(const MailView.flagged()),
            onTap: () => state.setView(const MailView.flagged()),
          ),
          if (multi) ...[
            ...combined(MailboxRole.drafts, CupertinoIcons.doc_text),
            ...combined(MailboxRole.sent, CupertinoIcons.paperplane),
            ...combined(MailboxRole.archive, CupertinoIcons.archivebox),
            ...combined(MailboxRole.junk, CupertinoIcons.exclamationmark_octagon),
            ...combined(MailboxRole.trash, CupertinoIcons.trash),
          ],
        ],
        _SidebarHeader(
          text: 'Smart Mailboxes',
          open: open('smart'),
          onToggle: () => toggle('smart'),
          trailing: state.sorting
              ? Text('Sorting ${state.sortDone}/${state.sortTotal}', style: TextStyle(fontSize: 10, color: c.secondaryLabel))
              : null,
        ),
        if (open('smart')) ...[
          if (state.aiReady) ...[
            row(
              icon: CupertinoIcons.exclamationmark_circle,
              label: 'Priority',
              selected: state.view == const MailView.priority(),
              count: state.unreadFor(const MailView.priority()),
              onTap: () => state.setView(const MailView.priority()),
            ),
            row(
              icon: CupertinoIcons.arrowshape_turn_up_left,
              label: 'Needs Reply',
              selected: state.view == const MailView.needsReply(),
              count: state.unreadFor(const MailView.needsReply()),
              onTap: () => state.setView(const MailView.needsReply()),
            ),
          ],
          if (state.userData.snoozes.isNotEmpty)
            row(
              icon: CupertinoIcons.alarm,
              label: 'Reminders',
              selected: state.view == const MailView.snoozed(),
              count: state.unreadFor(const MailView.snoozed()),
              onTap: () => state.setView(const MailView.snoozed()),
            ),
          if (state.userData.scheduled.isNotEmpty)
            row(
              icon: CupertinoIcons.clock,
              label: 'Send Later',
              selected: state.view == const MailView.scheduled(),
              count: state.unreadFor(const MailView.scheduled()),
              onTap: () => state.setView(const MailView.scheduled()),
            ),
          if (state.userData.followUps.isNotEmpty)
            row(
              icon: CupertinoIcons.bell,
              label: 'Follow Up',
              selected: state.view == const MailView.followUp(),
              count: state.unreadFor(const MailView.followUp()),
              onTap: () => state.setView(const MailView.followUp()),
            ),
        ],
        for (final s in state.sessions) ...[
          _SidebarHeader(
            text: s.config.email,
            open: !multi || _expandedAccounts.contains(s.id),
            onToggle: () => setState(() =>
                _expandedAccounts.contains(s.id) ? _expandedAccounts.remove(s.id) : _expandedAccounts.add(s.id)),
            trailing: switch (s.status) {
              ConnectionStatus.connecting =>
                const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.2)),
              ConnectionStatus.failed => Tooltip(
                  message: '${s.error ?? 'Not connected'}\nClick to retry.',
                  child: InkWell(
                    onTap: () => state.reconnect(s),
                    child: const Icon(CupertinoIcons.exclamationmark_triangle, size: 13, color: Color(0xFFFF9500)),
                  ),
                ),
              _ => null,
            },
          ),
          if (!multi || _expandedAccounts.contains(s.id))
            for (final b in s.mailboxes)
              row(
                icon: mailboxIcon(b),
                label: b.isInbox ? 'Inbox' : b.name,
                // Subfolders are indented under their parent, like Mail.
                indent: folderDepth(b, s.mailboxes),
                onDrop: dropInto(s, b),
                selected: state.view == MailView.folder(s.id, b.path),
                count: b.isInbox ? state.unreadFor(MailView.folder(s.id, b.path)) : state.folderUnread(s, b),
                onTap: () => state.openFolder(s, b),
              ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: c.secondaryLabel),
              icon: const Icon(CupertinoIcons.add, size: 13),
              label: const Text('Add Account'),
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AccountSetupPage())),
            ),
          ),
        ),
      ],
    );

    final body = Column(children: [
      Expanded(child: list),
      if (widget.onSettings != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
          child: Row(children: [
            ToolButton(icon: CupertinoIcons.gear, tooltip: 'Settings (⌘,)', onPressed: widget.onSettings),
            const Spacer(),
            if (state.indexing)
              Text('Indexing…', style: TextStyle(fontSize: 10, color: c.tertiaryLabel)),
          ]),
        ),
      if (state.aiError != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 8, 10),
          child: Row(children: [
            const Icon(CupertinoIcons.exclamationmark_triangle, size: 13, color: Color(0xFFFF9500)),
            const SizedBox(width: 6),
            Expanded(
              child: Text('AI offline: ${state.aiError}',
                  style: TextStyle(fontSize: 11, color: c.secondaryLabel), maxLines: 3, overflow: TextOverflow.ellipsis),
            ),
            ToolButton(icon: CupertinoIcons.arrow_clockwise, tooltip: 'Retry', size: 13, onPressed: state.refreshAi),
          ]),
        ),
    ]);

    if (useMacWindow) {
      return TransparentMacOSSidebar(child: Material(type: MaterialType.transparency, child: body));
    }
    return Material(color: c.sidebar, child: body);
  }
}

class _SidebarHeader extends StatefulWidget {
  const _SidebarHeader({required this.text, required this.open, required this.onToggle, this.trailing});
  final String text;
  final bool open;
  final VoidCallback onToggle;
  final Widget? trailing;

  @override
  State<_SidebarHeader> createState() => _SidebarHeaderState();
}

class _SidebarHeaderState extends State<_SidebarHeader> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 12, 4),
          child: Row(children: [
            Expanded(
              child: Text(widget.text,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: c.secondaryLabel)),
            ),
            ?widget.trailing,
            // Like Finder and Mail: the disclosure chevron appears on hover.
            AnimatedOpacity(
              opacity: _hover ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(widget.open ? CupertinoIcons.chevron_down : CupertinoIcons.chevron_right,
                    size: 11, color: c.secondaryLabel),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _SidebarRow extends StatelessWidget {
  const _SidebarRow({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.iconColor,
    this.count = 0,
    this.indent = 0,
    this.onDrop,
    this.expanded,
    this.onToggle,
  });

  /// Nesting depth of a subfolder.
  final int indent;

  /// Shows a disclosure chevron when not null.
  final bool? expanded;
  final VoidCallback? onToggle;

  /// Accepts messages dragged from the list (folders only).
  final void Function(List<MimeMessage> messages)? onDrop;

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color iconColor;
  final int count;

  @override
  Widget build(BuildContext context) {
    final drop = onDrop;
    if (drop == null) return _row(context, false);
    return DragTarget<List<MimeMessage>>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => drop(d.data),
      builder: (context, candidates, _) => _row(context, candidates.isNotEmpty),
    );
  }

  Widget _row(BuildContext context, bool hovering) {
    final c = MacColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Material(
        color: hovering ? c.accent.withValues(alpha: 0.25) : (selected ? c.sidebarSelection : Colors.transparent),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          hoverColor: Colors.transparent,
          onTap: onTap,
          child: SizedBox(
            height: 28,
            child: Row(children: [
              SizedBox(width: 2 + 16.0 * indent),
              // Room for a disclosure chevron on every row, so icons line up.
              SizedBox(
                width: 16,
                child: expanded == null
                    ? null
                    : GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onToggle,
                        child: SizedBox(
                          height: 28,
                          child: Icon(expanded! ? CupertinoIcons.chevron_down : CupertinoIcons.chevron_right,
                              size: 10, color: c.secondaryLabel),
                        ),
                      ),
              ),
              const SizedBox(width: 4),
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: c.label)),
              ),
              if (count > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text('$count', style: TextStyle(fontSize: 12, color: c.secondaryLabel)),
                ),
              const SizedBox(width: 8),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Small gray label naming the account a message belongs to.
class AccountBadge extends StatelessWidget {
  const AccountBadge({super.key, required this.config, required this.index});

  final AccountConfig config;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(
        child: Text(config.email,
            overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: MacColors.of(context).secondaryLabel)),
      ),
    ]);
  }
}


/// How deep [b] is nested under folders that are actually listed (so
/// Gmail's "[Gmail]/Sent Mail" isn't indented under a hidden "[Gmail]").
int folderDepth(Mailbox b, List<Mailbox> all) {
  final sep = b.pathSeparator;
  if (sep.isEmpty || !b.path.contains(sep)) return 0;
  final paths = {for (final x in all) x.path};
  final parts = b.path.split(sep);
  var depth = 0;
  for (var i = 1; i < parts.length; i++) {
    if (paths.contains(parts.sublist(0, i).join(sep))) depth++;
  }
  return depth;
}

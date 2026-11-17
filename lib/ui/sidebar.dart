import 'package:enough_mail/enough_mail.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/account_config.dart';
import '../models/triage.dart';
import '../state/app_state.dart';
import 'account_setup_page.dart';

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
      Color(0xFF5B5BD6),
      Color(0xFF12A594),
      Color(0xFFF76B15),
      Color(0xFFD6409F),
      Color(0xFF0090FF),
      Color(0xFF30A46C),
      Color(0xFFE5484D),
      Color(0xFF8E4EC6),
    ][index % 8];

IconData mailboxIcon(Mailbox b) {
  if (b.isInbox) return Icons.inbox_outlined;
  if (b.isSent) return Icons.send_outlined;
  if (b.isDrafts) return Icons.edit_note;
  if (b.isTrash) return Icons.delete_outline;
  if (b.isJunk) return Icons.report_gmailerrorred;
  if (b.isArchive) return Icons.archive_outlined;
  if (b.hasFlag(MailboxFlag.all)) return Icons.all_inbox_outlined;
  if (b.hasFlag(MailboxFlag.flagged)) return Icons.star_outline;
  return Icons.folder_outlined;
}

class Sidebar extends StatefulWidget {
  const Sidebar({super.key, this.onNavigate});

  /// Called after the user picks something (closes the drawer on phones).
  final VoidCallback? onNavigate;

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  final _expanded = <String>{};

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget item({
      required Widget leading,
      required String label,
      required bool selected,
      required VoidCallback onTap,
      int count = 0,
      double indent = 0,
      Widget? trailing,
    }) {
      return Padding(
        padding: EdgeInsets.only(left: 8 + indent, right: 8, top: 1, bottom: 1),
        child: Material(
          color: selected ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              onTap();
              widget.onNavigate?.call();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(children: [
                SizedBox(width: 18, child: Center(child: leading)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(label,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: selected ? FontWeight.w600 : FontWeight.normal)),
                ),
                if (count > 0)
                  Text('$count', style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                ?trailing,
              ]),
            ),
          ),
        ),
      );
    }

    Icon icon(IconData i, [Color? c]) => Icon(i, size: 18, color: c ?? scheme.onSurfaceVariant);
    Widget dot(Color c, [double size = 10]) =>
        Container(width: size, height: size, decoration: BoxDecoration(color: c, shape: BoxShape.circle));

    Widget header(String text, {Widget? trailing}) => Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 12, 4),
          child: Row(children: [
            Expanded(
              child: Text(text.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 0.8, color: scheme.onSurfaceVariant)),
            ),
            ?trailing,
          ]),
        );

    final usedCategories = <MailCategory>{
      for (final m in state.allInboxMessages)
        if (state.triageOf(m) case final t?) t.category,
    };
    final multi = state.sessions.length > 1;

    return Container(
      color: scheme.surfaceContainerLow,
      child: Column(children: [
        Expanded(
          child: ListView(padding: const EdgeInsets.only(top: 8, bottom: 12), children: [
            item(
              leading: icon(Icons.all_inbox_rounded, scheme.primary),
              label: multi ? 'All Inboxes' : 'Inbox',
              selected: state.view == const MailView.allInboxes(),
              count: state.unreadFor(const MailView.allInboxes()),
              onTap: () => state.setView(const MailView.allInboxes()),
            ),
            if (state.userData.vips.isNotEmpty)
              item(
                leading: icon(Icons.star_rounded, const Color(0xFFFFB224)),
                label: 'VIPs',
                selected: state.view == const MailView.vip(),
                count: state.unreadFor(const MailView.vip()),
                onTap: () => state.setView(const MailView.vip()),
              ),
            if (state.userData.snoozes.isNotEmpty)
              item(
                leading: icon(Icons.alarm),
                label: 'Reminders',
                selected: state.view == const MailView.snoozed(),
                count: state.unreadFor(const MailView.snoozed()),
                onTap: () => state.setView(const MailView.snoozed()),
              ),
            if (state.userData.scheduled.isNotEmpty)
              item(
                leading: icon(Icons.schedule_send),
                label: 'Scheduled',
                selected: state.view == const MailView.scheduled(),
                count: state.unreadFor(const MailView.scheduled()),
                onTap: () => state.setView(const MailView.scheduled()),
              ),
            if (state.userData.followUps.isNotEmpty)
              item(
                leading: icon(Icons.notification_important_outlined, state.dueFollowUps.isEmpty ? null : scheme.primary),
                label: 'Follow up',
                selected: state.view == const MailView.followUp(),
                count: state.unreadFor(const MailView.followUp()),
                onTap: () => state.setView(const MailView.followUp()),
              ),
            if (state.aiReady) ...[
              header('Smart inbox',
                  trailing: state.sorting
                      ? Text('Sorting ${state.sortDone}/${state.sortTotal}', style: theme.textTheme.labelSmall)
                      : IconButton(
                          icon: const Icon(Icons.auto_awesome, size: 15),
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Re-sort all inboxes with AI',
                          onPressed: () => state.sortInboxes(force: true),
                        )),
              item(
                leading: icon(Icons.priority_high_rounded, const Color(0xFFE5484D)),
                label: 'Priority',
                selected: state.view == const MailView.priority(),
                count: state.unreadFor(const MailView.priority()),
                onTap: () => state.setView(const MailView.priority()),
              ),
              item(
                leading: icon(Icons.reply_rounded, scheme.primary),
                label: 'Needs reply',
                selected: state.view == const MailView.needsReply(),
                count: state.unreadFor(const MailView.needsReply()),
                onTap: () => state.setView(const MailView.needsReply()),
              ),
              for (final c in MailCategory.values)
                if (usedCategories.contains(c))
                  item(
                    leading: dot(categoryColor(c)),
                    label: c.label,
                    selected: state.view == MailView.category(c),
                    count: state.unreadFor(MailView.category(c)),
                    onTap: () => state.setView(MailView.category(c)),
                  ),
            ],
            header('Accounts',
                trailing: IconButton(
                  icon: const Icon(Icons.add, size: 16),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Add account',
                  onPressed: () => Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => const AccountSetupPage())),
                )),
            for (final s in state.sessions) ...[
              item(
                leading: dot(accountColor(state.indexOf(s))),
                label: s.config.email,
                selected: false,
                count: _expanded.contains(s.id) ? 0 : s.inboxMessages.where((m) => !m.isSeen).length,
                onTap: () => setState(() => _expanded.contains(s.id) ? _expanded.remove(s.id) : _expanded.add(s.id)),
                trailing: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: switch (s.status) {
                    ConnectionStatus.connecting => const SizedBox(
                        width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                    ConnectionStatus.failed => Tooltip(
                        message: '${s.error ?? 'Not connected'}\nClick to retry.',
                        child: InkWell(
                          onTap: () => state.reconnect(s),
                          child: Icon(Icons.error_outline, size: 16, color: scheme.error),
                        ),
                      ),
                    _ => Icon(_expanded.contains(s.id) ? Icons.expand_less : Icons.expand_more, size: 16),
                  },
                ),
              ),
              if (_expanded.contains(s.id))
                for (final b in s.mailboxes)
                  item(
                    indent: 16,
                    leading: icon(mailboxIcon(b)),
                    label: b.isInbox ? 'Inbox' : b.name,
                    selected: state.view == MailView.folder(s.id, b.path),
                    count: b.isInbox ? s.inboxMessages.where((m) => !m.isSeen).length : 0,
                    onTap: () => state.openFolder(s, b),
                  ),
            ],
          ]),
        ),
        if (state.aiError != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Icon(Icons.warning_amber_rounded, size: 16, color: scheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text('AI offline: ${state.aiError}',
                    style: theme.textTheme.labelSmall, maxLines: 3, overflow: TextOverflow.ellipsis),
              ),
              IconButton(icon: const Icon(Icons.refresh, size: 16), tooltip: 'Retry', onPressed: state.refreshAi),
            ]),
          ),
      ]),
    );
  }
}

/// Small colored label naming the account a message belongs to.
class AccountBadge extends StatelessWidget {
  const AccountBadge({super.key, required this.config, required this.index});

  final AccountConfig config;
  final int index;

  @override
  Widget build(BuildContext context) {
    final color = accountColor(index);
    final label = config.email;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 4),
      Flexible(
        child: Text(label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ),
    ]);
  }
}

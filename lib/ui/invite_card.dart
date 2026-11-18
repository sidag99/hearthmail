import 'package:enough_mail/enough_mail.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/calendar_invite.dart';
import '../services/mail_service.dart';
import '../state/app_state.dart';

/// A meeting invitation: title, time, place, organizer and Accept / Maybe /
/// Decline buttons. Shows nothing if [message] has no invitation. Mount it
/// above the message body.
class InviteCard extends StatefulWidget {
  const InviteCard(this.message, {super.key});

  final MimeMessage message;

  @override
  State<InviteCard> createState() => _InviteCardState();
}

class _InviteCardState extends State<InviteCard> {
  PartStat? _sending;

  /// "Mon, Nov 23, 3:00 – 4:00 PM" (in the viewer's time zone).
  static String when(Invite i) {
    final start = i.allDay ? i.start : i.start.toLocal();
    final end = i.displayEnd == null ? null : (i.allDay ? i.displayEnd! : i.displayEnd!.toLocal());
    final day = DateFormat('EEE, MMM d');
    final dayY = DateFormat('EEE, MMM d, y');
    final time = DateFormat.jm();
    bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
    final thisYear = start.year == DateTime.now().year;
    final d0 = (thisYear ? day : dayY).format(start);
    if (i.allDay) {
      if (end == null || sameDay(start, end)) return '$d0, all day';
      return '$d0 – ${(thisYear ? day : dayY).format(end)}';
    }
    if (end == null) return '$d0, ${time.format(start)}';
    if (sameDay(start, end)) return '$d0, ${time.format(start)} – ${time.format(end)}';
    return '$d0, ${time.format(start)} – ${(thisYear ? day : dayY).format(end)}, ${time.format(end)}';
  }

  Future<void> _answer(AppState state, Invite invite, PartStat stat) async {
    // The answer goes to the invitation's organizer. If that isn't who
    // sent the email, check first: a forged invite could make your account
    // write to someone else.
    final sender = MailService.senderOf(widget.message)?.email.toLowerCase() ?? '';
    final organizer = invite.organizerEmail.toLowerCase();
    if (organizer.isNotEmpty && organizer != sender) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Send your answer to the organizer?'),
          content: Text('This invitation was sent by ${sender.isEmpty ? 'an unknown sender' : sender}, '
              'but your answer goes to the organizer, ${invite.organizerEmail}.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Send')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _sending = stat);
    try {
      await state.respondToInvite(widget.message, invite, stat);
    } finally {
      if (mounted) setState(() => _sending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final invite = state.inviteOf(widget.message);
    if (invite == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    final answer = state.inviteAnswerOf(invite);
    final cancelled = invite.isCancel;
    final organizerIsMe = invite.organizerEmail.isNotEmpty &&
        state.accounts.any((a) => a.email.toLowerCase() == invite.organizerEmail.toLowerCase());
    final canAnswer = !cancelled && !organizerIsMe && invite.organizer != null;
    final busy = _sending != null;

    Widget line(IconData icon, String text) => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 15, color: muted),
              const SizedBox(width: 8),
              Expanded(child: Text(text, style: const TextStyle(fontSize: 13, height: 1.3))),
            ],
          ),
        );

    ButtonStyle style(PartStat s) => answer == s
        ? FilledButton.styleFrom(visualDensity: VisualDensity.compact)
        : OutlinedButton.styleFrom(visualDensity: VisualDensity.compact);

    Widget button(PartStat s, String label) {
      final onPressed = busy ? null : () => _answer(state, invite, s);
      final child = _sending == s
          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5))
          : Text(label);
      return answer == s
          ? FilledButton(style: style(s), onPressed: onPressed, child: child)
          : OutlinedButton(style: style(s), onPressed: onPressed, child: child);
    }

    final organizer = invite.organizerName.isNotEmpty ? invite.organizerName : invite.organizerEmail;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(cancelled ? Icons.event_busy : Icons.event, size: 18, color: cancelled ? scheme.error : scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  invite.summary,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    decoration: cancelled ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
            ],
          ),
          if (cancelled) line(Icons.info_outline, 'This event was cancelled.'),
          line(Icons.schedule, when(invite) + (invite.isRecurring ? '  (repeats)' : '')),
          if (invite.location.isNotEmpty) line(Icons.place_outlined, invite.location),
          if (organizer.isNotEmpty) line(Icons.person_outline, 'Organizer: $organizer'),
          if (invite.attendees.length > 1)
            line(Icons.group_outlined, '${invite.attendees.length} invited'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (canAnswer) ...[
                button(PartStat.accepted, 'Accept'),
                button(PartStat.tentative, 'Maybe'),
                button(PartStat.declined, 'Decline'),
              ],
              if (!cancelled)
                TextButton.icon(
                  onPressed: () => state.openInviteInCalendar(invite),
                  icon: const Icon(Icons.calendar_month_outlined, size: 16),
                  label: const Text('Add to Calendar'),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                ),
            ],
          ),
          if (answer != null && canAnswer)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('You ${answer.verb} this invitation.', style: TextStyle(fontSize: 12, color: muted)),
            ),
        ],
      ),
    );
  }
}

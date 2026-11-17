import 'dart:async';
import 'dart:convert';

import 'package:enough_mail/enough_mail.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/ai/email_ai.dart';
import '../services/email_html.dart';
import '../services/mail_service.dart';
import '../state/app_state.dart';
import 'compose_page.dart';
import 'email_web_view.dart';
import 'sidebar.dart';
import 'widgets/ai_widgets.dart';

/// Opens the composer as a reply, optionally with an AI draft.
void openReply(BuildContext context, MimeMessage m,
    {bool replyAll = false, String? aiInstruction, String? body}) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => ComposePage(
      replyTo: m,
      replyAll: replyAll,
      aiReplyInstruction: aiInstruction,
      initialBody: body,
    ),
  ));
}

void openForward(BuildContext context, MimeMessage m) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ComposePage(forwardOf: m)));
}

/// "Remind me" times, like Apple Mail and Gmail offer.
List<(String, DateTime)> snoozeChoices([DateTime? from]) {
  final now = from ?? DateTime.now();
  DateTime at(DateTime d, int h) => DateTime(d.year, d.month, d.day, h);
  final tomorrow = now.add(const Duration(days: 1));
  final saturday = now.add(Duration(days: (DateTime.saturday - now.weekday + 7) % 7 == 0 ? 7 : (DateTime.saturday - now.weekday + 7) % 7));
  final monday = now.add(Duration(days: (DateTime.monday - now.weekday + 7) % 7 == 0 ? 7 : (DateTime.monday - now.weekday + 7) % 7));
  return [
    ('In 1 hour', now.add(const Duration(hours: 1))),
    if (now.hour < 17) ('This evening', at(now, 19)),
    ('Tomorrow morning', at(tomorrow, 8)),
    if (now.weekday < DateTime.friday) ('This weekend', at(saturday, 9)),
    ('Next week', at(monday, 8)),
  ];
}

Future<DateTime?> pickDateTime(BuildContext context, {String help = 'Pick a time'}) async {
  final now = DateTime.now();
  final d = await showDatePicker(
    context: context,
    initialDate: now,
    firstDate: now,
    lastDate: now.add(const Duration(days: 365)),
    helpText: help,
  );
  if (d == null || !context.mounted) return null;
  final t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 8, minute: 0));
  if (t == null) return null;
  return DateTime(d.year, d.month, d.day, t.hour, t.minute);
}

class MessageView extends StatelessWidget {
  const MessageView({super.key, this.onBack});

  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final m = state.selected;
    final theme = Theme.of(context);
    if (m == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.mail_outline, size: 48, color: theme.colorScheme.outlineVariant),
          const SizedBox(height: 8),
          Text('No message selected', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline)),
        ]),
      );
    }
    return Column(children: [
      MessageToolbar(message: m, onBack: onBack),
      const Divider(height: 1),
      Expanded(
        child: state.loadingSelected
            ? const Center(child: CircularProgressIndicator())
            // Rebuild everything (incl. AI panels) when the message changes.
            : _MessageBody(key: ObjectKey(m), message: m),
      ),
    ]);
  }
}

class MessageToolbar extends StatelessWidget {
  const MessageToolbar({super.key, required this.message, this.onBack});
  final MimeMessage message;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final m = message;
    final sender = MailService.senderOf(m)?.email;
    final owner = state.sessionOf(m);
    final here = state.mailboxOf(m);
    final narrow = MediaQuery.sizeOf(context).width < 700;

    Future<void> snoozeMenu(Offset? at) async {
      final choice = await showMenu<Object>(
        context: context,
        position: RelativeRect.fromLTRB(at?.dx ?? 400, at?.dy ?? 60, at?.dx ?? 400, 0),
        items: [
          for (final (label, time) in snoozeChoices())
            PopupMenuItem(value: time, child: Text('$label  ·  ${DateFormat('E HH:mm').format(time)}')),
          const PopupMenuItem(value: 'custom', child: Text('Pick date & time…')),
          if (state.snoozeOf(m) != null) const PopupMenuItem(value: 'cancel', child: Text('Cancel reminder')),
        ],
      );
      if (!context.mounted) return;
      if (choice is DateTime) {
        await state.snooze(m, choice);
      } else if (choice == 'custom') {
        final when = await pickDateTime(context, help: 'Remind me on');
        if (when != null) await state.snooze(m, when);
      } else if (choice == 'cancel') {
        await state.unsnooze(m);
      }
    }

    Future<void> moveMenu() async {
      final boxes = (owner?.mailboxes ?? const <Mailbox>[]).where((b) => b.path != here?.path).toList();
      final target = await showDialog<Mailbox>(
        context: context,
        builder: (c) => SimpleDialog(
          title: const Text('Move to'),
          children: [
            for (final b in boxes)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(c, b),
                child: Row(children: [Icon(mailboxIcon(b), size: 18), const SizedBox(width: 10), Text(b.isInbox ? 'Inbox' : b.name)]),
              ),
          ],
        ),
      );
      if (target != null) await state.moveMessage(m, target);
    }

    Future<void> confirmBlock() async {
      if (sender == null) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Block $sender?'),
          content: const Text('Their emails will go straight to Junk on this computer. You can unblock them in Settings.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Block')),
          ],
        ),
      );
      if (ok == true) await state.blockSender(sender);
    }

    final more = PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_horiz),
      onSelected: (v) async {
        switch (v) {
          case 'forward':
            openForward(context, m);
          case 'replyAll':
            openReply(context, m, replyAll: true);
          case 'move':
            await moveMenu();
          case 'junk':
            await state.junkMessage(m);
          case 'vip':
            if (sender != null) await state.toggleVip(sender);
          case 'block':
            await confirmBlock();
          case 'mute':
            await state.muteThread(m);
          case 'read':
            await state.toggleRead(m);
        }
      },
      itemBuilder: (_) => [
        if (narrow) const PopupMenuItem(value: 'replyAll', child: Text('Reply all')),
        if (narrow) const PopupMenuItem(value: 'forward', child: Text('Forward')),
        const PopupMenuItem(value: 'move', child: Text('Move to…')),
        const PopupMenuItem(value: 'junk', child: Text('Move to Junk')),
        PopupMenuItem(value: 'read', child: Text(m.isSeen ? 'Mark as unread' : 'Mark as read')),
        const PopupMenuDivider(),
        if (sender != null)
          PopupMenuItem(value: 'vip', child: Text(state.userData.isVip(sender) ? 'Remove from VIPs' : 'Add sender to VIPs')),
        PopupMenuItem(value: 'mute', child: Text(state.isMuted(m) ? 'Unmute conversation' : 'Mute conversation')),
        if (sender != null) PopupMenuItem(value: 'block', child: Text('Block $sender')),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(children: [
        if (onBack != null) IconButton(icon: const Icon(Icons.arrow_back), onPressed: onBack, tooltip: 'Back'),
        IconButton(icon: const Icon(Icons.reply), tooltip: 'Reply (⌘R)', onPressed: () => openReply(context, m)),
        if (!narrow)
          IconButton(
            icon: const Icon(Icons.reply_all),
            tooltip: 'Reply all (⇧⌘R)',
            onPressed: () => openReply(context, m, replyAll: true),
          ),
        if (!narrow)
          IconButton(icon: const Icon(Icons.forward), tooltip: 'Forward (⇧⌘F)', onPressed: () => openForward(context, m)),
        const SizedBox(width: 8),
        IconButton(icon: const Icon(Icons.archive_outlined), tooltip: 'Archive (⌘E)', onPressed: () => state.archiveMessage(m)),
        IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Delete (⌘⌫)', onPressed: () => state.deleteMessage(m)),
        IconButton(
          icon: Icon(m.isFlagged ? Icons.flag : Icons.outlined_flag),
          tooltip: m.isFlagged ? 'Unflag (⇧⌘L)' : 'Flag (⇧⌘L)',
          onPressed: () => state.toggleFlag(m),
        ),
        Builder(
          builder: (bc) => IconButton(
            icon: Icon(state.snoozeOf(m) != null ? Icons.alarm_on : Icons.alarm),
            tooltip: 'Remind me',
            onPressed: () {
              final box = bc.findRenderObject() as RenderBox?;
              snoozeMenu(box?.localToGlobal(Offset(0, box.size.height)));
            },
          ),
        ),
        more,
      ]),
    );
  }
}

class _MessageBody extends StatefulWidget {
  const _MessageBody({super.key, required this.message});
  final MimeMessage message;

  @override
  State<_MessageBody> createState() => _MessageBodyState();
}

class _MessageBodyState extends State<_MessageBody> {
  bool _showSummary = false;
  bool _loadImages = false;
  Future<List<String>>? _quickReplies;
  final _instruction = TextEditingController();

  // Translation
  String? _language;
  String? _translated;
  bool _translating = false;
  bool _showTranslation = false;
  StreamSubscription<String>? _translateSub;

  bool _findingEvent = false;
  bool _unsubscribing = false;

  // Building the page means parsing the HTML; do it once, not every repaint.
  String? _docKey;
  EmailDocument? _doc;

  @override
  void initState() {
    super.initState();
    _detectLanguage();
  }

  Future<void> _detectLanguage() async {
    final state = context.read<AppState>();
    final ai = state.ai;
    if (ai == null) return;
    final text = MailService.bodyText(widget.message);
    final lang = await ai.detectLanguage('${MailService.subjectOf(widget.message)}\n$text');
    if (!mounted || lang == null) return;
    if (lang.toLowerCase() != state.settings.myLanguage.toLowerCase()) setState(() => _language = lang);
  }

  void _translate(AppState state) {
    if (_translated != null) {
      setState(() => _showTranslation = true);
      return;
    }
    final ai = state.ai;
    if (ai == null) return;
    final buf = StringBuffer();
    setState(() {
      _translating = true;
      _showTranslation = true;
      _translated = '';
    });
    final m = widget.message;
    _translateSub = ai
        .translate('${MailService.subjectOf(m)}\n\n${MailService.bodyText(m)}', state.settings.myLanguage, source: _language)
        .listen((chunk) {
      buf.write(chunk);
      if (mounted) setState(() => _translated = buf.toString());
    }, onError: (Object e) {
      state.toast('Translation failed: $e');
      if (mounted) {
        setState(() {
          _translating = false;
          _translated = null;
          _showTranslation = false;
        });
      }
    }, onDone: () {
      if (mounted) setState(() => _translating = false);
    });
  }

  Future<void> _addToCalendar(AppState state) async {
    final ai = state.ai;
    if (ai == null) return;
    setState(() => _findingEvent = true);
    try {
      final event = await ai.extractEvent(state.contentOf(widget.message));
      if (!mounted) return;
      if (event == null) {
        state.toast('No date or event found in this email.');
        return;
      }
      final fmt = event.allDay ? DateFormat.yMMMEd() : DateFormat.yMMMEd().add_jm();
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Add to Calendar?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(event.title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(fmt.format(event.start) + (event.end == null ? '' : ' – ${fmt.format(event.end!)}')),
            if (event.location.isNotEmpty) Text(event.location),
            const SizedBox(height: 10),
            Text('Found by AI: check the details. Calendar opens so you can confirm.',
                style: Theme.of(c).textTheme.bodySmall),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Open in Calendar')),
          ],
        ),
      );
      if (ok == true) await state.addToCalendar(event, widget.message);
    } catch (e) {
      state.toast('Could not read the event: $e');
    } finally {
      if (mounted) setState(() => _findingEvent = false);
    }
  }

  Future<void> _unsubscribe(AppState state) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Unsubscribe from ${MailService.senderName(widget.message)}?'),
        content: const Text('Lumen Mail will ask the sender to stop sending you these emails.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Unsubscribe')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _unsubscribing = true);
    try {
      state.toast(await state.unsubscribe(widget.message));
    } catch (e) {
      state.toast('Could not unsubscribe: ${AppState.friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _unsubscribing = false);
    }
  }

  EmailDocument _document(MimeMessage m, bool allowImages, bool dark) {
    final key = '$allowImages|$dark|$_showTranslation|${_translated?.length}';
    if (key == _docKey && _doc != null) return _doc!;
    _docKey = key;
    final html = m.decodeTextHtmlPart();
    if (_showTranslation && _translated != null) {
      _doc = EmailDocument.fromPlain(_translated!.isEmpty ? 'Translating…' : _translated!, dark: dark);
    } else if (html != null && html.trim().isNotEmpty) {
      _doc = EmailDocument.fromHtml(html, allowRemote: allowImages, inlineImage: (cid) => _inline(m, cid));
    } else {
      _doc = EmailDocument.fromPlain(m.decodeTextPlainPart() ?? MailService.bodyText(m), dark: dark);
    }
    return _doc!;
  }

  static String? _inline(MimeMessage m, String cid) {
    final part = m.getPartWithContentId(cid);
    final bytes = part?.decodeContentBinary();
    if (part == null || bytes == null) return null;
    final type = part.getHeaderContentType()?.mediaType.text ?? 'image/png';
    return 'data:$type;base64,${base64Encode(bytes)}';
  }

  @override
  void dispose() {
    _instruction.dispose();
    _translateSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final m = widget.message;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final sender = MailService.senderOf(m);
    final date = MailService.dateOf(m);
    final allowImages = _loadImages || state.settings.loadRemoteImages;
    final doc = _document(m, allowImages, dark);
    final isHtml = !(_showTranslation && _translated != null) && (m.decodeTextHtmlPart()?.trim().isNotEmpty ?? false);
    final triage = state.triageOf(m);
    final owner = state.sessions.length > 1 ? state.sessionOf(m) : null;
    final suspicion = MailService.suspicionOf(m) ?? (triage?.suspicious == true ? 'The AI thinks this email may be a phishing or scam attempt.' : null);
    final unsub = MailService.unsubscribeOf(m);
    final snooze = state.snoozeOf(m);
    final vip = sender != null && state.userData.isVip(sender.email);
    final attachments = m.findContentInfo(disposition: ContentDisposition.attachment);

    Widget banner(IconData icon, Color color, Widget text, {List<Widget> actions = const []}) => Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(child: DefaultTextStyle.merge(style: theme.textTheme.bodySmall, child: text)),
            ...actions,
          ]),
        );

    final header = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SelectableText(MailService.subjectOf(m), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 12),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CircleAvatar(radius: 18, child: Text(MailService.senderName(m).characters.first.toUpperCase())),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: SelectableText.rich(TextSpan(children: [
                  TextSpan(text: MailService.senderName(m), style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (sender != null && sender.personalName?.isNotEmpty == true)
                    TextSpan(text: '  <${sender.email}>', style: TextStyle(color: scheme.onSurfaceVariant)),
                ])),
              ),
              if (sender != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  icon: Icon(vip ? Icons.star_rounded : Icons.star_outline_rounded, color: vip ? const Color(0xFFFFB224) : null),
                  tooltip: vip ? 'VIP · click to remove' : 'Add to VIPs',
                  onPressed: () => state.toggleVip(sender.email),
                ),
            ]),
            Text(
                'To: ${MailService.displayList(m.to)}'
                '${(m.cc ?? []).isEmpty ? '' : '   Cc: ${MailService.displayList(m.cc)}'}',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (date != null)
            Text(DateFormat.yMMMd().add_jm().format(date.toLocal()),
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          if (owner != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: AccountBadge(config: owner.config, index: state.indexOf(owner)),
            ),
        ]),
      ]),
      if (suspicion != null)
        banner(Icons.gpp_maybe_outlined, scheme.error, Text('Be careful: $suspicion Don\'t click links or share passwords or codes.')),
      if (snooze != null && !snooze.isDue)
        banner(Icons.alarm, scheme.primary, Text('Reminder set for ${DateFormat('E d MMM, HH:mm').format(snooze.until)}'),
            actions: [TextButton(onPressed: () => state.unsnooze(m), child: const Text('Cancel'))]),
      if (_language != null || _showTranslation)
        banner(
          Icons.translate,
          scheme.primary,
          Text(_showTranslation
              ? (_translating ? 'Translating from ${_language ?? 'the original'}…' : 'Translated from ${_language ?? 'the original'} by your local AI')
              : 'This email is in $_language.'),
          actions: [
            TextButton(
              onPressed: _translating
                  ? null
                  : () => _showTranslation ? setState(() => _showTranslation = false) : _translate(state),
              child: Text(_showTranslation ? 'Show original' : 'Translate to ${state.settings.myLanguage}'),
            ),
          ],
        ),
      if (unsub != null)
        banner(Icons.unsubscribe_outlined, scheme.onSurfaceVariant, const Text('This email is from a mailing list.'),
            actions: [
              TextButton(
                onPressed: _unsubscribing ? null : () => _unsubscribe(state),
                child: Text(_unsubscribing ? 'Unsubscribing…' : 'Unsubscribe'),
              ),
            ]),
      if (isHtml && !allowImages && doc.blockedImages > 0)
        banner(Icons.image_not_supported_outlined, scheme.onSurfaceVariant,
            const Text('Remote images are blocked to protect your privacy.'),
            actions: [TextButton(onPressed: () => setState(() => _loadImages = true), child: const Text('Load images'))]),
      const SizedBox(height: 12),
      if (state.aiReady) ...[
        _aiBar(context, state, m),
        if (_showSummary) ...[
          const SizedBox(height: 10),
          AiCard(
            title: 'Summary',
            onClose: () => setState(() => _showSummary = false),
            child: AiStreamView(placeholder: 'Summarizing…', start: () => state.ai!.summarize(state.contentOf(m))),
          ),
        ],
        if (_quickReplies != null) ...[
          const SizedBox(height: 10),
          _quickReplyCard(context, m),
        ],
        if (triage != null && triage.needsReply && !m.isAnswered && _quickReplies == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('This email looks like it is waiting for your reply.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.primary)),
          ),
      ],
      if (attachments.isNotEmpty) ...[
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final info in attachments) _AttachmentChip(message: m, info: info),
        ]),
      ],
      const SizedBox(height: 10),
    ]);

    return LayoutBuilder(builder: (context, box) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: box.maxHeight * 0.55),
          child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(24, 18, 24, 0), child: header),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              // HTML email is designed for a white page, so it keeps one
              // even in dark mode. Plain text follows the app theme.
              color: isHtml || !dark ? Colors.white : const Color(0xFF1F1F22),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: EmailWebView(html: doc.html, background: isHtml || !dark ? Colors.white : const Color(0xFF1F1F22)),
          ),
        ),
      ]);
    });
  }

  Widget _aiBar(BuildContext context, AppState state, MimeMessage m) {
    return Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      FilledButton.tonalIcon(
        icon: const Icon(Icons.auto_awesome, size: 16),
        label: const Text('Summarize'),
        onPressed: () => setState(() => _showSummary = true),
      ),
      FilledButton.tonalIcon(
        icon: const Icon(Icons.bolt, size: 16),
        label: const Text('Quick replies'),
        onPressed: () {
          final replies = state.ai!.quickReplies(state.contentOf(m));
          setState(() {
            _quickReplies = replies;
          });
        },
      ),
      FilledButton.tonalIcon(
        icon: _findingEvent
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.event, size: 16),
        label: const Text('Add to Calendar'),
        onPressed: _findingEvent ? null : () => _addToCalendar(state),
      ),
      if (_language == null)
        FilledButton.tonalIcon(
          icon: const Icon(Icons.translate, size: 16),
          label: Text(_showTranslation ? 'Original' : 'Translate'),
          onPressed: _translating ? null : () => _showTranslation ? setState(() => _showTranslation = false) : _translate(state),
        ),
      SizedBox(
        width: 340,
        child: TextField(
          controller: _instruction,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Reply with AI: "say yes, but Thursday works better"',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            suffixIcon: IconButton(
              icon: const Icon(Icons.edit_note, size: 18),
              tooltip: 'Draft reply',
              onPressed: () => openReply(context, m, aiInstruction: _instruction.text),
            ),
          ),
          onSubmitted: (v) => openReply(context, m, aiInstruction: v),
        ),
      ),
    ]);
  }

  Widget _quickReplyCard(BuildContext context, MimeMessage m) {
    return AiCard(
      title: 'Quick replies',
      onClose: () => setState(() => _quickReplies = null),
      child: FutureBuilder<List<String>>(
        future: _quickReplies,
        builder: (context, snap) {
          if (snap.hasError) {
            return Text('${snap.error}', style: TextStyle(color: Theme.of(context).colorScheme.error));
          }
          if (!snap.hasData) {
            return const LinearProgressIndicator();
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final r in snap.data!)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  ),
                  // Expand the short reply into a full email, keeping its meaning.
                  onPressed: () => openReply(context, m, aiInstruction: r),
                  child: Text(r, textAlign: TextAlign.left),
                ),
              ),
            Text('Click one to turn it into a full reply you can edit.', style: Theme.of(context).textTheme.labelSmall),
          ]);
        },
      ),
    );
  }
}

class _AttachmentChip extends StatefulWidget {
  const _AttachmentChip({required this.message, required this.info});
  final MimeMessage message;
  final ContentInfo info;

  @override
  State<_AttachmentChip> createState() => _AttachmentChipState();
}

class _AttachmentChipState extends State<_AttachmentChip> {
  bool _busy = false;

  Future<void> _run(bool open) async {
    final state = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final f = await state.saveAttachment(widget.message, widget.info, open: open);
      if (!open) state.toast('Saved to ${f.path}');
    } catch (e) {
      state.toast('Could not ${open ? 'open' : 'save'} the attachment: ${AppState.friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.info.size;
    final label = '${widget.info.fileName ?? 'attachment'}${size == null ? '' : '  ·  ${_size(size)}'}';
    return InputChip(
      avatar: _busy
          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(widget.info.isImage ? Icons.image_outlined : Icons.attach_file, size: 16),
      label: Text(label),
      tooltip: 'Click to open',
      onPressed: _busy ? null : () => _run(true),
      deleteIcon: const Icon(Icons.download, size: 16),
      deleteButtonTooltipMessage: 'Save to Downloads',
      onDeleted: _busy ? null : () => _run(false),
    );
  }

  static String _size(int b) => b < 1024
      ? '$b B'
      : b < 1024 * 1024
          ? '${(b / 1024).toStringAsFixed(0)} KB'
          : '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// For the event dialog and tests.
typedef EventFinder = Future<EmailEvent?> Function();

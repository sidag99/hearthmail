import 'dart:async';
import 'dart:convert';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/ai/email_ai.dart';
import '../services/email_html.dart';
import '../services/mail_service.dart';
import '../state/app_state.dart';
import 'compose_page.dart';
import 'conversation_view.dart';
import 'email_web_view.dart';
import 'invite_card.dart';
import 'mac_style.dart';
import 'sidebar.dart';
import 'widgets/ai_widgets.dart';

/// Opens the composer as a reply, optionally with an AI draft.
void openReply(
  BuildContext context,
  MimeMessage m, {
  bool replyAll = false,
  String? aiInstruction,
  String? body,
}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ComposePage(
        replyTo: m,
        replyAll: replyAll,
        aiReplyInstruction: aiInstruction,
        initialBody: body,
      ),
    ),
  );
}

void openForward(BuildContext context, MimeMessage m) {
  Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => ComposePage(forwardOf: m)));
}

/// Opens a message from a Drafts folder in the composer to keep writing.
/// Saving or sending replaces the old draft.
Future<void> openDraft(BuildContext context, MimeMessage m) async {
  final state = context.read<AppState>();
  try {
    final mail = await state.draftToOutgoing(m);
    if (!context.mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => ComposePage(restore: mail)));
  } catch (e) {
    state.toast('Could not open the draft: ${AppState.friendlyError(e)}');
  }
}

/// "Remind me" times, like Apple Mail and Gmail offer.
List<(String, DateTime)> snoozeChoices([DateTime? from]) {
  final now = from ?? DateTime.now();
  DateTime at(DateTime d, int h) => DateTime(d.year, d.month, d.day, h);
  final tomorrow = now.add(const Duration(days: 1));
  final saturday = now.add(
    Duration(
      days: (DateTime.saturday - now.weekday + 7) % 7 == 0
          ? 7
          : (DateTime.saturday - now.weekday + 7) % 7,
    ),
  );
  final monday = now.add(
    Duration(
      days: (DateTime.monday - now.weekday + 7) % 7 == 0
          ? 7
          : (DateTime.monday - now.weekday + 7) % 7,
    ),
  );
  return [
    ('In 1 hour', now.add(const Duration(hours: 1))),
    if (now.hour < 17) ('This evening', at(now, 19)),
    ('Tomorrow morning', at(tomorrow, 8)),
    if (now.weekday < DateTime.friday) ('This weekend', at(saturday, 9)),
    ('Next week', at(monday, 8)),
  ];
}

Future<DateTime?> pickDateTime(
  BuildContext context, {
  String help = 'Pick a time',
}) async {
  final now = DateTime.now();
  final d = await showDatePicker(
    context: context,
    initialDate: now,
    firstDate: now,
    lastDate: now.add(const Duration(days: 365)),
    helpText: help,
  );
  if (d == null || !context.mounted) return null;
  final t = await showTimePicker(
    context: context,
    initialTime: const TimeOfDay(hour: 8, minute: 0),
  );
  if (t == null) return null;
  return DateTime(d.year, d.month, d.day, t.hour, t.minute);
}

class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    this.onBack,
    this.search,
    this.leadingInset = 0,
  });

  final VoidCallback? onBack;

  /// Room for the window's traffic lights when this pane is leftmost.
  final double leadingInset;

  /// The search field, shown at the right end of the toolbar (wide windows).
  final Widget? search;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final m = state.selected;
    final c = MacColors.of(context);
    return ColoredBox(
      color: c.window,
      child: Column(
        children: [
          SizedBox(
            height: kToolbarHeight52,
            child: MessageToolbar(
              message: m,
              onBack: onBack,
              search: search,
              leadingInset: leadingInset,
            ),
          ),
          const Hairline(),
          Expanded(
            child: state.hasMulti
                ? _MultiSelection(count: state.multi.length)
                : m == null
                ? Center(
                    child: Text(
                      'No Message Selected',
                      style: TextStyle(
                        fontSize: 15,
                        color: c.tertiaryLabel,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  )
                : state.loadingSelected
                ? const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                // A new body (incl. AI panels) for each message; the key
                // also lets the toolbar's ✨ menu reach it.
                : _MessageBody(key: _bodyKey(m), message: m),
          ),
        ],
      ),
    );
  }
}

GlobalObjectKey<_MessageBodyState> _bodyKey(MimeMessage m) =>
    GlobalObjectKey<_MessageBodyState>(m);

/// Mail's toolbar: archive, delete, junk · reply, reply all, forward · flag,
/// remind · ✨ AI · more, then search.
class MessageToolbar extends StatelessWidget {
  const MessageToolbar({
    super.key,
    required this.message,
    this.onBack,
    this.search,
    this.leadingInset = 0,
  });
  final double leadingInset;
  final MimeMessage? message;
  final VoidCallback? onBack;
  final Widget? search;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final m = message;
    final c = MacColors.of(context);
    return LayoutBuilder(
      builder: (context, box) =>
          _build(context, state, m, c, box.maxWidth - leadingInset),
    );
  }

  Widget _build(
    BuildContext context,
    AppState state,
    MimeMessage? m,
    MacColors c,
    double width,
  ) {
    // Fold the less-used buttons into ⋯ and shrink or drop the search
    // field so nothing overflows at any window size.
    final narrow = width < 660;
    final searchWidth = search == null
        ? 0.0
        : (width - (narrow ? 330 : 440)).clamp(0.0, 230.0);
    VoidCallback? on(void Function(MimeMessage m) f) =>
        m == null ? null : () => f(m);
    // Archive, delete, junk and flag act on every selected message.
    VoidCallback? onAll(Future<void> Function(List<MimeMessage> ms) f) =>
        m == null ? null : () => f(state.targets);

    Future<void> snoozeMenu(BuildContext bc) async {
      if (m == null) return;
      final box = bc.findRenderObject() as RenderBox?;
      final at =
          box?.localToGlobal(Offset(0, box.size.height)) ??
          const Offset(400, 60);
      final choice = await showMenu<Object>(
        popUpAnimationStyle: AnimationStyle.noAnimation,
        context: context,
        position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, 0),
        items: [
          for (final (label, time) in snoozeChoices())
            PopupMenuItem(
              value: time,
              height: 32,
              child: Text('$label  ·  ${DateFormat('E HH:mm').format(time)}'),
            ),
          const PopupMenuItem(
            value: 'custom',
            height: 32,
            child: Text('Pick Date & Time…'),
          ),
          if (state.snoozeOf(m) != null)
            const PopupMenuItem(
              value: 'cancel',
              height: 32,
              child: Text('Cancel Reminder'),
            ),
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

    final body = m == null ? null : _bodyKey(m).currentState;
    final aiMenu = ToolbarItem(
      child: PopupMenuButton<String>(
        popUpAnimationStyle: AnimationStyle.noAnimation,
        tooltip: 'AI Tools',
        enabled: m != null && state.aiReady,
        onSelected: (v) {
          final b = m == null ? null : _bodyKey(m).currentState;
          switch (v) {
            case 'summary':
              b?.showSummary();
            case 'replies':
              b?.showQuickReplies();
            case 'reply':
              b?.replyWithAi();
            case 'translate':
              b?.translateNow();
            case 'calendar':
              b?.addToCalendarNow();
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: 'summary',
            height: 32,
            child: Text('Summarize'),
          ),
          const PopupMenuItem(
            value: 'replies',
            height: 32,
            child: Text('Quick Replies'),
          ),
          const PopupMenuItem(
            value: 'reply',
            height: 32,
            child: Text('Reply with AI…'),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'translate',
            height: 32,
            child: Text(
              body?.showingTranslation == true ? 'Show Original' : 'Translate',
            ),
          ),
          const PopupMenuItem(
            value: 'calendar',
            height: 32,
            child: Text('Add to Calendar'),
          ),
        ],
        child: SizedBox(
          width: 32,
          height: 28,
          child: Icon(
            CupertinoIcons.sparkles,
            size: 17,
            color: m != null && state.aiReady
                ? c.secondaryLabel
                : c.tertiaryLabel,
          ),
        ),
      ),
    );

    final more = ToolbarItem(
      child: PopupMenuButton<String>(
        popUpAnimationStyle: AnimationStyle.noAnimation,
        tooltip: 'More',
        enabled: m != null,
        onSelected: (v) async {
          if (m == null) return;
          final sender = MailService.senderOf(m)?.email;
          switch (v) {
            case 'forward':
              openForward(context, m);
            case 'replyAll':
              openReply(context, m, replyAll: true);
            case 'junk':
              await state.junkMessage(m);
            case 'read':
              await state.toggleRead(m);
            case 'menu':
              // The full right-click menu has everything else.
              final box = context.findRenderObject() as RenderBox?;
              final at = box == null
                  ? const Offset(600, 60)
                  : box.localToGlobal(
                      Offset(box.size.width - 200, box.size.height),
                    );
              if (context.mounted) await showMessageMenu(context, m, at);
            case 'vip':
              if (sender != null) await state.toggleVip(sender);
            case 'mute':
              await state.muteThread(m);
            case 'headers':
              if (context.mounted) showAllHeaders(context, m);
          }
        },
        itemBuilder: (_) {
          final sender = m == null ? null : MailService.senderOf(m)?.email;
          return [
            if (narrow)
              const PopupMenuItem(
                value: 'replyAll',
                height: 32,
                child: Text('Reply All'),
              ),
            if (narrow)
              const PopupMenuItem(
                value: 'forward',
                height: 32,
                child: Text('Forward'),
              ),
            if (narrow)
              PopupMenuItem(
                value: 'junk',
                height: 32,
                child: Text(
                  m != null && state.isInJunk(m) ? 'Not Junk' : 'Move to Junk',
                ),
              ),
            PopupMenuItem(
              value: 'read',
              height: 32,
              child: Text(
                m?.isSeen == true ? 'Mark as Unread' : 'Mark as Read',
              ),
            ),
            if (sender != null)
              PopupMenuItem(
                value: 'vip',
                height: 32,
                child: Text(
                  state.userData.isVip(sender)
                      ? 'Remove from VIPs'
                      : 'Add Sender to VIPs',
                ),
              ),
            PopupMenuItem(
              value: 'mute',
              height: 32,
              child: Text(
                m != null && state.isMuted(m)
                    ? 'Unmute Conversation'
                    : 'Mute Conversation',
              ),
            ),
            const PopupMenuItem(value: 'headers', height: 32, child: Text('Show All Headers')),
            const PopupMenuItem(
              value: 'menu',
              height: 32,
              child: Text('Move, Block…'),
            ),
          ];
        },
        child: SizedBox(
          width: 32,
          height: 28,
          child: Icon(
            CupertinoIcons.ellipsis_circle,
            size: 17,
            color: m == null ? c.tertiaryLabel : c.secondaryLabel,
          ),
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.only(left: 8 + leadingInset, right: 8),
      child: Row(
        children: [
          if (onBack != null)
            ToolButton(
              icon: CupertinoIcons.chevron_left,
              tooltip: 'Back',
              onPressed: onBack,
            ),
          ToolButton(
            icon: CupertinoIcons.archivebox,
            tooltip: 'Archive (⌃⌘A)',
            onPressed: onAll(state.archiveMessages),
          ),
          ToolButton(
            icon: CupertinoIcons.trash,
            tooltip: 'Delete (⌘⌫)',
            onPressed: onAll(state.deleteMessages),
          ),
          if (!narrow)
            ToolButton(
              icon: m != null && state.isInJunk(m)
                  ? CupertinoIcons.tray_arrow_up
                  : CupertinoIcons.xmark_octagon,
              tooltip: m != null && state.isInJunk(m)
                  ? 'Not Junk (⇧⌘J)'
                  : 'Move to Junk (⇧⌘J)',
              onPressed: onAll(state.junkMessages),
            ),
          const SizedBox(width: 10),
          ToolButton(
            icon: CupertinoIcons.arrowshape_turn_up_left,
            tooltip: 'Reply (⌘R)',
            onPressed: on((m) => openReply(context, m)),
          ),
          if (!narrow)
            ToolButton(
              icon: CupertinoIcons.arrowshape_turn_up_left_2,
              tooltip: 'Reply All (⇧⌘R)',
              onPressed: on((m) => openReply(context, m, replyAll: true)),
            ),
          if (!narrow)
            ToolButton(
              icon: CupertinoIcons.arrowshape_turn_up_right,
              tooltip: 'Forward (⇧⌘F)',
              onPressed: on((m) => openForward(context, m)),
            ),
          const SizedBox(width: 10),
          ToolButton(
            icon: m?.isFlagged == true
                ? CupertinoIcons.flag_fill
                : CupertinoIcons.flag,
            color: m?.isFlagged == true ? kFlagColors[MailService.flagColorOf(m!)] : null,
            tooltip: 'Flag (⇧⌘L)',
            onPressed: onAll(
              (ms) => state.setFlagged(ms, !ms.every((x) => x.isFlagged)),
            ),
          ),
          // Mail's flag colour menu.
          ToolbarItem(
            child: PopupMenuButton<int>(
              popUpAnimationStyle: AnimationStyle.noAnimation,
              tooltip: 'Flag Colour',
              enabled: m != null,
              onSelected: (i) => i < 0
                  ? state.setFlagged(state.targets, false)
                  : state.setFlagColor(state.targets, i),
              itemBuilder: (_) => [
                for (var i = 0; i < MailService.flagColorNames.length; i++)
                  PopupMenuItem(
                    value: i,
                    height: 30,
                    child: Row(children: [
                      Icon(CupertinoIcons.flag_fill, size: 13, color: kFlagColors[i]),
                      const SizedBox(width: 8),
                      Text(MailService.flagColorNames[i]),
                    ]),
                  ),
                const PopupMenuDivider(),
                const PopupMenuItem(value: -1, height: 30, child: Text('Clear Flag')),
              ],
              child: SizedBox(
                width: 14,
                height: 28,
                child: Icon(CupertinoIcons.chevron_down, size: 9, color: MacColors.of(context).secondaryLabel),
              ),
            ),
          ),
          Builder(
            builder: (bc) => ToolButton(
              icon: CupertinoIcons.alarm,
              color: m != null && state.snoozeOf(m) != null
                  ? MacColors.of(context).accent
                  : null,
              tooltip: 'Remind Me',
              onPressed: m == null ? null : () => snoozeMenu(bc),
            ),
          ),
          aiMenu,
          more,
          const Spacer(),
          if (searchWidth >= 120) SizedBox(width: searchWidth, child: search),
        ],
      ),
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
  final _webKey = GlobalKey<EmailWebViewState>();
  double _scrollY = 0;
  double _headerHeight = 0;

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
    final lang = await ai.detectLanguage(
      '${MailService.subjectOf(widget.message)}\n$text',
    );
    if (!mounted || lang == null) return;
    if (lang.toLowerCase() != state.settings.myLanguage.toLowerCase()) {
      setState(() => _language = lang);
    }
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
        .translate(
          '${MailService.subjectOf(m)}\n\n${MailService.bodyText(m)}',
          state.settings.myLanguage,
          source: _language,
        )
        .listen(
          (chunk) {
            buf.write(chunk);
            if (mounted) setState(() => _translated = buf.toString());
          },
          onError: (Object e) {
            state.toast('Translation failed: $e');
            if (mounted) {
              setState(() {
                _translating = false;
                _translated = null;
                _showTranslation = false;
              });
            }
          },
          onDone: () {
            if (mounted) setState(() => _translating = false);
          },
        );
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
      final fmt = event.allDay
          ? DateFormat.yMMMEd()
          : DateFormat.yMMMEd().add_jm();
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Add to Calendar?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                event.title,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                fmt.format(event.start) +
                    (event.end == null ? '' : ' – ${fmt.format(event.end!)}'),
              ),
              if (event.location.isNotEmpty) Text(event.location),
              const SizedBox(height: 10),
              Text(
                'Found by AI: check the details. Calendar opens so you can confirm.',
                style: Theme.of(c).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Open in Calendar'),
            ),
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
        title: Text(
          'Unsubscribe from ${MailService.senderName(widget.message)}?',
        ),
        content: Text(
          'Hearthmail will ask the sender to stop sending you these emails'
          '${state.unsubscribeTarget(widget.message) == null ? '' : ' (via ${state.unsubscribeTarget(widget.message)})'}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Unsubscribe'),
          ),
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
      _doc = EmailDocument.fromPlain(
        _translated!.isEmpty ? 'Translating…' : _translated!,
        dark: dark,
      );
    } else if (html != null && html.trim().isNotEmpty) {
      _doc = EmailDocument.fromHtml(
        html,
        allowRemote: allowImages,
        inlineImage: (cid) => _inline(m, cid),
      );
    } else {
      _doc = EmailDocument.fromPlain(
        m.decodeTextPlainPart() ?? MailService.bodyText(m),
        dark: dark,
      );
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

  // Called from the toolbar's ✨ menu.
  void showSummary() => setState(() => _showSummary = true);
  void showQuickReplies() {
    final state = context.read<AppState>();
    if (state.ai == null) return;
    final replies = state.ai!.quickReplies(state.contentOf(widget.message));
    setState(() {
      _quickReplies = replies;
    });
  }

  void translateNow() => _showTranslation
      ? setState(() => _showTranslation = false)
      : _translate(context.read<AppState>());
  Future<void> addToCalendarNow() => _addToCalendar(context.read<AppState>());
  bool get showingTranslation => _showTranslation;

  Future<void> replyWithAi() async {
    final c = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Reply with AI'),
        content: SizedBox(
          width: 380,
          child: TextField(
            controller: c,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText: 'What should the reply say? e.g. "yes, but Thursday works better"',
            ),
            onSubmitted: (v) => Navigator.pop(d, v),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, c.text),
            child: const Text('Write Reply'),
          ),
        ],
      ),
    );
    c.dispose();
    if (text != null && mounted) {
      openReply(context, widget.message, aiInstruction: text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final m = widget.message;
    final theme = Theme.of(context);
    final c = MacColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    final sender = MailService.senderOf(m);
    final date = MailService.dateOf(m);
    final allowImages = _loadImages || state.settings.loadRemoteImages;
    final doc = _document(m, allowImages, dark);
    final isHtml =
        !(_showTranslation && _translated != null) &&
        (m.decodeTextHtmlPart()?.trim().isNotEmpty ?? false);
    final triage = state.triageOf(m);
    final owner = state.sessions.length > 1 ? state.sessionOf(m) : null;
    final suspicion =
        MailService.suspicionOf(m) ??
        (triage?.suspicious == true
            ? 'The AI thinks this email may be a phishing or scam attempt.'
            : null);
    final unsub = MailService.unsubscribeOf(m);
    final snooze = state.snoozeOf(m);
    final vip = sender != null && state.userData.isVip(sender.email);
    final attachments = m.findContentInfo(
      disposition: ContentDisposition.attachment,
    );

    // Mail-style notice line: small icon, text, blue link on the right.
    Widget notice(
      IconData icon,
      String text, {
      Color? color,
      String? action,
      VoidCallback? onAction,
    }) => Column(
      children: [
        const Hairline(),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              Icon(icon, size: 14, color: color ?? c.secondaryLabel),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 12,
                    color: color ?? c.secondaryLabel,
                  ),
                ),
              ),
              if (action != null)
                TextButton(onPressed: onAction, child: Text(action)),
            ],
          ),
        ),
      ],
    );

    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InitialsAvatar(MailService.senderName(m), size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Tooltip(
                          message: sender?.email ?? '',
                          child: SelectableText(
                            MailService.senderName(m),
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: c.label,
                            ),
                          ),
                        ),
                      ),
                      if (sender != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: InkWell(
                            onTap: () => state.toggleVip(sender.email),
                            child: Tooltip(
                              message: vip
                                  ? 'VIP · click to remove'
                                  : 'Add to VIPs',
                              child: Icon(
                                vip
                                    ? CupertinoIcons.star_fill
                                    : CupertinoIcons.star,
                                size: 13,
                                color: vip ? c.secondaryLabel : c.tertiaryLabel,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  SelectableText(
                    MailService.subjectOf(m),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: c.label,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: 'To: ',
                          style: TextStyle(color: c.secondaryLabel),
                        ),
                        TextSpan(
                          text: MailService.displayList(m.to),
                          style: TextStyle(color: c.label),
                        ),
                        if ((m.cc ?? []).isNotEmpty) ...[
                          TextSpan(
                            text: '   Cc: ',
                            style: TextStyle(color: c.secondaryLabel),
                          ),
                          TextSpan(
                            text: MailService.displayList(m.cc),
                            style: TextStyle(color: c.label),
                          ),
                        ],
                      ],
                    ),
                    style: const TextStyle(fontSize: 12),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (date != null)
                  Text(
                    DateFormat.yMMMd().add_jm().format(date.toLocal()),
                    style: TextStyle(fontSize: 12, color: c.secondaryLabel),
                  ),
                if (owner != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: AccountBadge(
                      config: owner.config,
                      index: state.indexOf(owner),
                    ),
                  ),
                if (state.aiReady && !_showSummary)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _Pill(
                      icon: CupertinoIcons.sparkles,
                      label: 'Summarize',
                      onTap: showSummary,
                    ),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (state.isDraft(m))
          notice(
            CupertinoIcons.pencil,
            'This is a draft.',
            color: c.accent,
            action: 'Edit Draft',
            onAction: () => openDraft(context, m),
          ),
        if (suspicion != null)
          notice(
            CupertinoIcons.exclamationmark_shield,
            'Be careful: $suspicion Don\'t click links or share passwords or codes.',
            color: const Color(0xFFFF3B30),
          ),
        if (snooze != null && !snooze.isDue)
          notice(
            CupertinoIcons.alarm,
            'Reminder set for ${DateFormat('E d MMM, HH:mm').format(snooze.until)}',
            action: 'Cancel',
            onAction: () => state.unsnooze(m),
          ),
        if (_language != null || _showTranslation)
          notice(
            CupertinoIcons.globe,
            _showTranslation
                ? (_translating
                      ? 'Translating from ${_language ?? 'the original'}…'
                      : 'Translated from ${_language ?? 'the original'}')
                : 'This message is in $_language.',
            action: _translating
                ? null
                : (_showTranslation
                      ? 'Show Original'
                      : 'Translate to ${state.settings.myLanguage}'),
            onAction: translateNow,
          ),
        if (unsub != null)
          notice(
            CupertinoIcons.envelope,
            'This message is from a mailing list.',
            action: _unsubscribing ? 'Unsubscribing…' : 'Unsubscribe',
            onAction: _unsubscribing ? null : () => _unsubscribe(state),
          ),
        if (isHtml && !allowImages && doc.blockedImages > 0)
          notice(
            CupertinoIcons.photo,
            'This message contains remote content.',
            action: 'Load Remote Content',
            onAction: () => setState(() => _loadImages = true),
          ),
        if (triage != null &&
            triage.needsReply &&
            !m.isAnswered &&
            _quickReplies == null &&
            state.aiReady)
          notice(
            CupertinoIcons.arrowshape_turn_up_left,
            'This message looks like it is waiting for your reply.',
            color: c.accent,
            action: 'Quick Replies',
            onAction: showQuickReplies,
          ),
        if (_showSummary) ...[
          const SizedBox(height: 6),
          AiCard(
            title: 'Summary',
            onClose: () => setState(() => _showSummary = false),
            child: AiStreamView(
              placeholder: 'Summarizing…',
              start: () => state.ai!.summarize(state.contentOf(m)),
            ),
          ),
        ],
        if (_quickReplies != null) ...[
          const SizedBox(height: 6),
          _quickReplyCard(context, m),
        ],
        if (_findingEvent)
          notice(
            CupertinoIcons.calendar_badge_plus,
            'Looking for a date in this message…',
          ),
        InviteCard(m),
        if (attachments.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final info in attachments)
                _AttachmentChip(message: m, info: info),
            ],
          ),
        ],
        // Earlier messages in this conversation, newest last, like Mail.
        ConversationHistory(m),
        const SizedBox(height: 10),
      ],
    );

    final bodyBg = isHtml || !dark ? Colors.white : const Color(0xFF1F1F22);
    // One page, like Mail: the header sits in space left above the email
    // and slides up as the email scrolls; scrolling over it scrolls the email.
    final offset = _scrollY.clamp(0.0, _headerHeight);
    return ClipRect(
      child: Stack(
        children: [
          // HTML email is designed for a white page, so it keeps one even in
          // dark mode. Plain text follows the app theme.
          Positioned.fill(
            child: ColoredBox(
              color: bodyBg,
              child: EmailWebView(
                key: _webKey,
                html: doc.html,
                background: bodyBg,
                topInset: _headerHeight,
                onScroll: (y) {
                  if (mounted &&
                      (y.clamp(0.0, _headerHeight) !=
                          _scrollY.clamp(0.0, _headerHeight))) {
                    setState(() => _scrollY = y);
                  } else {
                    _scrollY = y;
                  }
                },
              ),
            ),
          ),
          Positioned(
            top: -offset,
            left: 0,
            right: 0,
            child: Listener(
              onPointerSignal: (e) {
                if (e is PointerScrollEvent) {
                  _webKey.currentState?.scrollBy(e.scrollDelta.dy);
                }
              },
              onPointerPanZoomUpdate: (e) =>
                  _webKey.currentState?.scrollBy(-e.localPanDelta.dy),
              child: _MeasureHeight(
                onChange: (h) {
                  if (mounted && (h - _headerHeight).abs() > 0.5) {
                    setState(() => _headerHeight = h);
                  }
                },
                child: ColoredBox(
                  color: MacColors.of(context).window,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                        child: header,
                      ),
                      const Hairline(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _quickReplyCard(BuildContext context, MimeMessage m) {
    return AiCard(
      title: 'Quick replies',
      onClose: () => setState(() => _quickReplies = null),
      child: FutureBuilder<List<String>>(
        future: _quickReplies,
        builder: (context, snap) {
          if (snap.hasError) {
            return Text(
              '${snap.error}',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            );
          }
          if (!snap.hasData) {
            return const LinearProgressIndicator();
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final r in snap.data!)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                    ),
                    // Expand the short reply into a full email, keeping its meaning.
                    onPressed: () => openReply(context, m, aiInstruction: r),
                    child: Text(r, textAlign: TextAlign.left),
                  ),
                ),
              Text(
                'Click one to turn it into a full reply you can edit.',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A small rounded button, like Mail's "Summarize".
class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: c.fill,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: c.accent),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: c.label,
              ),
            ),
          ],
        ),
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

  Future<void> _quickLook() async {
    final state = context.read<AppState>();
    setState(() => _busy = true);
    try {
      await state.quickLook(widget.message, widget.info);
    } catch (e) {
      state.toast('Could not preview the attachment: ${AppState.friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _menu(Offset at) async {
    final choice = await showMenu<String>(
      context: context,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
      items: const [
        PopupMenuItem(value: 'look', height: 30, child: Text('Quick Look')),
        PopupMenuItem(value: 'open', height: 30, child: Text('Open')),
        PopupMenuItem(value: 'save', height: 30, child: Text('Save to Downloads')),
      ],
    );
    switch (choice) {
      case 'look':
        await _quickLook();
      case 'open':
        await _run(true);
      case 'save':
        await _run(false);
    }
  }

  Future<void> _run(bool open) async {
    final state = context.read<AppState>();
    if (open && AppState.isRiskyAttachment(widget.info.fileName)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Open "${widget.info.fileName}"?'),
          content: const Text('This kind of file can run programs on your Mac. Only open it if you trust the sender '
              'and were expecting it. macOS will check it before it runs.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Open')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final f = await state.saveAttachment(
        widget.message,
        widget.info,
        open: open,
      );
      if (!open) state.toast('Saved to ${f.path}');
    } catch (e) {
      state.toast(
        'Could not ${open ? 'open' : 'save'} the attachment: ${AppState.friendlyError(e)}',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.info.size;
    final label =
        '${widget.info.fileName ?? 'attachment'}${size == null ? '' : '  ·  ${_size(size)}'}';
    return InputChip(
      avatar: _busy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              widget.info.isImage ? Icons.image_outlined : Icons.attach_file,
              size: 16,
            ),
      label: GestureDetector(
        // Like Mail: double-click opens, right-click for more.
        onDoubleTap: _busy ? null : () => _run(true),
        onSecondaryTapDown: _busy ? null : (d) => _menu(d.globalPosition),
        child: Text(label),
      ),
      tooltip: 'Click for Quick Look · double-click to open',
      onPressed: _busy ? null : _quickLook,
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

/// The right-click (or long-press) menu for an email, like Apple Mail's.
Future<void> showMessageMenu(
  BuildContext context,
  MimeMessage m,
  Offset at,
) async {
  final state = context.read<AppState>();
  final sender = MailService.senderOf(m)?.email;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  PopupMenuItem<String> item(String value, IconData icon, String label) =>
      PopupMenuItem(
        value: value,
        height: 36,
        child: Row(
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 12),
            Text(label),
          ],
        ),
      );
  final choice = await showMenu<String>(
    popUpAnimationStyle: AnimationStyle.noAnimation,
    context: context,
    position: RelativeRect.fromRect(
      at & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: [
      item('reply', Icons.reply, 'Reply'),
      item('replyAll', Icons.reply_all, 'Reply All'),
      item('forward', Icons.forward, 'Forward'),
      const PopupMenuDivider(),
      item(
        'read',
        m.isSeen ? Icons.mark_email_unread_outlined : Icons.drafts_outlined,
        m.isSeen ? 'Mark as Unread' : 'Mark as Read',
      ),
      item(
        'flag',
        m.isFlagged ? Icons.outlined_flag : Icons.flag_outlined,
        m.isFlagged ? 'Unflag' : 'Flag',
      ),
      item('remind', Icons.alarm, 'Remind Me…'),
      const PopupMenuDivider(),
      item('archive', Icons.archive_outlined, 'Archive'),
      item('move', Icons.drive_file_move_outline, 'Move To…'),
      item(
        'junk',
        Icons.report_gmailerrorred,
        state.isInJunk(m) ? 'Not Junk' : 'Move to Junk',
      ),
      item('delete', Icons.delete_outline, 'Delete'),
      const PopupMenuDivider(),
      if (sender != null)
        item(
          'vip',
          state.userData.isVip(sender)
              ? Icons.star_rounded
              : Icons.star_outline_rounded,
          state.userData.isVip(sender)
              ? 'Remove from VIPs'
              : 'Add Sender to VIPs',
        ),
      item(
        'mute',
        Icons.notifications_off_outlined,
        state.isMuted(m) ? 'Unmute Conversation' : 'Mute Conversation',
      ),
      if (sender != null) item('copy', Icons.copy, 'Copy Sender Address'),
      if (sender != null) item('block', Icons.block, 'Block Sender…'),
    ],
  );
  if (choice == null || !context.mounted) return;
  // Right-clicking inside a selection acts on all of it, like Mail.
  final all = state.hasMulti && state.isSelected(m) ? state.targets : [m];
  switch (choice) {
    case 'reply':
      openReply(context, m);
    case 'replyAll':
      openReply(context, m, replyAll: true);
    case 'forward':
      openForward(context, m);
    case 'read':
      await state.setRead(all, !m.isSeen);
    case 'flag':
      await state.setFlagged(all, !m.isFlagged);
    case 'remind':
      final picked = await showDialog<Object>(
        context: context,
        builder: (c) => SimpleDialog(
          title: const Text('Remind me'),
          children: [
            for (final (label, time) in snoozeChoices())
              SimpleDialogOption(
                onPressed: () => Navigator.pop(c, time),
                child: Text('$label  ·  ${DateFormat('E HH:mm').format(time)}'),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, 'custom'),
              child: const Text('Pick date & time…'),
            ),
          ],
        ),
      );
      if (!context.mounted) return;
      final when = picked is DateTime
          ? picked
          : (picked == 'custom'
                ? await pickDateTime(context, help: 'Remind me on')
                : null);
      if (when != null) await state.snooze(m, when);
    case 'archive':
      await state.archiveMessages(all);
    case 'move':
      final owner = state.sessionOf(m);
      final here = state.mailboxOf(m);
      final target = await showDialog<Mailbox>(
        context: context,
        builder: (c) => SimpleDialog(
          title: const Text('Move to'),
          children: [
            for (final b in (owner?.mailboxes ?? const <Mailbox>[]).where(
              (b) => b.path != here?.path,
            ))
              SimpleDialogOption(
                onPressed: () => Navigator.pop(c, b),
                child: Row(
                  children: [
                    Icon(mailboxIcon(b), size: 18),
                    const SizedBox(width: 10),
                    Text(b.isInbox ? 'Inbox' : b.name),
                  ],
                ),
              ),
          ],
        ),
      );
      if (target != null) await state.moveMessages(all, target);
    case 'junk':
      await state.junkMessages(all);
    case 'delete':
      await state.deleteMessages(all);
    case 'vip':
      await state.toggleVip(sender!);
    case 'mute':
      await state.muteThread(m);
    case 'copy':
      await Clipboard.setData(ClipboardData(text: sender!));
      state.toast('Copied $sender');
    case 'block':
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Block $sender?'),
          content: const Text(
            'Their emails will go straight to Junk on this computer. You can unblock them in Settings.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Block'),
            ),
          ],
        ),
      );
      if (ok == true) await state.blockSender(sender!);
  }
}

/// Reports its child's height after each layout.
class _MeasureHeight extends SingleChildRenderObjectWidget {
  const _MeasureHeight({required this.onChange, required super.child});
  final ValueChanged<double> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureHeight(onChange);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMeasureHeight renderObject,
  ) => renderObject.onChange = onChange;
}

class _RenderMeasureHeight extends RenderProxyBox {
  _RenderMeasureHeight(this.onChange);
  ValueChanged<double> onChange;
  double? _last;

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if (h != _last) {
      _last = h;
      WidgetsBinding.instance.addPostFrameCallback((_) => onChange(h));
    }
  }
}

/// What the reading pane shows when several messages are selected.
class _MultiSelection extends StatelessWidget {
  const _MultiSelection({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    final state = context.read<AppState>();
    final ms = state.targets;
    final anyUnread = ms.any((m) => !m.isSeen);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(CupertinoIcons.envelope_open, size: 44, color: c.tertiaryLabel),
          const SizedBox(height: 10),
          Text(
            '$count messages selected',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: c.secondaryLabel,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => state.archiveMessages(ms),
                child: const Text('Archive'),
              ),
              OutlinedButton(
                onPressed: () => state.deleteMessages(ms),
                child: const Text('Delete'),
              ),
              OutlinedButton(
                onPressed: () => state.setRead(ms, anyUnread),
                child: Text(anyUnread ? 'Mark as Read' : 'Mark as Unread'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


/// Every header of a message, as sent (View > Message > All Headers in Mail).
void showAllHeaders(BuildContext context, MimeMessage m) {
  final c = MacColors.of(context);
  final text = [
    for (final h in m.headers ?? const <Header>[]) '${h.name}: ${h.value ?? ''}',
  ].join('\n');
  showDialog<void>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('All Headers'),
      content: SizedBox(
        width: 640,
        height: 420,
        child: SingleChildScrollView(
          child: SelectableText(
            text.isEmpty ? 'No headers were downloaded for this message.' : text,
            style: TextStyle(fontFamily: 'Menlo', fontSize: 11.5, height: 1.4, color: c.label),
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Done'))],
    ),
  );
}

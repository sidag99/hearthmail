import 'dart:async';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/intent.dart';
import '../services/ai/ai_provider.dart';
import '../services/ai/email_ai.dart';
import '../services/ai/engines.dart';
import '../services/mail_service.dart';
import '../services/user_data.dart';
import '../state/app_state.dart';
import 'compose_ai.dart';
import 'mac_style.dart';
import 'message_view.dart' show pickDateTime;

class ComposePage extends StatefulWidget {
  const ComposePage({
    super.key,
    this.replyTo,
    this.replyAll = false,
    this.forwardOf,
    this.aiReplyInstruction,
    this.initialBody,
    this.restore,
    this.followUpOf,
  });

  final MimeMessage? replyTo;
  final bool replyAll;
  final MimeMessage? forwardOf;

  /// When set (even empty), an AI reply draft is written on open.
  final String? aiReplyInstruction;
  final String? initialBody;

  /// A message to edit again (after "Undo send" or a failed send).
  final OutgoingMail? restore;

  /// Write a polite follow-up for a sent email nobody answered.
  final FollowUp? followUpOf;

  @override
  State<ComposePage> createState() => _ComposePageState();
}

class _ComposePageState extends State<ComposePage> {
  final _to = TextEditingController();
  final _cc = TextEditingController();
  final _bcc = TextEditingController();
  final _subject = TextEditingController();
  final _body = TextEditingController();
  final _prompt = TextEditingController();
  final _intentNotes = TextEditingController();
  final _bodyFocus = FocusNode();
  final _fieldFocus = <TextEditingController, FocusNode>{};

  bool _showCc = false;
  bool _preview = false;
  bool _includeQuote = true;
  bool _suggestingSubject = false;
  bool _showAiWriter = false;
  bool _loadingAttachments = false;
  bool _sent = false;
  int? _followUpDays;
  final _files = <File>[];

  StreamSubscription<String>? _aiSub;
  String? _aiLabel;

  /// The last AI job, so it can be re-run on another model if it fails.
  Stream<String> Function(EmailAi ai)? _lastJob;
  String? _lastLabel;

  /// Why the last AI job failed, and the model to try instead.
  ({String message, WritingChoice? fallback})? _aiFailure;

  /// "What should it say?" for new messages and replies.
  bool _showIntent = false;
  String? _undoText;
  String? _replyLanguage;

  bool get _generating => _aiSub != null;

  /// The copy of this message last saved to Drafts; the next save (or
  /// sending) replaces it.
  MimeMessage? _savedDraft;
  String? _savedSnapshot;
  Timer? _autosave;

  /// The account this message is sent from.
  AccountSession? _from;

  late final String _initialSnapshot;

  MimeMessage? get _original => widget.replyTo ?? widget.forwardOf;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    final r = widget.replyTo;
    final f = widget.forwardOf;
    final restore = widget.restore;
    // Replies go out from the account that received the email.
    _from = restore?.from ?? (_original == null ? null : state.sessionOf(_original!)) ?? state.defaultSendingSession;
    if (restore != null) {
      _to.text = restore.to;
      _cc.text = restore.cc;
      _bcc.text = restore.bcc;
      _subject.text = restore.subject;
      _body.text = restore.body;
      _files.addAll(restore.files);
      _includeQuote = false; // the restored body already contains it
      _showCc = restore.cc.isNotEmpty || restore.bcc.isNotEmpty;
      _followUpDays = restore.followUpDays;
    } else if (r != null) {
      // Every address of mine, so Reply All never includes me.
      final mine = {for (final x in state.sessions) x.config.email.toLowerCase()};
      final replyTo = (r.replyTo?.isNotEmpty ?? false) ? r.replyTo! : (r.from ?? const <MailAddress>[]);
      _to.text = MailService.addressList(replyTo);
      if (widget.replyAll) {
        final seen = {for (final x in replyTo) x.email.toLowerCase()};
        final others = [
          // When Reply-To differs from From, the sender still gets it.
          if (r.replyTo?.isNotEmpty ?? false) ...?r.from,
          ...?r.to,
          ...?r.cc,
        ].where((a) => !mine.contains(a.email.toLowerCase()) && seen.add(a.email.toLowerCase())).toList();
        if (others.isNotEmpty) {
          _cc.text = MailService.addressList(others);
          _showCc = true;
        }
      }
      final subj = MailService.subjectOf(r);
      _subject.text = RegExp(r'^re:', caseSensitive: false).hasMatch(subj) ? subj : 'Re: $subj';
      _detectReplyLanguage(state, r);
    } else if (f != null) {
      final subj = MailService.subjectOf(f);
      _subject.text = RegExp(r'^fwd?:', caseSensitive: false).hasMatch(subj) ? subj : 'Fwd: $subj';
      if (f.hasAttachments()) _loadForwardedAttachments(state, f);
    } else if (widget.followUpOf != null) {
      final fu = widget.followUpOf!;
      _to.text = fu.to;
      _subject.text = RegExp(r'^re:', caseSensitive: false).hasMatch(fu.subject) ? fu.subject : 'Re: ${fu.subject}';
      if (state.ai != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _runAi(
            'Writing follow-up…',
            (ai) => ai.compose(
              'A short, friendly follow-up nudge: I sent an email about "${fu.subject}" and have not heard back yet. '
              'Ask if they had a chance to look at it.',
              to: fu.to,
              subject: fu.subject,
            ),
          );
        });
      }
    }
    if (widget.initialBody != null) _body.text = widget.initialBody!;
    if (widget.aiReplyInstruction != null && r != null && state.ai != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _runAi('Writing reply…', (ai) => ai.draftReply(state.contentOf(r), instruction: widget.aiReplyInstruction!));
      });
    }
    // Offer "what should it say?" when starting from an empty message or reply.
    _showIntent = widget.forwardOf == null &&
        restore == null &&
        widget.followUpOf == null &&
        widget.aiReplyInstruction == null &&
        state.aiReady &&
        _body.text.isEmpty;
    // The AI toolbar offers rewrites only once there is text.
    var hadText = _body.text.trim().isNotEmpty;
    _body.addListener(() {
      final hasText = _body.text.trim().isNotEmpty;
      if (hasText != hadText && mounted) setState(() => hadText = hasText);
    });
    _initialSnapshot = _snapshot();
    _savedDraft = restore?.replacesDraft;
    // Autosave like Mail and Gmail, so a crash or quit doesn't lose much.
    _autosave = Timer.periodic(const Duration(seconds: 30), (_) => _autosaveNow());
  }

  Future<void> _autosaveNow() async {
    if (!mounted || _sent || !_dirty || _generating || _from?.connected != true) return;
    final snap = _snapshot();
    if (snap == _savedSnapshot) return;
    final state = context.read<AppState>();
    try {
      final saved = await state.saveDraft(_mail(state), quiet: true);
      _savedSnapshot = snap;
      // Without a UID we couldn't replace it next time; stop autosaving.
      if (saved == null) _autosave?.cancel();
      _savedDraft = saved;
    } catch (_) {
      // Try again on the next tick.
    }
  }

  String _snapshot() => [_to.text, _cc.text, _bcc.text, _subject.text, _body.text, _files.length].join('\u0000');

  bool get _dirty => !_sent && _snapshot() != _initialSnapshot && (_body.text.trim().isNotEmpty || _to.text.trim().isNotEmpty);

  Future<void> _detectReplyLanguage(AppState state, MimeMessage r) async {
    final lang = await state.ai?.detectLanguage(MailService.bodyText(r));
    if (!mounted || lang == null) return;
    if (lang.toLowerCase() != state.settings.myLanguage.toLowerCase()) setState(() => _replyLanguage = lang);
  }

  Future<void> _loadForwardedAttachments(AppState state, MimeMessage f) async {
    setState(() => _loadingAttachments = true);
    try {
      final files = await state.attachmentFiles(f);
      if (mounted) setState(() => _files.addAll(files));
    } catch (e) {
      _snack('Could not load the original attachments: ${AppState.friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _loadingAttachments = false);
    }
  }

  @override
  void dispose() {
    _autosave?.cancel();
    _aiSub?.cancel();
    for (final c in [_to, _cc, _bcc, _subject, _body, _prompt, _intentNotes]) {
      c.dispose();
    }
    _bodyFocus.dispose();
    for (final f in _fieldFocus.values) {
      f.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------------------ AI

  /// Runs an AI writing job into the body. [job] gets the current AI, so a
  /// failed job can be re-run as is after switching models.
  void _runAi(String label, Stream<String> Function(EmailAi ai) job) {
    final state = context.read<AppState>();
    final ai = state.ai;
    if (ai == null) return;
    _aiSub?.cancel();
    _lastJob = job;
    _lastLabel = label;
    _undoText = _body.text;
    final who = state.currentWritingChoice;
    final stream = job(ai); // reads the current body before it is cleared
    final buf = StringBuffer();
    setState(() {
      _aiLabel = label;
      _aiFailure = null;
      _preview = false;
      _body.text = '';
    });
    _aiSub = stream.listen(
      (chunk) {
        buf.write(chunk);
        _body.value = TextEditingValue(text: buf.toString());
      },
      onError: (Object e) {
        _body.text = _undoText ?? '';
        _undoText = null;
        if (mounted) {
          setState(() => _aiFailure = (
                message: e is AiException ? describeAiError(e, who) : 'Writing failed: $e',
                fallback: state.fallbackFor(who),
              ));
        }
        _finishAi();
      },
      onDone: () {
        _body.text = EmailAi.cleanDraft(buf.toString());
        _finishAi();
      },
    );
  }

  void _finishAi() {
    if (!mounted) return;
    setState(() {
      _aiSub = null;
      _aiLabel = null;
    });
  }

  void _stopAi() {
    _aiSub?.cancel();
    _body.text = EmailAi.cleanDraft(_body.text);
    _finishAi();
  }

  /// Switches to the suggested model and runs the failed job again.
  Future<void> _retryWith(WritingChoice choice) async {
    final job = _lastJob;
    final label = _lastLabel;
    await context.read<AppState>().setWritingChoice(choice);
    if (!mounted || job == null) return;
    _runAi(label ?? 'Writing…', job);
  }

  void _writeFromIntent(IntentChoice choice) {
    final state = context.read<AppState>();
    final r = widget.replyTo;
    final original = r == null ? null : state.contentOf(r);
    setState(() => _showIntent = false);
    _runAi('Writing…', (ai) => ai.writeFromIntent(choice, replyTo: original, to: _to.text, subject: _subject.text));
  }

  void _undo() {
    if (_undoText == null) return;
    setState(() {
      _body.text = _undoText!;
      _undoText = null;
    });
  }

  Future<void> _suggestSubject(EmailAi ai) async {
    if (_body.text.trim().isEmpty) {
      _snack('Write the email first, then I can suggest a subject.');
      return;
    }
    setState(() => _suggestingSubject = true);
    try {
      _subject.text = await ai.suggestSubject(_body.text);
    } catch (e) {
      _snack('AI error: $e');
    } finally {
      if (mounted) setState(() => _suggestingSubject = false);
    }
  }

  // ------------------------------------------------------------------ send

  String _finalBody(AppState state) {
    var text = _body.text.trimRight();
    final sig = state.userData.signatures[_from?.id]?.trim() ?? '';
    if (sig.isNotEmpty && !text.contains(sig)) text = '$text\n\n-- \n$sig';
    final r = widget.replyTo;
    final f = widget.forwardOf;
    if (f != null) {
      final date = MailService.dateOf(f);
      text = '$text\n\n---------- Forwarded message ----------\n'
          'From: ${MailService.senderOf(f) ?? ''}\n'
          '${date == null ? '' : 'Date: ${DateFormat.yMMMd().add_jm().format(date.toLocal())}\n'}'
          'Subject: ${MailService.subjectOf(f)}\n'
          'To: ${MailService.addressList(f.to)}\n\n'
          '${MailService.bodyText(f)}';
    } else if (r != null && _includeQuote) {
      final date = MailService.dateOf(r);
      final who = MailService.senderOf(r)?.toString() ?? 'the sender';
      final when = date == null ? '' : 'On ${DateFormat.yMMMd().add_jm().format(date.toLocal())}, ';
      final quoted = MailService.bodyText(r).split('\n').map((l) => '> $l').join('\n');
      text = '$text\n\n$when$who wrote:\n\n$quoted';
    }
    return text;
  }

  bool _validate() {
    if (_to.text.trim().isEmpty) {
      _snack('Add at least one recipient.');
      return false;
    }
    try {
      for (final f in [_to, _cc, _bcc]) {
        MailService.parseAddresses(f.text);
      }
    } catch (_) {
      _snack('One of the email addresses is not valid.');
      return false;
    }
    if (_from == null) {
      _snack('Add an email account first.');
      return false;
    }
    return true;
  }

  OutgoingMail _mail(AppState state, {DateTime? sendAt}) => OutgoingMail(
        from: _from!,
        to: _to.text,
        cc: _cc.text,
        bcc: _bcc.text,
        subject: _subject.text.trim(),
        body: _finalBody(state),
        // Keep threading when this is a reopened draft or an undone send.
        inReplyTo: widget.replyTo ?? widget.restore?.inReplyTo,
        files: [..._files],
        sendAt: sendAt,
        followUpDays: _followUpDays,
        replacesDraft: _savedDraft,
      );

  Future<void> _send({DateTime? at}) async {
    final state = context.read<AppState>();
    if (!_validate()) return;
    if (_subject.text.trim().isEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Send without a subject?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Send')),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (_from?.connected != true && at == null) {
      _snack('${_from?.config.email} is not connected right now.');
      return;
    }
    _autosave?.cancel();
    _sent = true; // stops any further autosave
    await state.sendMail(_mail(state, sendAt: at));
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _sendLater() async {
    final now = DateTime.now();
    DateTime at(DateTime d, int h) => DateTime(d.year, d.month, d.day, h);
    final tomorrow = now.add(const Duration(days: 1));
    final choice = await showDialog<Object>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Send later'),
        children: [
          for (final (label, time) in [
            ('Tomorrow morning', at(tomorrow, 8)),
            ('Tomorrow afternoon', at(tomorrow, 13)),
            if (now.weekday <= DateTime.friday) ('Monday morning', at(now.add(Duration(days: 8 - now.weekday)), 8)),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, time),
              child: Text('$label  ·  ${DateFormat('E d MMM, HH:mm').format(time)}'),
            ),
          SimpleDialogOption(onPressed: () => Navigator.pop(c, 'custom'), child: const Text('Pick date & time…')),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text('Hearthmail sends it at that time if it is open on this computer (or as soon as it is opened).',
                style: Theme.of(c).textTheme.bodySmall),
          ),
        ],
      ),
    );
    if (!mounted) return;
    DateTime? when = choice is DateTime ? choice : null;
    if (choice == 'custom') when = await pickDateTime(context, help: 'Send on');
    if (when != null) await _send(at: when);
  }

  Future<void> _attach() async {
    final files = await openFiles();
    if (files.isEmpty) return;
    setState(() => _files.addAll([for (final f in files) File(f.path)]));
    // Most mail servers refuse messages over about 25 MB (attachments grow
    // by a third when encoded).
    final bytes = _files.fold<int>(0, (sum, f) => sum + (f.existsSync() ? f.lengthSync() : 0));
    if (bytes * 4 / 3 > 25 * 1024 * 1024) {
      _snack('Attachments total ${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB. '
          'Many mail servers reject messages over 25 MB; consider sharing a link instead.');
    }
  }

  Future<bool> _confirmLeave() async {
    if (!_dirty) return true;
    final state = context.read<AppState>();
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Save this message as a draft?'),
        content: Text('It is saved to the Drafts folder of ${_from?.config.email ?? 'your account'}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, 'discard'), child: const Text('Discard')),
          TextButton(onPressed: () => Navigator.pop(c, 'cancel'), child: const Text('Keep editing')),
          FilledButton(onPressed: () => Navigator.pop(c, 'save'), child: const Text('Save draft')),
        ],
      ),
    );
    if (choice == 'discard') {
      _autosave?.cancel();
      final d = _savedDraft;
      if (d != null) unawaited(state.discardDraft(d));
      return true;
    }
    if (choice != 'save' || _from == null) return false;
    try {
      _autosave?.cancel();
      await state.saveDraft(_mail(state));
      return true;
    } catch (e) {
      _snack('Could not save the draft: ${AppState.friendlyError(e)}');
      return false;
    }
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  // ------------------------------------------------------------------ templates

  Future<void> _templates(AppState state) async {
    final data = state.userData;
    final choice = await showDialog<Object>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Templates'),
        children: [
          if (data.templates.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8), child: Text('No templates yet.')),
          for (final t in data.templates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, t),
              child: Row(children: [
                Expanded(child: Text(t.name)),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 16),
                  tooltip: 'Delete template',
                  onPressed: () => Navigator.pop(c, ('delete', t)),
                ),
              ]),
            ),
          const Divider(),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, 'save'),
            child: const Row(children: [Icon(Icons.add, size: 18), SizedBox(width: 8), Text('Save this message as a template')]),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice is Template) {
      setState(() => _body.text = _body.text.trim().isEmpty ? choice.body : '${_body.text}\n\n${choice.body}');
    } else if (choice is (String, Template)) {
      data.templates.remove(choice.$2);
      await data.save();
    } else if (choice == 'save') {
      if (_body.text.trim().isEmpty) {
        _snack('Write something first.');
        return;
      }
      final name = TextEditingController(text: _subject.text);
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Template name'),
          content: TextField(controller: name, autofocus: true),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
          ],
        ),
      );
      if (ok == true && name.text.trim().isNotEmpty) {
        data.templates.add(Template(name.text.trim(), _body.text));
        await data.save();
        _snack('Template saved');
      }
      name.dispose();
    }
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final ai = state.ai;
    final c = MacColors.of(context);
    final title = widget.forwardOf != null
        ? 'Forward'
        : widget.replyTo != null
            ? 'Reply'
            : 'New Message';
    final busy = _generating || _loadingAttachments;

    final header = SizedBox(
      height: kToolbarHeight52,
      child: Row(children: [
        // Room for the window's traffic lights.
        SizedBox(width: useMacWindow ? kTitlebarInset : 8),
        ToolButton(icon: CupertinoIcons.xmark, tooltip: 'Close (Esc)', onPressed: () => Navigator.of(context).maybePop()),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            _subject.text.trim().isEmpty ? title : _subject.text.trim(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c.label),
          ),
        ),
        ToolButton(icon: CupertinoIcons.paperclip, tooltip: 'Attach Files', onPressed: _attach),
        ToolButton(icon: CupertinoIcons.doc_on_doc, tooltip: 'Templates', onPressed: () => _templates(state)),
        ToolButton(
          icon: _preview ? CupertinoIcons.pencil : CupertinoIcons.eye,
          tooltip: _preview ? 'Edit' : 'Preview Formatting',
          onPressed: _generating ? null : () => setState(() => _preview = !_preview),
        ),
        ToolbarItem(
          child: PopupMenuButton<int>(
        popUpAnimationStyle: AnimationStyle.noAnimation,
            tooltip: 'Remind Me If No Reply',
            initialValue: _followUpDays ?? 0,
            onSelected: (d) => setState(() => _followUpDays = d == 0 ? null : d),
            itemBuilder: (_) => const [
              CheckedPopupMenuItem(value: 0, height: 32, child: Text('No Follow-Up Reminder')),
              PopupMenuDivider(),
              PopupMenuItem(value: 1, height: 32, child: Text('Remind Me If No Reply in 1 Day')),
              PopupMenuItem(value: 3, height: 32, child: Text('Remind Me If No Reply in 3 Days')),
              PopupMenuItem(value: 7, height: 32, child: Text('Remind Me If No Reply in 1 Week')),
            ],
            child: SizedBox(
              width: 32,
              height: 28,
              child: Icon(_followUpDays == null ? CupertinoIcons.bell : CupertinoIcons.bell_fill,
                  size: 16, color: _followUpDays == null ? c.secondaryLabel : c.accent),
            ),
          ),
        ),
        ToolButton(icon: CupertinoIcons.clock, tooltip: 'Send Later', onPressed: busy ? null : _sendLater),
        const SizedBox(width: 4),
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: ToolbarItem(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              icon: const Icon(CupertinoIcons.paperplane_fill, size: 13),
              label: const Text('Send'),
              onPressed: busy ? null : _send,
            ),
          ),
        ),
      ]),
    );

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) {
          _sent = true; // nothing more to save
          Navigator.of(context).pop();
        }
      },
      child: CallbackShortcuts(
        bindings: {
          // Apple Mail sends with ⇧⌘D, Gmail with ⌘↩.
          const SingleActivator(LogicalKeyboardKey.keyD, meta: true, shift: true): _send,
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): _send,
          const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop(),
          const SingleActivator(LogicalKeyboardKey.keyW, meta: true): () => Navigator.of(context).maybePop(),
        },
        child: Scaffold(
          backgroundColor: c.window,
          body: Column(children: [
            header,
            const Hairline(),
            if (state.sessions.length > 1) ...[_fromPicker(state), const Hairline(indent: 16)],
            _recipientField('To:', _to, state,
                trailing: _showCc
                    ? null
                    : TextButton(onPressed: () => setState(() => _showCc = true), child: const Text('Cc/Bcc'))),
            const Hairline(indent: 16),
            if (_showCc) ...[
              _recipientField('Cc:', _cc, state),
              const Hairline(indent: 16),
              _recipientField('Bcc:', _bcc, state),
              const Hairline(indent: 16),
            ],
            _field('Subject:', _subject,
                trailing: ai == null
                    ? null
                    : _suggestingSubject
                        ? const Padding(
                            padding: EdgeInsets.all(10),
                            child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                          )
                        : ToolButton(
                            icon: CupertinoIcons.sparkles,
                            size: 14,
                            tooltip: 'Suggest a Subject',
                            onPressed: () => _suggestSubject(ai),
                          )),
            const Hairline(),
            if (_files.isNotEmpty || _loadingAttachments)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(spacing: 6, runSpacing: 6, children: [
                    if (_loadingAttachments) const Pill(label: 'Loading attachments…', icon: CupertinoIcons.paperclip),
                    for (final f in _files)
                      Pill(
                        label: f.uri.pathSegments.last,
                        icon: CupertinoIcons.paperclip,
                        tooltip: 'Click to remove',
                        onTap: () => setState(() => _files.remove(f)),
                      ),
                  ]),
                ),
              ),
            // The intent panel has its own model switcher.
            if (ai != null && !(_showIntent && !_generating && _body.text.trim().isEmpty && _aiFailure == null)) _aiBar(ai, state),
            if (ai != null && _showIntent && !_generating)
              IntentPanel(
                notes: _intentNotes,
                replyTo: widget.replyTo == null ? null : state.contentOf(widget.replyTo!),
                to: _to.text,
                subject: _subject.text,
                onWrite: _writeFromIntent,
                onClose: () => setState(() => _showIntent = false),
              ),
            if (ai != null && _showAiWriter && !_generating && !_showIntent) _editPrompt(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                child: _preview
                    ? SingleChildScrollView(
                        child: HtmlWidget(
                          MailService.bodyToHtml(_body.text),
                          textStyle: TextStyle(color: c.label, fontSize: 14),
                        ),
                      )
                    : TextField(
                        controller: _body,
                        focusNode: _bodyFocus,
                        readOnly: _generating,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        style: TextStyle(fontSize: 14, height: 1.5, color: c.label),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          hintText: 'Write your message. **bold** and "- " lists are sent as formatting.',
                          hintStyle: TextStyle(color: c.tertiaryLabel),
                        ),
                      ),
              ),
            ),
            _footer(state),
          ]),
        ),
      ),
    );
  }

  Widget _footer(AppState state) {
    final c = MacColors.of(context);
    final small = TextStyle(fontSize: 11, color: c.secondaryLabel);
    final r = widget.replyTo;
    final hasSignature = (state.userData.signatures[_from?.id] ?? '').trim().isNotEmpty;
    if (r == null && !hasSignature && _followUpDays == null) return const SizedBox(height: 8);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 16, 6),
      child: Row(children: [
        if (r != null && widget.restore == null) ...[
          SizedBox(
            width: 28,
            child: Checkbox(
              value: _includeQuote,
              visualDensity: VisualDensity.compact,
              onChanged: (v) => setState(() => _includeQuote = v ?? true),
            ),
          ),
          Flexible(child: Text('Include original message from ${MailService.senderName(r)}', style: small)),
        ],
        const Spacer(),
        if (hasSignature) Padding(padding: const EdgeInsets.only(left: 12), child: Text('Signature added when sending', style: small)),
        if (_followUpDays != null)
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Text('Reminder if no reply in $_followUpDays day${_followUpDays == 1 ? '' : 's'}', style: small),
          ),
      ]),
    );
  }

  Widget _label(String text) => SizedBox(
        width: 72,
        child: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Text(text, textAlign: TextAlign.right, style: TextStyle(fontSize: 13, color: MacColors.of(context).secondaryLabel)),
        ),
      );

  static const _fieldStyle = TextStyle(fontSize: 13);
  // Mail's header fields are plain text with hairlines between them.
  static const _fieldDecoration = InputDecoration(
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    filled: false,
    isDense: true,
    contentPadding: EdgeInsets.symmetric(vertical: 10),
  );

  Widget _fromPicker(AppState state) => Padding(
        padding: const EdgeInsets.only(right: 16),
        child: Row(children: [
          _label('From:'),
          DropdownButtonHideUnderline(
            child: DropdownButton<AccountSession>(
              value: _from,
              isDense: true,
              style: _fieldStyle.copyWith(color: MacColors.of(context).label),
              items: [
                for (final s in state.sessions)
                  DropdownMenuItem(value: s, child: Text(s.config.displayName.isEmpty ? s.config.email : '${s.config.displayName} – ${s.config.email}')),
              ],
              onChanged: (s) => setState(() => _from = s),
            ),
          ),
          if (_from != null && !_from!.connected)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text('Not connected', style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
            ),
        ]),
      );

  Widget _field(String label, TextEditingController c, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.only(right: 12),
        child: Row(children: [
          _label(label),
          Expanded(
            child: TextField(controller: c, style: _fieldStyle, decoration: _fieldDecoration, onChanged: (_) => setState(() {})),
          ),
          ?trailing,
        ]),
      );

  /// An address field that suggests people you have emailed before.
  Widget _recipientField(String label, TextEditingController c, AppState state, {Widget? trailing}) {
    final focus = _fieldFocus.putIfAbsent(c, FocusNode.new);
    final colors = MacColors.of(context);
    String lastToken(String text) => text.split(RegExp(r'[,;]')).last.trim();
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(children: [
        _label(label),
        Expanded(
          child: RawAutocomplete<(String, String)>(
            textEditingController: c,
            focusNode: focus,
            optionsBuilder: (v) {
              final token = lastToken(v.text);
              if (token.length < 2) return const [];
              return state.userData.suggestContacts(token);
            },
            displayStringForOption: (o) => o.$1,
            onSelected: (o) {
              final parts = c.text.split(RegExp(r'[,;]'));
              parts.removeLast();
              final addr = o.$2.isEmpty ? o.$1 : '${o.$2.contains(',') ? '"${o.$2}"' : o.$2} <${o.$1}>';
              final text = [...parts.map((p) => p.trim()).where((p) => p.isNotEmpty), addr].join(', ');
              c.value = TextEditingValue(text: '$text, ', selection: TextSelection.collapsed(offset: text.length + 2));
            },
            fieldViewBuilder: (context, controller, focusNode, onSubmit) => TextField(
              controller: controller,
              focusNode: focusNode,
              style: _fieldStyle,
              decoration: _fieldDecoration,
            ),
            optionsViewBuilder: (context, onSelected, options) => Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                color: colors.window,
                borderRadius: BorderRadius.circular(8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420, maxHeight: 260),
                  child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(vertical: 4), children: [
                    for (final o in options)
                      InkWell(
                        onTap: () => onSelected(o),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(o.$2.isEmpty ? o.$1 : o.$2, style: TextStyle(fontSize: 13, color: colors.label)),
                            if (o.$2.isNotEmpty) Text(o.$1, style: TextStyle(fontSize: 11, color: colors.secondaryLabel)),
                          ]),
                        ),
                      ),
                  ]),
                ),
              ),
            ),
          ),
        ),
        ?trailing,
      ]),
    );
  }

  /// The AI row: which model writes (one click to change), then actions.
  Widget _aiBar(EmailAi ai, AppState state) {
    final c = MacColors.of(context);
    final hasText = _body.text.trim().isNotEmpty;
    final failure = _aiFailure;
    final languages = [
      ?_replyLanguage,
      ...Languages.common.where((l) => l != _replyLanguage && l != state.settings.myLanguage),
    ];
    final Widget content;
    if (_generating) {
      content = Row(children: [
        const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
        const SizedBox(width: 8),
        Expanded(
          child: Text('${_aiLabel ?? 'Writing…'}  ·  ${state.currentWritingChoice.label}',
              overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.secondaryLabel)),
        ),
        Pill(label: 'Stop', icon: CupertinoIcons.stop_fill, onTap: _stopAi),
      ]);
    } else {
      content = Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        const WriterSwitcher(),
        if (!_showIntent && !hasText)
          Pill(label: 'Write with AI', icon: CupertinoIcons.sparkles, onTap: () => setState(() => _showIntent = true)),
        if (hasText) ...[
          Pill(label: 'Change…', icon: CupertinoIcons.sparkles, onTap: () => setState(() => _showAiWriter = !_showAiWriter)),
          for (final style in RewriteStyle.values)
            Pill(label: style.label, onTap: () => _runAi('${style.label}…', (ai) => ai.rewrite(_body.text, style))),
          if (_replyLanguage != null)
            Pill(
              label: 'In $_replyLanguage',
              icon: CupertinoIcons.globe,
              onTap: () => _runAi('Translating to $_replyLanguage…',
                  (ai) => ai.translate(_body.text, _replyLanguage!, source: state.settings.myLanguage, forSending: true)),
            ),
          PopupMenuButton<String>(
        popUpAnimationStyle: AnimationStyle.noAnimation,
            tooltip: 'Translate',
            onSelected: (l) => _runAi('Translating to $l…', (ai) => ai.translate(_body.text, l, forSending: true)),
            itemBuilder: (_) => [for (final l in languages) PopupMenuItem(value: l, height: 32, child: Text(l))],
            child: const IgnorePointer(child: Pill(label: 'Translate…', icon: CupertinoIcons.globe, onTap: _noop)),
          ),
        ],
        if (_undoText != null) Pill(label: 'Undo AI', icon: CupertinoIcons.arrow_uturn_left, onTap: _undo),
      ]);
    }
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: Align(alignment: Alignment.centerLeft, child: content)),
      if (failure != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(children: [
            Icon(CupertinoIcons.exclamationmark_circle, size: 14, color: c.secondaryLabel),
            const SizedBox(width: 6),
            Expanded(child: Text(failure.message, style: TextStyle(fontSize: 12, color: c.label))),
            if (failure.fallback != null)
              Pill(
                label: 'Try with ${failure.fallback!.label}',
                icon: CupertinoIcons.arrow_clockwise,
                selected: true,
                onTap: () => _retryWith(failure.fallback!),
              ),
            ToolButton(icon: CupertinoIcons.xmark, size: 12, tooltip: 'Dismiss', onPressed: () => setState(() => _aiFailure = null)),
          ]),
        ),
    ]);
  }

  static void _noop() {}

  /// Free-form edit of an existing draft ("mention the deadline is Friday").
  Widget _editPrompt() {
    final c = MacColors.of(context);
    void go() {
      final p = _prompt.text.trim();
      if (p.isEmpty) return;
      setState(() => _showAiWriter = false);
      _runAi('Editing…', (ai) => ai.customEdit(_body.text, p));
      _prompt.clear();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: TextField(
        controller: _prompt,
        autofocus: true,
        minLines: 1,
        maxLines: 4,
        style: const TextStyle(fontSize: 13),
        onSubmitted: (_) => go(),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: c.fill,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
          hintText: 'How should it change? e.g. "mention the deadline is Friday"',
          suffixIcon: ToolButton(icon: CupertinoIcons.arrow_up_circle_fill, tooltip: 'Apply', onPressed: go),
        ),
      ),
    );
  }
}

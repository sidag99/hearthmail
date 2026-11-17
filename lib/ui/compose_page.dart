import 'dart:async';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:intl/intl.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/ai/email_ai.dart';
import '../services/mail_service.dart';
import '../services/user_data.dart';
import '../state/app_state.dart';
import 'message_view.dart' show pickDateTime;
import 'sidebar.dart';

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
  String? _undoText;
  String? _replyLanguage;

  bool get _generating => _aiSub != null;

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
      final me = _from?.config.email.toLowerCase() ?? '';
      final replyTo = (r.replyTo?.isNotEmpty ?? false) ? r.replyTo! : (r.from ?? const <MailAddress>[]);
      _to.text = MailService.addressList(replyTo);
      if (widget.replyAll) {
        final others = [...?r.to, ...?r.cc]
            .where((a) => a.email.toLowerCase() != me && !replyTo.any((x) => x.email == a.email))
            .toList();
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
            state.ai!.compose(
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
        _runAi('Writing reply…', state.ai!.draftReply(state.contentOf(r), instruction: widget.aiReplyInstruction!));
      });
    }
    _showAiWriter = _original == null && restore == null && widget.followUpOf == null && state.aiReady && _body.text.isEmpty;
    // The AI toolbar offers rewrites only once there is text.
    var hadText = _body.text.trim().isNotEmpty;
    _body.addListener(() {
      final hasText = _body.text.trim().isNotEmpty;
      if (hasText != hadText && mounted) setState(() => hadText = hasText);
    });
    _initialSnapshot = _snapshot();
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
    _aiSub?.cancel();
    for (final c in [_to, _cc, _bcc, _subject, _body, _prompt]) {
      c.dispose();
    }
    _bodyFocus.dispose();
    for (final f in _fieldFocus.values) {
      f.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------------------ AI

  void _runAi(String label, Stream<String> stream) {
    _aiSub?.cancel();
    _undoText = _body.text;
    final buf = StringBuffer();
    setState(() {
      _aiLabel = label;
      _preview = false;
      _body.text = '';
    });
    _aiSub = stream.listen(
      (chunk) {
        buf.write(chunk);
        _body.value = TextEditingValue(text: buf.toString());
      },
      onError: (Object e) {
        _snack('AI error: $e');
        _body.text = _undoText ?? '';
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
        inReplyTo: widget.replyTo,
        files: [..._files],
        sendAt: sendAt,
        followUpDays: _followUpDays,
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
    await state.sendMail(_mail(state, sendAt: at));
    _sent = true;
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
    if (choice == 'discard') return true;
    if (choice != 'save' || _from == null) return false;
    try {
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
    final theme = Theme.of(context);
    final title = widget.forwardOf != null
        ? 'Forward'
        : widget.replyTo != null
            ? 'Reply'
            : 'New message';

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
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): _send,
          const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop(),
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(title),
            actions: [
              IconButton(icon: const Icon(Icons.attach_file), tooltip: 'Attach files', onPressed: _attach),
              IconButton(icon: const Icon(Icons.description_outlined), tooltip: 'Templates', onPressed: () => _templates(state)),
              IconButton(
                icon: Icon(_preview ? Icons.edit : Icons.visibility_outlined),
                tooltip: _preview ? 'Edit' : 'Preview formatting',
                onPressed: _generating ? null : () => setState(() => _preview = !_preview),
              ),
              PopupMenuButton<int>(
                tooltip: 'Remind me if no reply',
                icon: Icon(_followUpDays == null ? Icons.notifications_none : Icons.notifications_active,
                    color: _followUpDays == null ? null : theme.colorScheme.primary),
                initialValue: _followUpDays ?? 0,
                onSelected: (d) => setState(() => _followUpDays = d == 0 ? null : d),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 0, child: Text('No follow-up reminder')),
                  PopupMenuItem(value: 1, child: Text('Remind me if no reply in 1 day')),
                  PopupMenuItem(value: 3, child: Text('Remind me if no reply in 3 days')),
                  PopupMenuItem(value: 7, child: Text('Remind me if no reply in 1 week')),
                ],
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.horizontal(left: Radius.circular(20))),
                    ),
                    icon: const Icon(Icons.send, size: 16),
                    label: const Text('Send'),
                    onPressed: _generating || _loadingAttachments ? null : _send,
                  ),
                  const SizedBox(width: 1),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(32, 40),
                      shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.horizontal(right: Radius.circular(20))),
                    ),
                    onPressed: _generating || _loadingAttachments ? null : _sendLater,
                    child: const Tooltip(message: 'Send later', child: Icon(Icons.schedule_send, size: 16)),
                  ),
                ]),
              ),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: Column(children: [
                if (state.sessions.length > 1) _fromPicker(state),
                _recipientField('To', _to, state,
                    trailing: TextButton(
                      onPressed: () => setState(() => _showCc = !_showCc),
                      child: const Text('Cc/Bcc'),
                    )),
                if (_showCc) ...[
                  _recipientField('Cc', _cc, state),
                  _recipientField('Bcc', _bcc, state),
                ],
                _field('Subject', _subject,
                    trailing: ai == null
                        ? null
                        : _suggestingSubject
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                              )
                            : IconButton(
                                icon: Icon(Icons.auto_awesome, size: 16, color: theme.colorScheme.primary),
                                tooltip: 'Suggest a subject',
                                onPressed: () => _suggestSubject(ai),
                              )),
                if (_files.isNotEmpty || _loadingAttachments)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(spacing: 6, runSpacing: 6, children: [
                        if (_loadingAttachments)
                          const Chip(
                            avatar: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                            label: Text('Loading attachments…'),
                          ),
                        for (final f in _files)
                          InputChip(
                            avatar: const Icon(Icons.attach_file, size: 16),
                            label: Text(f.uri.pathSegments.last),
                            onDeleted: () => setState(() => _files.remove(f)),
                          ),
                      ]),
                    ),
                  ),
                if (ai != null) _aiToolbar(ai, theme, state),
                if (ai != null && _showAiWriter && !_generating) _aiWriter(ai, theme),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: _preview
                        ? SingleChildScrollView(
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                              child: HtmlWidget(
                                md.markdownToHtml(_body.text, extensionSet: md.ExtensionSet.gitHubWeb),
                                textStyle: const TextStyle(color: Colors.black87, fontSize: 14),
                              ),
                            ),
                          )
                        : TextField(
                            controller: _body,
                            focusNode: _bodyFocus,
                            readOnly: _generating,
                            maxLines: null,
                            expands: true,
                            textAlignVertical: TextAlignVertical.top,
                            style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              hintText: 'Write your message… (**bold** and "- " bullets are sent as formatting)',
                            ),
                          ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(children: [
                    if (widget.replyTo != null && widget.restore == null)
                      Expanded(
                        child: CheckboxListTile(
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _includeQuote,
                          onChanged: (v) => setState(() => _includeQuote = v ?? true),
                          title: Text('Include original message (${MailService.senderName(widget.replyTo!)})'),
                        ),
                      )
                    else
                      const Spacer(),
                    if ((state.userData.signatures[_from?.id] ?? '').trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text('Signature added when sending', style: theme.textTheme.labelSmall),
                      ),
                    if (_followUpDays != null)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text('Follow-up reminder in $_followUpDays day${_followUpDays == 1 ? '' : 's'}',
                            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)),
                      ),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fromPicker(AppState state) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          SizedBox(
            width: 64,
            child: Text('From', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          DropdownButtonHideUnderline(
            child: DropdownButton<AccountSession>(
              value: _from,
              items: [
                for (final s in state.sessions)
                  DropdownMenuItem(value: s, child: AccountBadge(config: s.config, index: state.indexOf(s))),
              ],
              onChanged: (s) => setState(() => _from = s),
            ),
          ),
          if (_from != null && !_from!.connected)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text('not connected', style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
            ),
        ]),
      );

  Widget _field(String label, TextEditingController c, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          SizedBox(
            width: 64,
            child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          Expanded(
            child: TextField(controller: c, decoration: const InputDecoration(border: InputBorder.none, isDense: true)),
          ),
          ?trailing,
        ]),
      );

  /// An address field that suggests people you have emailed before.
  Widget _recipientField(String label, TextEditingController c, AppState state, {Widget? trailing}) {
    final focus = _fieldFocus.putIfAbsent(c, FocusNode.new);
    String lastToken(String text) => text.split(RegExp(r'[,;]')).last.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        SizedBox(
          width: 64,
          child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
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
              decoration: const InputDecoration(border: InputBorder.none, isDense: true),
            ),
            optionsViewBuilder: (context, onSelected, options) => Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420, maxHeight: 260),
                  child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: [
                    for (final o in options)
                      ListTile(
                        dense: true,
                        title: Text(o.$2.isEmpty ? o.$1 : o.$2),
                        subtitle: o.$2.isEmpty ? null : Text(o.$1),
                        onTap: () => onSelected(o),
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

  Widget _aiToolbar(EmailAi ai, ThemeData theme, AppState state) {
    final hasText = _body.text.trim().isNotEmpty;
    final languages = [
      ?_replyLanguage,
      ...Languages.common.where((l) => l != _replyLanguage && l != state.settings.myLanguage),
    ];
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(10),
      ),
      child: _generating
          ? Row(children: [
              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Text(_aiLabel ?? 'Writing…'),
              const Spacer(),
              TextButton.icon(onPressed: _stopAi, icon: const Icon(Icons.stop, size: 16), label: const Text('Stop')),
            ])
          : Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Icon(Icons.auto_awesome, size: 16, color: theme.colorScheme.primary),
              ActionChip(
                label: const Text('Write for me'),
                onPressed: () => setState(() => _showAiWriter = !_showAiWriter),
              ),
              if (hasText) ...[
                for (final style in RewriteStyle.values)
                  ActionChip(
                    label: Text(style.label),
                    onPressed: () => _runAi('${style.label}…', ai.rewrite(_body.text, style)),
                  ),
                if (_replyLanguage != null)
                  ActionChip(
                    avatar: const Icon(Icons.translate, size: 14),
                    label: Text('In $_replyLanguage'),
                    onPressed: () => _runAi('Translating to $_replyLanguage…',
                        ai.translate(_body.text, _replyLanguage!, source: state.settings.myLanguage, forSending: true)),
                  ),
                PopupMenuButton<String>(
                  tooltip: 'Translate',
                  onSelected: (l) => _runAi('Translating to $l…', ai.translate(_body.text, l, forSending: true)),
                  itemBuilder: (_) => [for (final l in languages) PopupMenuItem(value: l, child: Text(l))],
                  child: const Chip(avatar: Icon(Icons.translate, size: 14), label: Text('Translate…')),
                ),
              ],
              if (_undoText != null)
                TextButton.icon(onPressed: _undo, icon: const Icon(Icons.undo, size: 16), label: const Text('Undo AI')),
            ]),
    );
  }

  Widget _aiWriter(EmailAi ai, ThemeData theme) {
    final hasText = _body.text.trim().isNotEmpty;
    void go() {
      final p = _prompt.text.trim();
      if (p.isEmpty) return;
      setState(() => _showAiWriter = false);
      if (hasText) {
        _runAi('Editing…', ai.customEdit(_body.text, p));
      } else {
        _runAi('Writing…', ai.compose(p, to: _to.text, subject: _subject.text));
      }
      _prompt.clear();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: TextField(
        controller: _prompt,
        autofocus: true,
        minLines: 1,
        maxLines: 4,
        onSubmitted: (_) => go(),
        decoration: InputDecoration(
          hintText: hasText
              ? 'How should I change it? e.g. "mention the deadline is Friday"'
              : 'What should the email say? e.g. "ask landlord to fix leaking sink this week, home after 5"',
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          isDense: true,
          suffixIcon: IconButton(icon: const Icon(Icons.arrow_upward), tooltip: 'Write', onPressed: go),
        ),
      ),
    );
  }
}

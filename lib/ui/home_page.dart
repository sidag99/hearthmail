import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/mail_service.dart';
import '../state/app_state.dart';
import 'compose_page.dart';
import 'message_list.dart';
import 'message_view.dart';
import 'settings_page.dart';
import 'sidebar.dart';
import 'widgets/ai_widgets.dart';

/// Three panes on a wide window (Mac/Windows/tablet); one pane at a time
/// on a narrow one (phones), so the same code serves every platform.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _searchFocus = FocusNode();
  StreamSubscription<Toast>? _toastSub;
  StreamSubscription<OutgoingMail>? _undoSub;
  bool _showingMessageOnPhone = false;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _toastSub = state.toasts.listen((t) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(t.message),
          duration: t.duration,
          action: t.action == null ? null : SnackBarAction(label: t.action!, onPressed: t.onAction ?? () {}),
        ));
    });
    // "Undo send" (or a failed send) re-opens the message for editing.
    _undoSub = state.undoneSends.listen((mail) {
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ComposePage(restore: mail)));
    });
  }

  @override
  void dispose() {
    _toastSub?.cancel();
    _undoSub?.cancel();
    _searchFocus.dispose();
    super.dispose();
  }

  void _compose() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ComposePage()));

  void _settings() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));

  void _catchUp(AppState state) {
    final ai = state.ai;
    if (ai == null) return;
    final all = state.allInboxMessages;
    final unread = all.where((m) => !m.isSeen).take(30).toList();
    final source = unread.length >= 3 ? unread : all.take(20).toList();
    if (source.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (c) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 640),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SingleChildScrollView(
              child: AiCard(
                title: unread.length >= 3
                    ? 'Catch me up — ${source.length} unread emails'
                    : 'Catch me up — your latest ${source.length} emails',
                onClose: () => Navigator.pop(c),
                child: AiStreamView(
                  placeholder: 'Reading your inbox…',
                  start: () => ai.digest([for (final m in source) state.contentOf(m)]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final selected = state.selected;
    final wide = MediaQuery.sizeOf(context).width >= 900;

    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyN, meta: true): _compose,
      const SingleActivator(LogicalKeyboardKey.keyF, meta: true): _searchFocus.requestFocus,
      const SingleActivator(LogicalKeyboardKey.comma, meta: true): _settings,
      if (selected != null) ...{
        // Same shortcuts as Apple Mail.
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true): () => openReply(context, selected),
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true, shift: true): () =>
            openReply(context, selected, replyAll: true),
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true, shift: true): () => openForward(context, selected),
        const SingleActivator(LogicalKeyboardKey.keyE, meta: true): () => state.archiveMessage(selected),
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true, control: true): () => state.archiveMessage(selected),
        const SingleActivator(LogicalKeyboardKey.backspace, meta: true): () => state.deleteMessage(selected),
        const SingleActivator(LogicalKeyboardKey.keyU, meta: true, shift: true): () => state.toggleRead(selected),
        const SingleActivator(LogicalKeyboardKey.keyL, meta: true, shift: true): () => state.toggleFlag(selected),
        const SingleActivator(LogicalKeyboardKey.keyJ, meta: true, shift: true): () => state.junkMessage(selected),
      },
    };

    final actions = [
      if (state.aiReady && state.allInboxMessages.isNotEmpty)
        wide
            ? TextButton.icon(
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: const Text('Catch me up'),
                onPressed: () => _catchUp(state),
              )
            : IconButton(
                icon: const Icon(Icons.auto_awesome),
                tooltip: 'Catch me up',
                onPressed: () => _catchUp(state),
              ),
      IconButton(icon: const Icon(Icons.edit_square), tooltip: 'New message (⌘N)', onPressed: _compose),
      IconButton(icon: const Icon(Icons.settings_outlined), tooltip: 'Settings (⌘,)', onPressed: _settings),
      const SizedBox(width: 8),
    ];

    final Widget body;
    if (wide) {
      body = Row(children: [
        const SizedBox(width: 240, child: Sidebar()),
        const VerticalDivider(width: 1),
        SizedBox(width: 380, child: MessageListPane(searchFocus: _searchFocus)),
        const VerticalDivider(width: 1),
        const Expanded(child: MessageView()),
      ]);
    } else if (_showingMessageOnPhone && selected != null) {
      body = MessageView(onBack: () => setState(() => _showingMessageOnPhone = false));
    } else {
      body = MessageListPane(
        searchFocus: _searchFocus,
        onOpen: () => setState(() => _showingMessageOnPhone = true),
      );
    }

    return CallbackShortcuts(
      bindings: shortcuts,
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            toolbarHeight: 48,
            titleSpacing: 16,
            title: Text(
              selected == null || wide ? 'Hearthmail' : MailService.subjectOf(selected),
              style: Theme.of(context).textTheme.titleMedium,
              overflow: TextOverflow.ellipsis,
            ),
            actions: actions,
          ),
          drawer: wide ? null : Drawer(child: SafeArea(child: Sidebar(onNavigate: () => Navigator.of(context).pop()))),
          body: body,
        ),
      ),
    );
  }
}

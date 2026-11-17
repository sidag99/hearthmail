import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'compose_page.dart';
import 'mac_style.dart';
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

    final Widget body;
    if (wide) {
      body = Row(children: [
        SizedBox(width: 220, child: Sidebar(onSettings: _settings)),
        const Hairline(vertical: true),
        SizedBox(
          width: 340,
          child: MessageListPane(
            searchFocus: _searchFocus,
            onCompose: _compose,
            onCatchUp: state.allInboxMessages.isEmpty ? null : () => _catchUp(state),
          ),
        ),
        const Hairline(vertical: true),
        Expanded(child: MessageView(search: MailSearchField(focus: _searchFocus))),
      ]);
    } else if (_showingMessageOnPhone && selected != null) {
      body = SafeArea(child: MessageView(onBack: () => setState(() => _showingMessageOnPhone = false)));
    } else {
      body = SafeArea(
        child: MessageListPane(
          searchFocus: _searchFocus,
          showSearch: true,
          onCompose: _compose,
          onCatchUp: state.allInboxMessages.isEmpty ? null : () => _catchUp(state),
          leading: Builder(
            builder: (bc) => ToolButton(
              icon: CupertinoIcons.sidebar_left,
              tooltip: 'Mailboxes',
              onPressed: () => Scaffold.of(bc).openDrawer(),
            ),
          ),
          onOpen: () => setState(() => _showingMessageOnPhone = true),
        ),
      );
    }

    return CallbackShortcuts(
      bindings: shortcuts,
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: useMacWindow ? Colors.transparent : null,
          drawer: wide
              ? null
              : Drawer(
                  child: Sidebar(onSettings: _settings, onNavigate: () => Navigator.of(context).pop()),
                ),
          body: body,
        ),
      ),
    );
  }
}

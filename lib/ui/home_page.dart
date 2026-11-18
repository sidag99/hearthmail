import 'dart:async';

import 'package:enough_mail/enough_mail.dart' show MimeMessage;
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart';

import 'dart:ui' show AppExitResponse;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/mailto.dart';
import '../services/print_message.dart';
import '../state/app_state.dart';
import 'app_menus.dart';
import 'catch_up.dart';
import 'compose_page.dart';
import 'folder_dialogs.dart';
import 'mac_style.dart';
import 'message_list.dart';
import 'message_view.dart';
import 'settings_page.dart';
import 'sidebar.dart';

/// Three resizable panes on a wide window (Mac/Windows/tablet); one pane
/// at a time on a narrow one (phones), so the same code serves every
/// platform.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _searchFocus = FocusNode();

  /// Focus for the message list's keyboard shortcuts (arrows, Delete).
  final _listKeys = FocusNode(debugLabel: 'list keys');
  StreamSubscription<Toast>? _toastSub;
  StreamSubscription<OutgoingMail>? _undoSub;
  StreamSubscription<MailtoRequest>? _mailtoSub;
  StreamSubscription<MimeMessage>? _openSub;
  bool _showingMessageOnPhone = false;
  AppLifecycleListener? _lifecycle;

  // Column layout, remembered between launches.
  static const _sidebarRange = (min: 170.0, max: 360.0);
  static const _listRange = (min: 260.0, max: 600.0);
  static const _minReader = 380.0;
  double _sidebarWidth = 220;
  double _listWidth = 340;
  bool _sidebarVisible = true;
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _toastSub = state.toasts.listen((t) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(t.message),
            duration: t.duration,
            action: t.action == null
                ? null
                : SnackBarAction(
                    label: t.action!,
                    onPressed: t.onAction ?? () {},
                  ),
          ),
        );
    });
    // "Undo send" (or a failed send) re-opens the message for editing.
    _undoSub = state.undoneSends.listen((mail) {
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ComposePage(restore: mail)),
      );
    });
    // A clicked notification already selected its message; on phones,
    // also switch to the message.
    _openSub = state.openRequests.listen((_) {
      if (mounted) setState(() => _showingMessageOnPhone = true);
    });
    if (useMacWindow) {
      // mailto: links clicked in other apps.
      final urls = UrlEvents();
      _mailtoSub = urls.requests.listen(_composeMailto);
      unawaited(urls.start());
    }
    unawaited(_loadLayout());
    // Quitting during "Undo send" sends those messages instead of losing them.
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await state.flushPendingSends().timeout(
          const Duration(seconds: 20),
          onTimeout: () {},
        );
        return AppExitResponse.exit;
      },
    );
  }

  Future<void> _loadLayout() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _prefs = p;
      _sidebarWidth = (p.getDouble('layout.sidebarWidth') ?? _sidebarWidth)
          .clamp(_sidebarRange.min, _sidebarRange.max);
      _listWidth = (p.getDouble('layout.listWidth') ?? _listWidth).clamp(
        _listRange.min,
        _listRange.max,
      );
      _sidebarVisible = p.getBool('layout.sidebarVisible') ?? true;
    });
  }

  void _saveLayout() {
    final p = _prefs;
    if (p == null) return;
    unawaited(p.setDouble('layout.sidebarWidth', _sidebarWidth));
    unawaited(p.setDouble('layout.listWidth', _listWidth));
    unawaited(p.setBool('layout.sidebarVisible', _sidebarVisible));
  }

  @override
  void dispose() {
    _toastSub?.cancel();
    _undoSub?.cancel();
    _mailtoSub?.cancel();
    _openSub?.cancel();
    _lifecycle?.dispose();
    _searchFocus.dispose();
    _listKeys.dispose();
    super.dispose();
  }

  void _compose() =>
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const ComposePage()));

  void _composeMailto(MailtoRequest r) {
    if (!mounted) return;
    final from = context.read<AppState>().defaultSendingSession;
    if (from == null) return;
    final mail = OutgoingMail(
      from: from,
      to: r.to.join(', '),
      cc: r.cc.join(', '),
      bcc: r.bcc.join(', '),
      subject: r.subject,
      body: r.body,
    );
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => ComposePage(restore: mail)));
  }

  void _settings() => showSettings(context);

  void _toggleSidebar() {
    setState(() => _sidebarVisible = !_sidebarVisible);
    _saveLayout();
  }

  AppMenuActions _menuActions(AppState state) {
    final m = state.selected;
    VoidCallback? on(void Function(MimeMessage m) f) =>
        m == null ? null : () => f(m);
    final session = state.view.kind == ViewKind.folder
        ? state.folderSession
        : null;
    final box = state.view.kind == ViewKind.folder ? state.folderBox : null;
    final anySession = session ?? state.defaultSendingSession;
    return AppMenuActions(
      about: () => showAboutDialog(
        context: context,
        applicationName: 'Hearthmail',
        applicationLegalese: 'Open source under the MIT License.\nYour mail and AI stay on this Mac unless you choose a cloud model.',
      ),
      settings: _settings,
      newMessage: _compose,
      print: m == null ? null : () => printMessage(m, state),
      find: _searchFocus.requestFocus,
      toggleSidebar: _toggleSidebar,
      sidebarVisible: _sidebarVisible,
      getNewMail: () => state.refresh(),
      newMailbox: anySession == null
          ? null
          : () => showNewMailboxDialog(context, state, anySession),
      renameMailbox: session == null || box == null
          ? null
          : () => showRenameMailboxDialog(context, state, session, box),
      deleteMailbox: session == null || box == null
          ? null
          : () => confirmDeleteMailbox(context, state, session, box),
      reply: on((m) => openReply(context, m)),
      replyAll: on((m) => openReply(context, m, replyAll: true)),
      forward: on((m) => openForward(context, m)),
      archive: on((m) => state.archiveMessage(m)),
      junk: on((m) => state.junkMessage(m)),
      delete: on((m) => state.deleteMessage(m)),
      flag: on((m) => state.toggleFlag(m)),
      markUnread: on((m) => state.toggleRead(m)),
      remind: m == null
          ? null
          : () async {
              final when = await pickDateTime(context, help: 'Remind me on');
              if (when != null) await state.snooze(m, when);
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final selected = state.selected;
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= _listRange.min + _minReader;
    final catchUp = state.allInboxMessages.isEmpty || !state.aiReady
        ? null
        : () => showCatchUp(context);

    // On macOS the menu bar owns the shortcuts; elsewhere bind them here.
    final shortcuts = <ShortcutActivator, VoidCallback>{
      if (!useMacWindow) ...{
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): _compose,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            _searchFocus.requestFocus,
        const SingleActivator(LogicalKeyboardKey.comma, meta: true): _settings,
      },
      if (selected != null) ...{
        if (!useMacWindow) ...{
          const SingleActivator(LogicalKeyboardKey.keyR, meta: true): () =>
              openReply(context, selected),
          const SingleActivator(
            LogicalKeyboardKey.keyR,
            meta: true,
            shift: true,
          ): () =>
              openReply(context, selected, replyAll: true),
          const SingleActivator(
            LogicalKeyboardKey.keyF,
            meta: true,
            shift: true,
          ): () =>
              openForward(context, selected),
          const SingleActivator(
            LogicalKeyboardKey.keyA,
            meta: true,
            control: true,
          ): () =>
              state.archiveMessage(selected),
          const SingleActivator(LogicalKeyboardKey.backspace, meta: true): () =>
              state.deleteMessage(selected),
          const SingleActivator(
            LogicalKeyboardKey.keyU,
            meta: true,
            shift: true,
          ): () =>
              state.toggleRead(selected),
          const SingleActivator(
            LogicalKeyboardKey.keyL,
            meta: true,
            shift: true,
          ): () =>
              state.toggleFlag(selected),
          const SingleActivator(
            LogicalKeyboardKey.keyJ,
            meta: true,
            shift: true,
          ): () =>
              state.junkMessage(selected),
        },
        // Mail: Delete moves to Trash; arrows go through the list.
        const SingleActivator(LogicalKeyboardKey.backspace): () => state.deleteMessage(selected),
        const SingleActivator(LogicalKeyboardKey.delete): () => state.deleteMessage(selected),
      },
      const SingleActivator(LogicalKeyboardKey.arrowDown): () => state.selectAdjacent(1),
      const SingleActivator(LogicalKeyboardKey.arrowUp): () => state.selectAdjacent(-1),
    };

    final Widget body;
    if (wide) {
      // Shrink the list before hiding the sidebar, and always leave the
      // reader enough room.
      final listWidth = _listWidth.clamp(
        _listRange.min,
        (width - _minReader).clamp(_listRange.min, _listRange.max),
      );
      final showSidebar =
          _sidebarVisible && width - listWidth - _sidebarWidth >= _minReader;
      final sidebarWidth = _sidebarWidth;
      body = Row(
        children: [
          if (showSidebar) ...[
            SizedBox(
              width: sidebarWidth,
              child: Sidebar(onSettings: _settings),
            ),
            _Splitter(
              onDrag: (dx) => setState(() {
                _sidebarWidth = (_sidebarWidth + dx).clamp(
                  _sidebarRange.min,
                  _sidebarRange.max,
                );
              }),
              onEnd: _saveLayout,
            ),
          ],
          SizedBox(
            width: listWidth,
            child: MessageListPane(
              searchFocus: _searchFocus,
              onCompose: _compose,
              onCatchUp: catchUp,
              onOpen: _listKeys.requestFocus,
              titleInset: !showSidebar && useMacWindow ? kTitlebarInset : 0,
              leading: showSidebar
                  ? null
                  : Builder(
                      builder: (bc) => ToolButton(
                        icon: CupertinoIcons.sidebar_left,
                        tooltip: 'Show Sidebar',
                        onPressed:
                            width - listWidth - _sidebarWidth >= _minReader
                            ? _toggleSidebar
                            : () => Scaffold.of(bc).openDrawer(),
                      ),
                    ),
            ),
          ),
          _Splitter(
            onDrag: (dx) => setState(() {
              _listWidth = (listWidth + dx).clamp(
                _listRange.min,
                _listRange.max,
              );
            }),
            onEnd: _saveLayout,
          ),
          Expanded(
            child: MessageView(search: MailSearchField(focus: _searchFocus)),
          ),
        ],
      );
    } else if (_showingMessageOnPhone && selected != null) {
      body = SafeArea(
        child: MessageView(
          leadingInset: useMacWindow ? kTitlebarInset : 0,
          onBack: () => setState(() => _showingMessageOnPhone = false),
        ),
      );
    } else {
      body = SafeArea(
        child: MessageListPane(
          searchFocus: _searchFocus,
          showSearch: true,
          onCompose: _compose,
          onCatchUp: catchUp,
          titleInset: useMacWindow ? kTitlebarInset : 0,
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

    return AppMenus(
      actions: _menuActions(state),
      child: CallbackShortcuts(
        bindings: shortcuts,
        child: Focus(
          focusNode: _listKeys,
          autofocus: true,
          child: Scaffold(
            backgroundColor: useMacWindow ? Colors.transparent : null,
            drawer: Drawer(
              child: Sidebar(
                onSettings: _settings,
                onNavigate: () => Navigator.of(context).pop(),
              ),
            ),
            drawerEnableOpenDragGesture: !wide,
            body: body,
          ),
        ),
      ),
    );
  }
}

/// The hairline between two columns; drag it to resize them.
class _Splitter extends StatefulWidget {
  const _Splitter({required this.onDrag, required this.onEnd});
  final void Function(double dx) onDrag;
  final VoidCallback onEnd;

  @override
  State<_Splitter> createState() => _SplitterState();
}

class _SplitterState extends State<_Splitter> {
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    // A 1 pt line inside a wider hit area, like AppKit split views.
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _active = true),
      onExit: (_) => setState(() => _active = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) => widget.onEnd(),
        child: ColoredBox(
          color: c.window,
          child: SizedBox(
            width: 5,
            child: Center(
              child: Container(
                width: 1,
                color: _active
                    ? c.secondaryLabel.withValues(alpha: 0.5)
                    : c.separator,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

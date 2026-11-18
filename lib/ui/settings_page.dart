import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/account_config.dart';
import '../services/ai/email_ai.dart';
import '../services/mailto.dart';
import '../services/settings_store.dart';
import '../state/app_state.dart';
import 'account_setup_page.dart';
import 'mac_style.dart';
import 'settings/ai_settings_pane.dart';

/// The settings tabs, in Apple Mail's order (plus AI).
enum SettingsTab {
  general('General', CupertinoIcons.gear),
  accounts('Accounts', CupertinoIcons.at),
  junk('Junk Mail', CupertinoIcons.xmark_octagon),
  viewing('Viewing', CupertinoIcons.eyeglasses),
  composing('Composing', CupertinoIcons.square_pencil),
  signatures('Signatures', CupertinoIcons.signature),
  rules('Rules', CupertinoIcons.envelope_badge),
  ai('AI', CupertinoIcons.sparkles),
  privacy('Privacy', CupertinoIcons.hand_raised);

  const SettingsTab(this.label, this.icon);
  final String label;
  final IconData icon;
}

SettingsTab _lastTab = SettingsTab.general;

/// Opens Settings as a window-like panel with Apple Mail's tab toolbar.
Future<void> showSettings(BuildContext context, {SettingsTab? tab}) {
  final state = context.read<AppState>();
  return showDialog<void>(
    context: context,
    animationStyle: AnimationStyle.noAnimation,
    barrierColor: Colors.black26,
    builder: (_) => ChangeNotifierProvider.value(value: state, child: SettingsWindow(initialTab: tab ?? _lastTab)),
  );
}

class SettingsWindow extends StatefulWidget {
  const SettingsWindow({super.key, this.initialTab = SettingsTab.general});
  final SettingsTab initialTab;

  @override
  State<SettingsWindow> createState() => _SettingsWindowState();
}

class _SettingsWindowState extends State<SettingsWindow> {
  late SettingsTab _tab = widget.initialTab;

  void _select(SettingsTab t) => setState(() => _tab = _lastTab = t);

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    final size = MediaQuery.sizeOf(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyW, meta: true): () => Navigator.of(context).pop(),
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          backgroundColor: c.window,
          insetPadding: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: (size.width - 32).clamp(320, 820),
            height: (size.height - 32).clamp(360, 680),
            child: Column(children: [
              // Title, like the window title of Mail's settings.
              SizedBox(
                height: 30,
                width: double.infinity,
                child: Stack(alignment: Alignment.center, children: [
                  Text(_tab.label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.label)),
                  Positioned(
                    left: 6,
                    child: ToolButton(
                      icon: CupertinoIcons.xmark,
                      size: 12,
                      tooltip: 'Close (⌘W)',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ]),
              ),
              _TabBar(selected: _tab, onSelect: _select),
              const Hairline(),
              Expanded(
                child: SingleChildScrollView(
                  key: PageStorageKey(_tab),
                  padding: const EdgeInsets.fromLTRB(28, 22, 28, 28),
                  child: switch (_tab) {
                    SettingsTab.general => const _GeneralTab(),
                    SettingsTab.accounts => const _AccountsTab(),
                    SettingsTab.junk => const _JunkTab(),
                    SettingsTab.viewing => const _ViewingTab(),
                    SettingsTab.composing => const _ComposingTab(),
                    SettingsTab.signatures => const _SignaturesTab(),
                    SettingsTab.rules => const _RulesTab(),
                    SettingsTab.ai => const _AiTab(),
                    SettingsTab.privacy => const _PrivacyTab(),
                  },
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Icon-over-label tabs, centered, the selected one tinted.
class _TabBar extends StatelessWidget {
  const _TabBar({required this.selected, required this.onSelect});
  final SettingsTab selected;
  final ValueChanged<SettingsTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    return SizedBox(
      height: 58,
      child: Center(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            for (final t in SettingsTab.values)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => onSelect(t),
                  child: Container(
                    width: 74,
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    decoration: BoxDecoration(
                      color: t == selected ? c.fill : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(t.icon, size: 20, color: t == selected ? c.accent : c.secondaryLabel),
                      const SizedBox(height: 3),
                      Text(t.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: t == selected ? c.accent : c.label)),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- building blocks

/// "Label:  control", with labels right-aligned in a column like AppKit forms.
class _Row extends StatelessWidget {
  const _Row(this.label, this.child, {this.help});
  final String label;
  final Widget child;
  final String? help;

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 200,
          child: Padding(
            padding: const EdgeInsets.only(top: 5, right: 10),
            child: Text(label.isEmpty ? '' : '$label:',
                textAlign: TextAlign.right, style: TextStyle(fontSize: 13, color: c.label)),
          ),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            child,
            if (help != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(help!, style: TextStyle(fontSize: 11, color: c.secondaryLabel)),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// A Mac-style pop-up button.
class _Popup<T> extends StatelessWidget {
  const _Popup({required this.value, required this.items, required this.onChanged});
  final T value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    final known = items.any((i) => i.$1 == value);
    return Container(
      height: 26,
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(
        color: c.fill,
        borderRadius: BorderRadius.circular(6),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: known ? value : items.first.$1,
          isDense: true,
          focusColor: Colors.transparent,
          icon: Icon(CupertinoIcons.chevron_up_chevron_down, size: 12, color: c.secondaryLabel),
          style: TextStyle(fontSize: 13, color: c.label),
          dropdownColor: c.window,
          items: [for (final (v, l) in items) DropdownMenuItem(value: v, child: Text(l))],
          onChanged: (v) => v == null ? null : onChanged(v),
        ),
      ),
    );
  }
}

/// A checkbox with its label, as Mac settings use (rather than switches).
class _Check extends StatelessWidget {
  const _Check(this.label, this.value, this.onChanged, {this.help});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? help;

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: () => onChanged(!value),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 22,
            height: 22,
            child: Checkbox(value: value, visualDensity: VisualDensity.compact, onChanged: (v) => onChanged(v ?? false)),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: TextStyle(fontSize: 13, color: c.label)),
                if (help != null)
                  Text(help!, style: TextStyle(fontSize: 11, color: c.secondaryLabel)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group(this.title, this.children);
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.label)),
        const SizedBox(height: 8),
        ...children,
      ]),
    );
  }
}

/// A list of removable entries (VIPs, blocked senders).
class _EntryList extends StatelessWidget {
  const _EntryList({required this.entries, required this.empty, required this.onRemove});
  final List<String> entries;
  final String empty;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 80, maxHeight: 220),
      decoration: BoxDecoration(border: Border.all(color: c.separator), borderRadius: BorderRadius.circular(6)),
      child: entries.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(empty, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: c.secondaryLabel)),
              ),
            )
          : ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(vertical: 2), children: [
              for (final e in entries)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
                  child: Row(children: [
                    Expanded(child: Text(e, style: TextStyle(fontSize: 13, color: c.label))),
                    ToolButton(icon: CupertinoIcons.minus_circle, size: 14, tooltip: 'Remove', onPressed: () => onRemove(e)),
                  ]),
                ),
            ]),
    );
  }
}

AppState _st(BuildContext context) => context.watch<AppState>();
Future<void> _save(BuildContext context, AppSettings s) => context.read<AppState>().updateSettings(s);

// ---------------------------------------------------------------- tabs

class _GeneralTab extends StatefulWidget {
  const _GeneralTab();

  @override
  State<_GeneralTab> createState() => _GeneralTabState();
}

class _GeneralTabState extends State<_GeneralTab> {
  bool? _isDefault;

  @override
  void initState() {
    super.initState();
    if (useMacWindow) isDefaultMailApp().then((v) => mounted ? setState(() => _isDefault = v) : null);
  }

  @override
  Widget build(BuildContext context) {
    final state = _st(context);
    final s = state.settings;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (useMacWindow)
        _Row(
          'Default email reader',
          Row(children: [
            Text(_isDefault == true ? 'Hearthmail' : 'Another app', style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 10),
            if (_isDefault == false)
              OutlinedButton(
                onPressed: () async {
                  await setAsDefaultMailApp();
                  final v = await isDefaultMailApp();
                  if (mounted) setState(() => _isDefault = v);
                },
                child: const Text('Make Default'),
              ),
          ]),
          help: 'Opens mailto: links from other apps in Hearthmail.',
        ),
      _Row(
        'Mark messages as read',
        _Popup<int>(
          value: s.markReadDelay,
          items: const [(0, 'When opened'), (3, 'After 3 seconds'), (10, 'After 10 seconds'), (-1, 'Manually')],
          onChanged: (v) => _save(context, s.copyWith(markReadDelay: v)),
        ),
      ),
      _Row(
        'Notifications',
        _Check('Notify me about new mail', s.notifications, (v) => _save(context, s.copyWith(notifications: v)),
            help: 'Muted, blocked and promotional messages stay quiet.'),
      ),
      _Row(
        'My language',
        _Popup<String>(
          value: Languages.common.contains(s.myLanguage) ? s.myLanguage : 'English',
          items: [for (final l in Languages.common) (l, l)],
          onChanged: (v) => _save(context, s.copyWith(myLanguage: v)),
        ),
        help: 'Emails in other languages offer a Translate button.',
      ),
    ]);
  }
}

class _AccountsTab extends StatefulWidget {
  const _AccountsTab();

  @override
  State<_AccountsTab> createState() => _AccountsTabState();
}

class _AccountsTabState extends State<_AccountsTab> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final state = _st(context);
    final c = MacColors.of(context);
    final sessions = state.sessions;
    final i = _index.clamp(0, sessions.isEmpty ? 0 : sessions.length - 1);
    final sel = sessions.isEmpty ? null : sessions[i];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Account list, like Mail's left column.
        Container(
          width: 230,
          height: 300,
          decoration: BoxDecoration(border: Border.all(color: c.separator), borderRadius: BorderRadius.circular(6)),
          child: Column(children: [
            Expanded(
              child: ListView(padding: const EdgeInsets.all(4), children: [
                for (var k = 0; k < sessions.length; k++)
                  InkWell(
                    onTap: () => setState(() => _index = k),
                    borderRadius: BorderRadius.circular(5),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                        color: k == i ? c.accent : Colors.transparent,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Row(children: [
                        Icon(CupertinoIcons.envelope, size: 15, color: k == i ? Colors.white : c.secondaryLabel),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(sessions[k].config.email,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 13, color: k == i ? Colors.white : c.label)),
                            Text(_status(sessions[k]),
                                style: TextStyle(fontSize: 11, color: k == i ? Colors.white70 : c.secondaryLabel)),
                          ]),
                        ),
                      ]),
                    ),
                  ),
              ]),
            ),
            const Hairline(),
            Row(children: [
              ToolButton(
                icon: CupertinoIcons.plus,
                size: 13,
                tooltip: 'Add Account',
                onPressed: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AccountSetupPage()));
                },
              ),
              ToolButton(
                icon: CupertinoIcons.minus,
                size: 13,
                tooltip: 'Remove Account',
                onPressed: sel == null ? null : () => _remove(context, state, sel),
              ),
            ]),
          ]),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: sel == null
              ? Text('No accounts', style: TextStyle(color: c.secondaryLabel))
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _info(context, 'Email address', sel.config.email),
                  _info(context, 'Name', sel.config.displayName.isEmpty ? '—' : sel.config.displayName),
                  _info(
                      context,
                      'Sign-in',
                      switch (sel.config.authType) {
                        AuthType.google => 'Google',
                        AuthType.microsoft => 'Microsoft',
                        AuthType.password => 'Password (in your Keychain)',
                      }),
                  _info(context, 'Incoming server', sel.config.imapHost),
                  _info(context, 'Outgoing server', sel.config.smtpHost),
                  _info(context, 'Status', sel.status == ConnectionStatus.failed ? (sel.error ?? 'Not connected') : _status(sel)),
                  if (sel.status == ConnectionStatus.failed)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: OutlinedButton(onPressed: () => state.reconnect(sel), child: const Text('Try Again')),
                    ),
                ]),
        ),
      ]),
      const SizedBox(height: 24),
      const _SignInApps(),
    ]);
  }

  static String _status(AccountSession s) => switch (s.status) {
        ConnectionStatus.connected => 'Online',
        ConnectionStatus.failed => 'Offline',
        _ => 'Connecting…',
      };

  Widget _info(BuildContext context, String label, String value) {
    final c = MacColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 120, child: Text('$label:', style: TextStyle(fontSize: 13, color: c.secondaryLabel))),
        Expanded(child: SelectableText(value, style: TextStyle(fontSize: 13, color: c.label))),
      ]),
    );
  }

  Future<void> _remove(BuildContext context, AppState state, AccountSession sess) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove ${sess.config.email}?'),
        content: const Text('This removes the account and its saved password from Hearthmail. Your email stays on the server.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) {
      await state.removeAccount(sess.config);
      if (mounted) setState(() => _index = 0);
    }
  }
}

/// The user's own OAuth app registrations (advanced).
class _SignInApps extends StatefulWidget {
  const _SignInApps();

  @override
  State<_SignInApps> createState() => _SignInAppsState();
}

class _SignInAppsState extends State<_SignInApps> {
  late final AppState _state;
  late final TextEditingController _gId, _gSecret, _msId;
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _state = context.read<AppState>();
    _gId = TextEditingController(text: _state.settings.googleClientId);
    _gSecret = TextEditingController(text: _state.settings.googleClientSecret);
    _msId = TextEditingController(text: _state.settings.microsoftClientId);
  }

  @override
  void dispose() {
    _gId.dispose();
    _gSecret.dispose();
    _msId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = MacColors.of(context);
    InputDecoration deco(String hint) => InputDecoration(
          isDense: true,
          hintText: hint,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        onTap: () => setState(() => _open = !_open),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(_open ? CupertinoIcons.chevron_down : CupertinoIcons.chevron_right, size: 11, color: c.secondaryLabel),
          const SizedBox(width: 6),
          Text('Sign-in apps (advanced)', style: TextStyle(fontSize: 13, color: c.label)),
        ]),
      ),
      if (_open) ...[
        const SizedBox(height: 8),
        Text('Your own free app registrations for "Sign in with Google / Microsoft". See OAUTH_SETUP.md.',
            style: TextStyle(fontSize: 11, color: c.secondaryLabel)),
        const SizedBox(height: 10),
        _Row('Google client ID',
            TextField(controller: _gId, style: const TextStyle(fontSize: 13), decoration: deco(''),
                onChanged: (v) => _state.updateSettings(_state.settings.copyWith(googleClientId: v.trim())))),
        _Row('Google client secret',
            TextField(controller: _gSecret, obscureText: true, style: const TextStyle(fontSize: 13), decoration: deco(''),
                onChanged: (v) => _state.updateSettings(_state.settings.copyWith(googleClientSecret: v.trim())))),
        _Row('Microsoft client ID',
            TextField(controller: _msId, style: const TextStyle(fontSize: 13), decoration: deco(''),
                onChanged: (v) => _state.updateSettings(_state.settings.copyWith(microsoftClientId: v.trim())))),
      ],
    ]);
  }
}

class _JunkTab extends StatelessWidget {
  const _JunkTab();

  @override
  Widget build(BuildContext context) {
    final state = _st(context);
    final c = MacColors.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Your mail provider filters junk mail on its server, and it lands in each account\'s Junk mailbox.',
          style: TextStyle(fontSize: 13, color: c.label)),
      const SizedBox(height: 4),
      Text('Hearthmail also warns about emails that look like phishing or scams.',
          style: TextStyle(fontSize: 12, color: c.secondaryLabel)),
      const SizedBox(height: 20),
      _Group('Blocked senders', [
        _EntryList(
          entries: state.userData.blocked.toList(),
          empty: 'Nobody is blocked. Use Block Sender in an email\'s ⋯ menu.\nTheir new mail goes to Junk while Hearthmail is open.',
          onRemove: state.unblock,
        ),
      ]),
    ]);
  }
}

class _ViewingTab extends StatelessWidget {
  const _ViewingTab();

  @override
  Widget build(BuildContext context) {
    final s = _st(context).settings;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _Row('List preview', const SizedBox.shrink()),
      Padding(
        padding: const EdgeInsets.only(left: 200),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _Check('Show contact photos in the message list', s.showContactPhotos,
              (v) => _save(context, s.copyWith(showContactPhotos: v))),
          _Check('Group messages by conversation', s.groupConversations,
              (v) => _save(context, s.copyWith(groupConversations: v))),
          _Check('Show Mail Categories', s.showCategories, (v) => _save(context, s.copyWith(showCategories: v)),
              help: 'Primary, Transactions, Updates and Promotions, sorted by AI on this Mac.'),
          _Check('Show priority messages at the top', s.priorityFirst, (v) => _save(context, s.copyWith(priorityFirst: v))),
          const SizedBox(height: 14),
          _Check('Sort my inbox with AI', s.autoSort, (v) => _save(context, s.copyWith(autoSort: v)),
              help: 'Powers Priority, Needs Reply and the categories.'),
        ]),
      ),
    ]);
  }
}

class _ComposingTab extends StatefulWidget {
  const _ComposingTab();

  @override
  State<_ComposingTab> createState() => _ComposingTabState();
}

class _ComposingTabState extends State<_ComposingTab> {
  late final AppState _state;
  late final TextEditingController _name, _style;

  @override
  void initState() {
    super.initState();
    _state = context.read<AppState>();
    _name = TextEditingController(text: _state.settings.userName);
    _style = TextEditingController(text: _state.settings.styleNotes);
  }

  @override
  void dispose() {
    _name.dispose();
    _style.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _st(context).settings;
    final deco = InputDecoration(isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _Row(
        'Undo send delay',
        _Popup<int>(
          value: s.undoSendSeconds,
          items: const [(0, 'Off'), (5, '5 seconds'), (10, '10 seconds'), (20, '20 seconds'), (30, '30 seconds')],
          onChanged: (v) => _save(context, s.copyWith(undoSendSeconds: v)),
        ),
      ),
      _Row(
        'Your name',
        TextField(
          controller: _name,
          style: const TextStyle(fontSize: 13),
          decoration: deco,
          onChanged: (v) => _save(context, _state.settings.copyWith(userName: v.trim())),
        ),
        help: 'Used to sign emails the AI writes for you.',
      ),
      _Row(
        'Your writing style',
        TextField(
          controller: _style,
          minLines: 3,
          maxLines: 6,
          style: const TextStyle(fontSize: 13),
          decoration: deco.copyWith(hintText: 'e.g. Short and friendly. I sign off with "Cheers". No exclamation marks.'),
          onChanged: (v) => _save(context, _state.settings.copyWith(styleNotes: v)),
        ),
        help: 'The AI follows this when it writes or rewrites.',
      ),
      _Row(
        'Writing model',
        Text('Choose it from the ✨ button in the composer, or in the AI tab.',
            style: TextStyle(fontSize: 13, color: MacColors.of(context).secondaryLabel)),
      ),
    ]);
  }
}

class _SignaturesTab extends StatefulWidget {
  const _SignaturesTab();

  @override
  State<_SignaturesTab> createState() => _SignaturesTabState();
}

class _SignaturesTabState extends State<_SignaturesTab> {
  late final Map<String, TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _controllers = {
      for (final s in state.sessions) s.id: TextEditingController(text: state.userData.signatures[s.id] ?? ''),
    };
  }
  int _index = 0;

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _st(context);
    final c = MacColors.of(context);
    final sessions = state.sessions;
    if (sessions.isEmpty) return Text('Add an account first.', style: TextStyle(color: c.secondaryLabel));
    final i = _index.clamp(0, sessions.length - 1);
    final ctrl = _controllers[sessions[i].id];
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 230,
        height: 300,
        decoration: BoxDecoration(border: Border.all(color: c.separator), borderRadius: BorderRadius.circular(6)),
        child: ListView(padding: const EdgeInsets.all(4), children: [
          for (var k = 0; k < sessions.length; k++)
            InkWell(
              onTap: () => setState(() => _index = k),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(color: k == i ? c.accent : Colors.transparent, borderRadius: BorderRadius.circular(5)),
                child: Text(sessions[k].config.email,
                    overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: k == i ? Colors.white : c.label)),
              ),
            ),
        ]),
      ),
      const SizedBox(width: 20),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (ctrl != null)
            TextField(
              controller: ctrl,
              minLines: 8,
              maxLines: 12,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Signature for ${sessions[i].config.email}',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
              ),
              onChanged: (v) {
                state.userData.signatures[sessions[i].id] = v;
                state.userData.save();
              },
            ),
          const SizedBox(height: 6),
          Text('Added below your message, above any quoted text.', style: TextStyle(fontSize: 11, color: c.secondaryLabel)),
        ]),
      ),
    ]);
  }
}

class _RulesTab extends StatelessWidget {
  const _RulesTab();

  @override
  Widget build(BuildContext context) {
    final state = _st(context);
    final c = MacColors.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _Group('VIPs', [
        _EntryList(
          entries: state.userData.vips.toList(),
          empty: 'Click the ☆ next to a sender\'s name to make them a VIP.\nVIP mail always counts as Priority.',
          onRemove: state.toggleVip,
        ),
      ]),
      _Group('Muted conversations', [
        Text(
          state.userData.mutedThreads.isEmpty
              ? 'No muted conversations. Use Mute Conversation in an email\'s ⋯ menu.'
              : '${state.userData.mutedThreads.length} muted. New replies to them are archived automatically.',
          style: TextStyle(fontSize: 13, color: c.label),
        ),
      ]),
      Text('Rules run on this Mac while Hearthmail is open. Server-side filters (like Gmail\'s) keep working as usual.',
          style: TextStyle(fontSize: 11, color: c.secondaryLabel)),
    ]);
  }
}

class _AiTab extends StatelessWidget {
  const _AiTab();

  @override
  Widget build(BuildContext context) {
    final state = _st(context);
    final s = state.settings;
    final embedders = state.availableModels.where(AppState.isEmbeddingModel).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const AiSettingsPane(),
      _Group('Search', [
        _Check(
          'Search by meaning',
          s.semanticSearch,
          (v) => _save(context, s.copyWith(semanticSearch: v)),
          help: state.embeddingModel.isEmpty
              ? (embedders.isEmpty ? 'Needs an embedding model: ollama pull embeddinggemma:300m' : 'Off')
              : '${state.indexedCount} emails indexed on this Mac${state.indexing ? ' · indexing…' : ''}.',
        ),
        if (s.semanticSearch && embedders.isNotEmpty)
          _Row(
            'Emails to index per account',
            Row(children: [
              _Popup<int>(
                value: s.indexDepth,
                items: const [(1000, 'Latest 1,000'), (3000, 'Latest 3,000'), (10000, 'Latest 10,000'), (20000, 'Latest 20,000')],
                onChanged: (v) async {
                  await _save(context, s.copyWith(indexDepth: v));
                  await state.indexAll();
                },
              ),
              const SizedBox(width: 10),
              TextButton(onPressed: state.indexing ? null : state.rebuildIndex, child: const Text('Rebuild Index')),
            ]),
          ),
      ]),
    ]);
  }
}

class _PrivacyTab extends StatelessWidget {
  const _PrivacyTab();

  @override
  Widget build(BuildContext context) {
    final s = _st(context).settings;
    final c = MacColors.of(context);
    final cloud = s.writingEngine != 'local' || s.assistEngine != 'local';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _Check(
        'Block all remote content',
        !s.loadRemoteImages,
        (v) => _save(context, s.copyWith(loadRemoteImages: !v)),
        help: 'Stops tracking pixels from telling senders when and where you read their email. '
            'Use "Load images" in a message to show them once.',
      ),
      const SizedBox(height: 18),
      _Group('AI', [
        Text(
          cloud
              ? 'Some AI jobs use a cloud model you chose (AI tab). The emails involved in those jobs are sent to that provider.'
              : 'All AI runs on this Mac. Your mail never leaves it.',
          style: TextStyle(fontSize: 13, color: c.label),
        ),
      ]),
    ]);
  }
}

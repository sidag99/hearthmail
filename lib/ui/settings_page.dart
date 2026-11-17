import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/account_config.dart';
import '../services/ai/email_ai.dart';
import '../services/settings_store.dart';
import '../state/app_state.dart';
import 'account_setup_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final AppState _state = context.read<AppState>();
  late final _url = TextEditingController(text: _state.settings.ollamaUrl);
  late final _name = TextEditingController(text: _state.settings.userName);
  late final _style = TextEditingController(text: _state.settings.styleNotes);
  late final _gId = TextEditingController(text: _state.settings.googleClientId);
  late final _gSecret = TextEditingController(text: _state.settings.googleClientSecret);
  late final _msId = TextEditingController(text: _state.settings.microsoftClientId);
  late final _signatures = {
    for (final s in _state.sessions) s.id: TextEditingController(text: _state.userData.signatures[s.id] ?? ''),
  };
  bool _checking = false;

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    _style.dispose();
    _gId.dispose();
    _gSecret.dispose();
    _msId.dispose();
    for (final c in _signatures.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save(AppSettings s) => _state.updateSettings(s);

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = state.settings;
    final theme = Theme.of(context);
    final models = state.availableModels.where(AppState.isChatModel).toList();
    final embedders = state.availableModels.where(AppState.isEmbeddingModel).toList();
    final translators = state.availableModels.where((m) => m.contains('translategemma')).toList();

    Widget section(String title, List<Widget> children) => Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            ...children,
          ]),
        );

    Widget modelPicker(String label, String help, String value, void Function(String) onChanged) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: DropdownButtonFormField<String>(
            initialValue: models.contains(value) ? value : null,
            decoration: InputDecoration(labelText: label, helperText: help),
            items: [for (final m in models) DropdownMenuItem(value: m, child: Text(m))],
            onChanged: models.isEmpty ? null : (v) => v == null ? null : onChanged(v),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(padding: const EdgeInsets.all(24), children: [
            section('Local AI', [
              Row(children: [
                Icon(
                  state.aiReady ? Icons.check_circle : Icons.error_outline,
                  size: 18,
                  color: state.aiReady ? const Color(0xFF30A46C) : theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(state.aiReady
                      ? 'Connected to Ollama — ${models.length} model${models.length == 1 ? '' : 's'} available. Nothing leaves this computer.'
                      : (state.aiError ?? 'Not connected')),
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _url,
                    decoration: const InputDecoration(
                      labelText: 'Ollama address',
                      helperText: 'Use another computer\'s address to use its AI (e.g. your Mac from a phone).',
                    ),
                    onSubmitted: (v) => _save(s.copyWith(ollamaUrl: v.trim())),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _checking
                      ? null
                      : () async {
                          setState(() => _checking = true);
                          if (_url.text.trim() != s.ollamaUrl) {
                            await _save(s.copyWith(ollamaUrl: _url.text.trim()));
                          } else {
                            await state.refreshAi();
                          }
                          if (mounted) setState(() => _checking = false);
                        },
                  child: Text(_checking ? 'Checking…' : 'Reconnect'),
                ),
              ]),
              const SizedBox(height: 16),
              modelPicker('Fast model', 'Sorting, search, summaries and quick replies.', s.fastModel,
                  (v) => _save(s.copyWith(fastModel: v))),
              modelPicker('Writing model', 'Drafts, rewrites and inbox digests. Using the same model as above saves memory.',
                  s.writingModel, (v) => _save(s.copyWith(writingModel: v))),
            ]),
            section('Search', [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Search by meaning (semantic search)'),
                subtitle: Text(state.embeddingModel.isEmpty
                    ? (embedders.isEmpty
                        ? 'Needs an embedding model. Run: ollama pull embeddinggemma:300m'
                        : 'Off')
                    : '${state.indexedCount} emails indexed on this computer'
                        '${state.indexing ? ' · indexing…' : ''}. Finds emails even when they use different words.'),
                value: s.semanticSearch,
                onChanged: (v) => _save(s.copyWith(semanticSearch: v)),
              ),
              if (embedders.isNotEmpty && s.semanticSearch) ...[
                DropdownButtonFormField<String>(
                  initialValue: embedders.contains(state.embeddingModel) ? state.embeddingModel : null,
                  decoration: const InputDecoration(
                      labelText: 'Embedding model', helperText: 'embeddinggemma:300m tested best for email search.'),
                  items: [for (final m in embedders) DropdownMenuItem(value: m, child: Text(m))],
                  onChanged: (v) => v == null ? null : _save(s.copyWith(embeddingModel: v)),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<int>(
                  initialValue: [1000, 3000, 10000, 20000].contains(s.indexDepth) ? s.indexDepth : 3000,
                  decoration: const InputDecoration(labelText: 'Emails to index per account'),
                  items: const [
                    DropdownMenuItem(value: 1000, child: Text('Latest 1,000')),
                    DropdownMenuItem(value: 3000, child: Text('Latest 3,000')),
                    DropdownMenuItem(value: 10000, child: Text('Latest 10,000')),
                    DropdownMenuItem(value: 20000, child: Text('Latest 20,000 (uses more disk and download)')),
                  ],
                  onChanged: (v) async {
                    if (v == null) return;
                    await _save(s.copyWith(indexDepth: v));
                    await state.indexAll();
                  },
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: state.indexing ? null : state.rebuildIndex,
                    child: const Text('Rebuild index'),
                  ),
                ),
              ],
            ]),
            section('Translation', [
              DropdownButtonFormField<String>(
                initialValue: Languages.common.contains(s.myLanguage) ? s.myLanguage : 'English',
                decoration: const InputDecoration(
                    labelText: 'My language', helperText: 'Emails in other languages offer a Translate button.'),
                items: [for (final l in Languages.common) DropdownMenuItem(value: l, child: Text(l))],
                onChanged: (v) => v == null ? null : _save(s.copyWith(myLanguage: v)),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: s.translationModel.isEmpty ? 'auto' : (translators.contains(s.translationModel) || models.contains(s.translationModel) ? s.translationModel : 'auto'),
                decoration: InputDecoration(
                  labelText: 'Translation model (for reading)',
                  helperText: translators.isEmpty
                      ? 'Tip: ollama pull translategemma:4b translates more faithfully.'
                      : 'Writing in another language always uses the writing model.',
                ),
                items: [
                  DropdownMenuItem(
                      value: 'auto',
                      child: Text(translators.isEmpty ? 'Same as writing model' : 'Automatic (${translators.first})')),
                  for (final m in [...translators, ...models]) DropdownMenuItem(value: m, child: Text(m)),
                ],
                onChanged: (v) => v == null ? null : _save(s.copyWith(translationModel: v)),
              ),
            ]),
            section('Sending', [
              DropdownButtonFormField<int>(
                initialValue: [0, 5, 10, 20, 30].contains(s.undoSendSeconds) ? s.undoSendSeconds : 10,
                decoration: const InputDecoration(labelText: 'Undo send', helperText: 'Time to change your mind after clicking Send.'),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('Off')),
                  DropdownMenuItem(value: 5, child: Text('5 seconds')),
                  DropdownMenuItem(value: 10, child: Text('10 seconds')),
                  DropdownMenuItem(value: 20, child: Text('20 seconds')),
                  DropdownMenuItem(value: 30, child: Text('30 seconds')),
                ],
                onChanged: (v) => v == null ? null : _save(s.copyWith(undoSendSeconds: v)),
              ),
              const SizedBox(height: 12),
              for (final sess in state.sessions)
                if (_signatures[sess.id] case final c?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: TextField(
                      controller: c,
                      minLines: 2,
                      maxLines: 5,
                      decoration: InputDecoration(
                        labelText: 'Signature for ${sess.config.email}',
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (v) {
                        state.userData.signatures[sess.id] = v;
                        state.userData.save();
                      },
                    ),
                  ),
            ]),
            section('People', [
              Text('VIPs', style: theme.textTheme.labelLarge),
              if (state.userData.vips.isEmpty)
                Text('Star a sender in an email to make them a VIP. VIP mail always counts as Priority.',
                    style: theme.textTheme.bodySmall),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final v in state.userData.vips) InputChip(label: Text(v), onDeleted: () => state.toggleVip(v)),
              ]),
              const SizedBox(height: 12),
              Text('Blocked senders', style: theme.textTheme.labelLarge),
              if (state.userData.blocked.isEmpty)
                Text('Nobody is blocked. Use "Block" in an email\'s ⋯ menu.', style: theme.textTheme.bodySmall),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final b in state.userData.blocked) InputChip(label: Text(b), onDeleted: () => state.unblock(b)),
              ]),
            ]),
            section('Writing', [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Your name', helperText: 'Used to sign AI-written emails.'),
                onChanged: (v) => _save(s.copyWith(userName: v.trim())),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _style,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Your writing style (optional)',
                  helperText: 'e.g. "Short and friendly. I sign off with Cheers. No exclamation marks."',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => _save(s.copyWith(styleNotes: v)),
              ),
            ]),
            section('Inbox', [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Sort my inbox automatically with AI'),
                subtitle: const Text('Adds Priority, Needs reply and category views.'),
                value: s.autoSort,
                onChanged: (v) => _save(s.copyWith(autoSort: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Load remote images automatically'),
                subtitle: const Text('Off blocks tracking pixels until you click "Load images".'),
                value: s.loadRemoteImages,
                onChanged: (v) => _save(s.copyWith(loadRemoteImages: v)),
              ),
            ]),
            section('Sign-in apps', [
              Text(
                'Your own free app registrations for "Sign in with Google / Microsoft". '
                'See OAUTH_SETUP.md for step-by-step instructions.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _gId,
                decoration: const InputDecoration(labelText: 'Google client ID'),
                onChanged: (v) => _save(state.settings.copyWith(googleClientId: v.trim())),
              ),
              TextField(
                controller: _gSecret,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Google client secret'),
                onChanged: (v) => _save(state.settings.copyWith(googleClientSecret: v.trim())),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _msId,
                decoration: const InputDecoration(labelText: 'Microsoft application (client) ID'),
                onChanged: (v) => _save(state.settings.copyWith(microsoftClientId: v.trim())),
              ),
            ]),
            section('Accounts', [
              for (final sess in state.sessions)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    switch (sess.status) {
                      ConnectionStatus.connected => Icons.check_circle,
                      ConnectionStatus.failed => Icons.error_outline,
                      _ => Icons.sync,
                    },
                    color: switch (sess.status) {
                      ConnectionStatus.connected => const Color(0xFF30A46C),
                      ConnectionStatus.failed => theme.colorScheme.error,
                      _ => null,
                    },
                  ),
                  title: Text(sess.config.email),
                  subtitle: Text(sess.status == ConnectionStatus.failed
                      ? (sess.error ?? 'Not connected')
                      : '${switch (sess.config.authType) {
                          AuthType.google => 'Signed in with Google',
                          AuthType.microsoft => 'Signed in with Microsoft',
                          AuthType.password => 'App password',
                        }} · ${sess.config.imapHost}'),
                  trailing: TextButton(
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: Text('Remove ${sess.config.email}?'),
                          content: const Text(
                              'This removes the account and its saved password from this app. Your email stays on the server.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
                          ],
                        ),
                      );
                      if (ok == true) await state.removeAccount(sess.config);
                    },
                    child: const Text('Remove'),
                  ),
                ),
              OutlinedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add account'),
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => const AccountSetupPage())),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

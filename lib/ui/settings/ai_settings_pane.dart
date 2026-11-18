import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../services/ai/ai_provider.dart';
import '../../services/ai/claude_cli_provider.dart';
import '../../services/ai/codex_cli_provider.dart';
import '../../services/ai/engines.dart';
import '../../services/settings_store.dart';
import '../../state/ai_engines.dart';
import '../../state/app_state.dart';

/// All AI settings in one scrollable-friendly column: local Ollama, which
/// engine runs which job, and the cloud / CLI engines. Reads [AppState] from
/// Provider. Embed it inside any page (it does not scroll by itself).
/// An Ollama address on another computer reached without encryption.
bool _plainRemote(String url) {
  final u = Uri.tryParse(url);
  if (u == null || u.scheme != 'http') return false;
  return !const {'localhost', '127.0.0.1', '::1', '[::1]'}.contains(u.host.toLowerCase());
}

class AiSettingsPane extends StatefulWidget {
  const AiSettingsPane({super.key});

  @override
  State<AiSettingsPane> createState() => _AiSettingsPaneState();
}

class _AiSettingsPaneState extends State<AiSettingsPane> {
  late final TextEditingController _url;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: context.read<AppState>().settings.ollamaUrl);
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Widget _section(BuildContext context, String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          ...children,
        ]),
      );

  Widget _dropdown({
    required String label,
    String? help,
    required String value,
    required List<String> options,
    String Function(String)? text,
    required void Function(String) onChanged,
  }) {
    final items = {...options, if (value.isNotEmpty) value}.toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        key: ValueKey('$label|$value|${items.length}'),
        initialValue: items.contains(value) ? value : null,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, helperText: help),
        items: [
          for (final m in items) DropdownMenuItem(value: m, child: Text(text?.call(m) ?? m, overflow: TextOverflow.ellipsis))
        ],
        onChanged: items.isEmpty ? null : (v) => v == null ? null : onChanged(v),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = state.settings;
    final theme = Theme.of(context);
    Future<void> save(AppSettings n) => state.updateSettings(n);
    final chat = state.availableModels.where(AppState.isChatModel).toList();
    final translators = state.availableModels.where((m) => m.contains('translategemma')).toList();
    final embedders = state.availableModels.where(AppState.isEmbeddingModel).toList();
    final anyCloud = AiEngine.isCloud(s.writingEngine) || AiEngine.isCloud(s.assistEngine);

    String engineText(String e) =>
        AiEngine.label(e) + (state.engines.configured(e) ? '' : ' (not set up)');

    Widget engineBlock({
      required String title,
      required String help,
      required String engine,
      required String model,
      required bool writing,
    }) {
      void set(String? e, String? m) => save(writing
          ? s.copyWith(writingEngine: e, writingCloudModel: m)
          : s.copyWith(assistEngine: e, assistCloudModel: m));
      final problem = AiEngine.isCloud(engine) ? state.engines.problem(engine) : null;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _dropdown(
          label: title,
          help: help,
          value: engine,
          // Codex only writes (it can't be fully stripped of tools, and
          // background jobs read every incoming email unattended).
          options: writing ? AiEngine.all : [for (final e in AiEngine.all) if (e != AiEngine.codexCli) e],
          text: engineText,
          onChanged: (e) => set(e, ''),
        ),
        if (AiEngine.isCloud(engine) && engine != AiEngine.codexCli)
          _dropdown(
            label: '$title model',
            value: model,
            options: ['', ...state.engines.modelsFor(engine)],
            text: (m) => m.isEmpty ? 'Default (${EngineHub.defaultModel(engine, writing: writing)})' : m,
            onChanged: (m) => set(null, m),
          ),
        if (problem != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text('$problem Local AI is used until then.',
                style: TextStyle(color: theme.colorScheme.error)),
          ),
      ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _section(context, 'Where AI runs', [
        engineBlock(
          title: 'Writing',
          help: 'Drafts, rewrites, subject lines, digests and translation of what you send.',
          engine: s.writingEngine,
          model: s.writingCloudModel,
          writing: true,
        ),
        engineBlock(
          title: 'Everything else',
          help: 'Summaries, quick replies, search, answers, event detection and sorting.',
          engine: s.assistEngine,
          model: s.assistCloudModel,
          writing: false,
        ),
        Text(
          anyCloud
              ? 'Privacy: while a cloud engine is selected, the text of the emails used for that job is sent to '
                  'Anthropic or OpenAI (through their API, or through the Claude Code / Codex app signed in on this Mac). '
                  'Jobs set to Local never leave this computer. Search indexing and reading translation always stay local.'
              : 'Everything runs locally with Ollama; nothing leaves this computer. Choosing a cloud engine sends the '
                  'email text for that job to Anthropic or OpenAI. Search indexing and reading translation always stay local.',
          style: theme.textTheme.bodySmall,
        ),
        if (state.engineError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(state.engineError!, style: TextStyle(color: theme.colorScheme.error)),
          ),
      ]),
      _section(context, 'Local AI (Ollama)', [
        Row(children: [
          Icon(
            state.availableModels.isNotEmpty ? Icons.check_circle : Icons.error_outline,
            size: 18,
            color: state.availableModels.isNotEmpty ? const Color(0xFF30A46C) : theme.colorScheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(state.availableModels.isNotEmpty
                ? 'Connected to Ollama — ${chat.length} chat model${chat.length == 1 ? '' : 's'} available. Nothing leaves this computer.'
                : (state.aiError ?? 'Not connected')),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _url,
              decoration: InputDecoration(
                labelText: 'Ollama address',
                helperText: _plainRemote(s.ollamaUrl)
                    ? 'Warning: emails are sent to this computer unencrypted. Use https or a trusted network only.'
                    : 'Use another computer\'s address to use its AI.',
                helperMaxLines: 2,
              ),
              onSubmitted: (v) => save(s.copyWith(ollamaUrl: v.trim())),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: _checking
                ? null
                : () async {
                    setState(() => _checking = true);
                    if (_url.text.trim() != s.ollamaUrl) {
                      await save(s.copyWith(ollamaUrl: _url.text.trim()));
                    } else {
                      await state.refreshAi();
                    }
                    if (mounted) setState(() => _checking = false);
                  },
            child: Text(_checking ? 'Checking…' : 'Reconnect'),
          ),
        ]),
        const SizedBox(height: 16),
        _dropdown(
          label: 'Fast model',
          help: 'Sorting, search, summaries and quick replies.',
          value: chat.contains(s.fastModel) ? s.fastModel : '',
          options: chat,
          onChanged: (v) => save(s.copyWith(fastModel: v)),
        ),
        _dropdown(
          label: 'Writing model',
          help: 'Drafts, rewrites and digests. Also the fallback when a cloud engine fails.',
          value: chat.contains(s.writingModel) ? s.writingModel : '',
          options: chat,
          onChanged: (v) => save(s.copyWith(writingModel: v)),
        ),
        if (embedders.isNotEmpty)
          _dropdown(
            label: 'Embedding model',
            help: 'For search by meaning. Always local.',
            value: embedders.contains(state.embeddingModel) ? state.embeddingModel : '',
            options: embedders,
            onChanged: (v) => save(s.copyWith(embeddingModel: v)),
          ),
        _dropdown(
          label: 'Translation model',
          help: 'For translating emails you read. Always local.',
          value: s.translationModel.isEmpty ? 'auto' : s.translationModel,
          options: ['auto', ...translators],
          text: (m) => m == 'auto' ? 'Automatic (translategemma if installed, else writing model)' : m,
          onChanged: (v) => save(s.copyWith(translationModel: v)),
        ),
      ]),
      _section(context, 'Claude API', [
        _ApiKeyBox(
          engine: AiEngine.claudeApi,
          keyName: AiEngine.anthropicKey,
          hint: 'sk-ant-…',
          help: 'Create a key at console.anthropic.com. It is stored in your Mac Keychain. API usage is billed by Anthropic.',
        ),
      ]),
      _section(context, 'OpenAI API', [
        _ApiKeyBox(
          engine: AiEngine.openaiApi,
          keyName: AiEngine.openaiKey,
          hint: 'sk-…',
          help: 'Create a key at platform.openai.com. It is stored in your Mac Keychain. API usage is billed by OpenAI.',
        ),
      ]),
      _section(context, 'Claude Code and Codex (your subscriptions)', [
        _CliBox(
          engine: AiEngine.claudeCli,
          installHint: ClaudeCliProvider.installHint,
          signIn: 'Sign in by running `claude` once in Terminal. Uses your Claude subscription; no API key needed.',
        ),
        const SizedBox(height: 12),
        _CliBox(
          engine: AiEngine.codexCli,
          installHint: CodexCliProvider.installHint,
          signIn: 'Sign in by running `codex login` in Terminal. Uses your ChatGPT subscription. '
              'Codex returns each reply in one piece, so text appears all at once.',
        ),
      ]),
    ]);
  }
}

class _ApiKeyBox extends StatefulWidget {
  const _ApiKeyBox({required this.engine, required this.keyName, required this.hint, required this.help});
  final String engine;
  final String keyName;
  final String hint;
  final String help;

  @override
  State<_ApiKeyBox> createState() => _ApiKeyBoxState();
}

class _ApiKeyBoxState extends State<_ApiKeyBox> {
  final _key = TextEditingController();
  String? _result;
  bool _ok = false;
  bool _busy = false;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String?> Function() job, {String okText = 'Works.'}) async {
    setState(() {
      _busy = true;
      _result = null;
    });
    final err = await job();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _ok = err == null;
      _result = err ?? okText;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final has = state.engines.hasKey(widget.keyName);
    final isWriting = state.settings.writingEngine == widget.engine;
    final model = isWriting
        ? state.settings.writingCloudModel
        : (state.settings.assistEngine == widget.engine ? state.settings.assistCloudModel : '');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: TextField(
            controller: _key,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: has ? 'API key (saved — paste to replace)' : 'API key',
              hintText: widget.hint,
              helperText: widget.help,
              helperMaxLines: 3,
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _busy
              ? null
              : () async {
                  final v = _key.text.trim();
                  if (v.isEmpty) return;
                  _key.clear();
                  await state.setApiKey(widget.keyName, v);
                  await _run(() async {
                    try {
                      await state.refreshEngineModels(widget.engine);
                      return null;
                    } on AiException catch (e) {
                      return e.message;
                    }
                  }, okText: 'Key saved and accepted.');
                },
          child: const Text('Save'),
        ),
        if (has) ...[
          const SizedBox(width: 8),
          TextButton(onPressed: () => state.setApiKey(widget.keyName, null), child: const Text('Remove')),
        ],
      ]),
      if (has)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(children: [
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _run(() => state.engines.test(
                      widget.engine, model.isEmpty ? EngineHub.defaultModel(widget.engine, writing: false) : model)),
              child: Text(_busy ? 'Testing…' : 'Test'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        try {
                          await state.refreshEngineModels(widget.engine);
                          return null;
                        } on AiException catch (e) {
                          return e.message;
                        }
                      }, okText: 'Model list updated.'),
              child: const Text('Refresh models'),
            ),
            const SizedBox(width: 8),
            if (_result != null)
              Expanded(
                child: Text(_result!,
                    style: TextStyle(color: _ok ? const Color(0xFF30A46C) : theme.colorScheme.error)),
              ),
          ]),
        ),
    ]);
  }
}

class _CliBox extends StatefulWidget {
  const _CliBox({required this.engine, required this.installHint, required this.signIn});
  final String engine;
  final String installHint;
  final String signIn;

  @override
  State<_CliBox> createState() => _CliBoxState();
}

class _CliBoxState extends State<_CliBox> {
  String? _result;
  bool _ok = false;
  bool _busy = false;
  TextEditingController? _modelText;

  @override
  void dispose() {
    _modelText?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final s = state.settings;
    final installed = state.engines.isInstalled(widget.engine);
    final isCodex = widget.engine == AiEngine.codexCli;
    final writingModel = s.writingEngine == widget.engine ? s.writingCloudModel : null;
    final assistModel = s.assistEngine == widget.engine ? s.assistCloudModel : null;
    final model = writingModel ?? assistModel ?? '';

    void setModel(String m) {
      var n = s;
      if (s.writingEngine == widget.engine) n = n.copyWith(writingCloudModel: m);
      if (s.assistEngine == widget.engine) n = n.copyWith(assistCloudModel: m);
      state.updateSettings(n);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(installed ? Icons.check_circle : Icons.error_outline,
            size: 18, color: installed ? const Color(0xFF30A46C) : theme.colorScheme.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text('${AiEngine.label(widget.engine)}: ${installed ? 'found on this Mac' : 'not found. ${widget.installHint}'}',
              style: theme.textTheme.bodyMedium),
        ),
        TextButton(onPressed: state.recheckClis, child: const Text('Check again')),
      ]),
      Text(widget.signIn, style: theme.textTheme.bodySmall),
      if (installed) ...[
        const SizedBox(height: 8),
        if (isCodex)
          Builder(builder: (context) {
            _modelText ??= TextEditingController(text: model);
            return TextField(
              controller: _modelText,
              decoration: const InputDecoration(
                labelText: 'Model (optional)',
                helperText: 'Leave empty to use Codex\'s default model.',
              ),
              onSubmitted: setModel,
            );
          })
        else
          DropdownButtonFormField<String>(
            key: ValueKey('${widget.engine}|$model'),
            initialValue: model,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Model (used when this engine is selected above)'),
            items: [
              const DropdownMenuItem(value: '', child: Text('Default')),
              for (final m in {...ClaudeCliProvider.knownModels, if (model.isNotEmpty) model})
                DropdownMenuItem(value: m, child: Text(m)),
            ],
            onChanged: (v) => v == null ? null : setModel(v),
          ),
        const SizedBox(height: 8),
        Row(children: [
          OutlinedButton(
            onPressed: _busy
                ? null
                : () async {
                    setState(() {
                      _busy = true;
                      _result = null;
                    });
                    final err = await state.engines.test(widget.engine, model);
                    if (!mounted) return;
                    setState(() {
                      _busy = false;
                      _ok = err == null;
                      _result = err ?? 'Works.';
                    });
                  },
            child: Text(_busy ? 'Testing…' : 'Test'),
          ),
          const SizedBox(width: 8),
          if (_result != null)
            Expanded(
              child: Text(_result!,
                  style: TextStyle(color: _ok ? const Color(0xFF30A46C) : theme.colorScheme.error)),
            ),
        ]),
      ],
    ]);
  }
}

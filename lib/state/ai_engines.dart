import '../services/ai/ai_provider.dart';
import '../services/ai/anthropic_provider.dart';
import '../services/ai/claude_cli_provider.dart';
import '../services/ai/cli_locator.dart';
import '../services/ai/codex_cli_provider.dart';
import '../services/ai/engines.dart';
import '../services/ai/openai_provider.dart';
import '../services/settings_store.dart';

/// Keys, install status, model lists and provider instances for the cloud
/// and CLI engines. Local Ollama stays in AppState.
class EngineHub {
  EngineHub(this._store);

  final SettingsStore _store;
  final Map<String, String> _keys = {};
  final Map<String, bool> _installed = {};
  final Map<String, List<String>> models = {};
  final Map<String, AiProvider> _providers = {};

  Future<void> load() async {
    for (final k in [AiEngine.anthropicKey, AiEngine.openaiKey]) {
      try {
        final v = await _store.readSecret(k);
        if (v != null && v.trim().isNotEmpty) _keys[k] = v.trim();
      } catch (_) {}
    }
    await refreshInstalled();
  }

  Future<void> refreshInstalled() async {
    _installed[AiEngine.claudeCli] = await CliLocator.find('claude', refresh: true) != null;
    _installed[AiEngine.codexCli] = await CliLocator.find('codex', refresh: true) != null;
  }

  static String? keyNameFor(String engine) => switch (engine) {
        AiEngine.claudeApi => AiEngine.anthropicKey,
        AiEngine.openaiApi => AiEngine.openaiKey,
        _ => null,
      };

  bool hasKey(String keyName) => (_keys[keyName] ?? '').isNotEmpty;

  Future<void> setKey(String keyName, String? value) async {
    final v = (value ?? '').trim();
    if (v.isEmpty) {
      _keys.remove(keyName);
      await _store.deleteSecret(keyName);
    } else {
      _keys[keyName] = v;
      await _store.writeSecret(keyName, v);
    }
    final engine = keyName == AiEngine.anthropicKey ? AiEngine.claudeApi : AiEngine.openaiApi;
    _providers.remove(engine)?.close();
    models.remove(engine);
  }

  bool isInstalled(String engine) => _installed[engine] ?? false;

  /// Whether [engine] can run right now.
  bool configured(String engine) => switch (engine) {
        AiEngine.local => true,
        AiEngine.claudeApi => hasKey(AiEngine.anthropicKey),
        AiEngine.openaiApi => hasKey(AiEngine.openaiKey),
        AiEngine.claudeCli || AiEngine.codexCli => isInstalled(engine),
        _ => false,
      };

  /// Why [engine] cannot run, for display. Null when it can.
  String? problem(String engine) {
    if (configured(engine)) return null;
    return switch (engine) {
      AiEngine.claudeApi => 'Add your Claude API key in Settings.',
      AiEngine.openaiApi => 'Add your OpenAI API key in Settings.',
      AiEngine.claudeCli => ClaudeCliProvider.installHint,
      AiEngine.codexCli => CodexCliProvider.installHint,
      _ => null,
    };
  }

  AiProvider? provider(String engine) {
    if (!configured(engine) || engine == AiEngine.local) return null;
    return _providers[engine] ??= switch (engine) {
      AiEngine.claudeApi => AnthropicProvider(apiKey: _keys[AiEngine.anthropicKey]!),
      AiEngine.openaiApi => OpenAiProvider(apiKey: _keys[AiEngine.openaiKey]!),
      AiEngine.claudeCli => ClaudeCliProvider(),
      _ => CodexCliProvider(),
    };
  }

  /// Model used when the user has not picked one.
  static String defaultModel(String engine, {required bool writing}) => switch (engine) {
        AiEngine.claudeApi => writing ? AnthropicProvider.writingModel : AnthropicProvider.fastModel,
        AiEngine.openaiApi => OpenAiProvider.defaultModel,
        AiEngine.claudeCli => writing ? 'sonnet' : 'haiku',
        _ => '',
      };

  /// Model ids to offer for [engine]; falls back to defaults until loaded.
  List<String> modelsFor(String engine) {
    final loaded = models[engine];
    if (loaded != null && loaded.isNotEmpty) return loaded;
    return switch (engine) {
      AiEngine.claudeApi => [AnthropicProvider.writingModel, AnthropicProvider.fastModel],
      AiEngine.openaiApi => [OpenAiProvider.defaultModel],
      AiEngine.claudeCli => ClaudeCliProvider.knownModels,
      _ => const [],
    };
  }

  /// Fetches the model list from the service (throws [AiException]).
  Future<List<String>> refreshModels(String engine) async {
    final p = provider(engine);
    if (p == null) throw AiAuthException(problem(engine) ?? 'Not available.');
    final list = await p.listModels();
    models[engine] = list;
    return list;
  }

  /// A tiny round trip to prove the engine works. Returns null on success,
  /// otherwise a message for the user. Sends no email content.
  Future<String?> test(String engine, String model) async {
    final p = provider(engine);
    if (p == null) return problem(engine);
    try {
      final r = await p.complete(const [AiMessage.user('Reply with the single word OK.')],
          model: model.isEmpty ? defaultModel(engine, writing: false) : model, temperature: 0);
      return r.isEmpty ? 'The engine returned an empty reply.' : null;
    } on AiException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  void close() {
    for (final p in _providers.values) {
      p.close();
    }
    _providers.clear();
  }

  // ---------------------------------------------------------------- labels

  /// "claude-sonnet-5-5" -> "Claude Sonnet 5.5".
  static String prettyClaude(String id) {
    final parts = id.replaceFirst(RegExp(r'^claude-'), '').split('-');
    final words = <String>[];
    var nums = <String>[];
    void flush() {
      if (nums.isNotEmpty) words.add(nums.join('.'));
      nums = [];
    }

    for (final p in parts) {
      if (RegExp(r'^\d{8}$').hasMatch(p) || p == 'latest') continue;
      if (RegExp(r'^\d+$').hasMatch(p)) {
        nums.add(p);
      } else {
        flush();
        words.add(p.isEmpty ? p : p[0].toUpperCase() + p.substring(1));
      }
    }
    flush();
    return 'Claude ${words.join(' ')}';
  }

  static String label(String engine, String model) => switch (engine) {
        AiEngine.local => model.isEmpty ? 'Local AI' : '$model · Local',
        AiEngine.claudeApi => '${prettyClaude(model)} · API',
        AiEngine.openaiApi => '$model · OpenAI API',
        AiEngine.claudeCli => 'Claude Code',
        AiEngine.codexCli => 'Codex',
        _ => model,
      };
}

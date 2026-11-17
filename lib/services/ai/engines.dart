/// Where an AI job runs. Stored in settings as these exact strings.
class AiEngine {
  static const local = 'local';
  static const claudeApi = 'claudeApi';
  static const openaiApi = 'openaiApi';
  static const claudeCli = 'claudeCli';
  static const codexCli = 'codexCli';

  static const all = [local, claudeApi, openaiApi, claudeCli, codexCli];

  static bool isCloud(String engine) => engine != local;

  static String label(String engine) => switch (engine) {
        claudeApi => 'Claude API',
        openaiApi => 'OpenAI API',
        claudeCli => 'Claude Code',
        codexCli => 'Codex',
        _ => 'Local (Ollama)',
      };

  /// Keychain keys.
  static const anthropicKey = 'anthropic.apiKey';
  static const openaiKey = 'openai.apiKey';
}

/// One selectable way to run writing jobs: an engine plus a model.
/// An empty [model] means the engine's default (CLIs).
class WritingChoice {
  const WritingChoice(this.engine, this.model, this.label);

  final String engine;
  final String model;

  /// Short, e.g. "Claude Sonnet 5.5 · API", "gemma4:12b · Local", "Claude Code".
  final String label;

  bool get isCloud => AiEngine.isCloud(engine);

  @override
  bool operator ==(Object other) =>
      other is WritingChoice && other.engine == engine && other.model == model;

  @override
  int get hashCode => Object.hash(engine, model);

  @override
  String toString() => label;
}

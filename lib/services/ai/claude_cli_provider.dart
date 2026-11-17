import 'dart:convert';

import 'ai_provider.dart';
import 'cli_locator.dart';

/// Runs the user's installed Claude Code CLI headless (`claude -p`), using
/// their Claude subscription. No tools, single turn, nothing persisted.
class ClaudeCliProvider extends AiProvider {
  /// [executable] overrides discovery (used by tests).
  ClaudeCliProvider({this.executable});

  final String? executable;

  static const installHint =
      'Install Claude Code and run `claude` once to sign in.';

  /// Aliases the CLI accepts, plus full ids. Empty model = CLI default.
  static const knownModels = ['sonnet', 'opus', 'haiku', 'claude-sonnet-5-5', 'claude-haiku-5-5'];

  @override
  String get name => 'Claude Code';

  Future<String?> _path() async => executable ?? await CliLocator.find('claude');

  Future<bool> get isInstalled async => await _path() != null;

  @override
  Future<List<String>> listModels() async => knownModels;

  @override
  Stream<String> chat(
    List<AiMessage> messages, {
    required String model,
    double temperature = 0.4,
    Map<String, dynamic>? jsonSchema,
  }) async* {
    final exe = await _path();
    if (exe == null) throw AiAuthException(installHint);
    final args = [
      '-p',
      '--output-format', 'stream-json',
      '--verbose',
      '--include-partial-messages',
      '--tools', '',
      '--no-session-persistence',
      '--setting-sources', '',
      '--disable-slash-commands',
      '--strict-mcp-config',
      // Constant text only: the real prompt goes over stdin, never argv.
      '--system-prompt',
      'You are a text engine inside an email app. Follow the instructions in the input exactly and output only what is asked.',
      if (model.isNotEmpty) ...['--model', model],
    ];
    var gotText = false;
    String? resultText;
    String? errorText;
    await for (final line in runCliLines(
      executable: exe,
      args: args,
      stdin: foldMessages(messages, jsonSchema: jsonSchema),
      onFailure: (stderr, code) => _failure(errorText ?? stderr, code),
    )) {
      if (line.trim().isEmpty) continue;
      final Map<String, dynamic> obj;
      try {
        obj = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      switch (obj['type']) {
        case 'stream_event':
          final ev = obj['event'] as Map<String, dynamic>? ?? const {};
          if (ev['type'] == 'content_block_delta') {
            final d = ev['delta'] as Map<String, dynamic>? ?? const {};
            if (d['type'] == 'text_delta' && (d['text'] as String?)?.isNotEmpty == true) {
              gotText = true;
              yield d['text'] as String;
            }
          }
        case 'result':
          if (obj['is_error'] == true) {
            errorText = '${obj['result'] ?? obj['subtype'] ?? ''}';
            throw _failure(errorText, 1);
          }
          resultText = obj['result'] as String?;
      }
    }
    if (!gotText && resultText != null && resultText.isNotEmpty) yield resultText;
  }

  static AiException _failure(String text, int code) {
    if (looksLikeLimit(text)) {
      return AiLimitException('Claude Code usage limit reached. Try again later or pick another engine.');
    }
    if (looksLikeAuth(text)) {
      return AiAuthException('Claude Code is not signed in. Run `claude` in Terminal once and sign in.');
    }
    final first = text.trim().split('\n').first;
    return AiException('Claude Code failed${first.isEmpty ? ' (exit $code)' : ': $first'}');
  }
}

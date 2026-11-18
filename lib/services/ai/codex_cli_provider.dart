import 'dart:convert';
import 'dart:io';

import 'ai_provider.dart';
import 'cli_locator.dart';

/// Runs the user's installed Codex CLI non-interactively (`codex exec`) in a
/// read-only sandbox, using their ChatGPT sign-in. Codex emits whole messages
/// (not token deltas), so replies arrive in one piece.
class CodexCliProvider extends AiProvider {
  CodexCliProvider({this.executable});

  final String? executable;

  static const installHint =
      'Install Codex (npm i -g @openai/codex or brew install codex) and run `codex login`.';

  @override
  String get name => 'Codex';

  Future<String?> _path() async => executable ?? await CliLocator.find('codex');

  /// Codex features that give the model tools (shell, browser, apps…).
  /// Email text reaches Codex, so all of them are switched off.
  static const _toolFeatures = [
    'shell_tool', 'unified_exec', 'apps', 'browser_use', 'browser_use_external', 'browser_use_full_cdp_access',
    'computer_use', 'in_app_browser', 'plugins', 'remote_plugin', 'image_generation', 'multi_agent', 'view_image',
    'hooks', 'tool_suggest', 'skill_mcp_dependency_install', 'in_app_local_automation', 'workspace_dependencies',
    'goals', 'sleep_tool',
  ];

  static List<String>? _disableArgs;

  /// `--disable` flags for the tool features this Codex version has
  /// (it refuses unknown names, so ask it which exist).
  static Future<List<String>> _toolsOff(String exe, String home) async {
    final cached = _disableArgs;
    if (cached != null) return cached;
    final known = <String>{};
    try {
      final r = await Process.run(exe, ['features', 'list'],
          includeParentEnvironment: false,
          environment: {'PATH': [...CliLocator.candidateDirs(), '/usr/bin:/bin'].join(':'), 'HOME': home});
      for (final line in (r.stdout as String).split('\n')) {
        final name = line.trim().split(RegExp(r'\s+')).first;
        if (name.isNotEmpty) known.add(name);
      }
    } catch (_) {}
    return _disableArgs = [
      for (final f in _toolFeatures)
        if (known.contains(f)) ...['--disable', f],
    ];
  }

  Future<bool> get isInstalled async => await _path() != null;

  /// Codex has no model listing; empty model means Codex's own default.
  @override
  Future<List<String>> listModels() async => const [];

  @override
  Stream<String> chat(
    List<AiMessage> messages, {
    required String model,
    double temperature = 0.4,
    Map<String, dynamic>? jsonSchema,
  }) async* {
    final exe = await _path();
    if (exe == null) throw AiAuthException(installHint);
    final home = Platform.environment['HOME'] ?? '';
    final codexHome = Platform.environment['CODEX_HOME'] ?? '$home/.codex';
    final args = [
      ...await _toolsOff(exe, home),
      '-c', 'web_search="disabled"',
      'exec',
      '--json',
      '-s', 'read-only',
      '--skip-git-repo-check',
      '--ephemeral',
      '--ignore-user-config',
      '--ignore-rules',
      if (model.isNotEmpty) ...['-m', model],
      '-', // read the prompt from stdin
    ];
    String? errorText;
    await for (final line in runCliLines(
      executable: exe,
      args: args,
      stdin: foldMessages(messages, jsonSchema: jsonSchema),
      // Codex finds its sign-in via CODEX_HOME; everything else sees an empty home.
      isolateHome: true,
      extraEnv: {'CODEX_HOME': codexHome},
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
        case 'item.completed':
          final item = obj['item'] as Map<String, dynamic>? ?? const {};
          if (item['type'] == 'agent_message' && item['text'] is String) {
            yield item['text'] as String;
          }
        case 'turn.failed':
          errorText = '${(obj['error'] as Map?)?['message'] ?? ''}';
          throw _failure(errorText, 1);
        case 'error':
          errorText = '${obj['message'] ?? ''}';
      }
    }
  }

  static AiException _failure(String text, int code) {
    if (looksLikeLimit(text)) {
      return AiLimitException('Codex usage limit reached. Try again later or pick another engine.');
    }
    if (looksLikeAuth(text)) {
      return AiAuthException('Codex is not signed in. Run `codex login` in Terminal.');
    }
    final first = text.trim().split('\n').first;
    return AiException('Codex failed${first.isEmpty ? ' (exit $code)' : ': $first'}');
  }
}

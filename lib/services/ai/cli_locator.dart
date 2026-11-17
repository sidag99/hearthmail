import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ai_provider.dart';

/// Finds command-line tools. GUI apps on macOS do not inherit the shell PATH,
/// so we look in common install folders and ask a login shell.
class CliLocator {
  static final _cache = <String, String?>{};

  static List<String> candidateDirs([String? home]) {
    final h = home ?? Platform.environment['HOME'] ?? '';
    return [
      '/opt/homebrew/bin',
      '/usr/local/bin',
      if (h.isNotEmpty) ...[
        '$h/.local/bin',
        '$h/.claude/local',
        '$h/.npm-global/bin',
        '$h/.bun/bin',
        '$h/.volta/bin',
      ],
    ];
  }

  static bool _isExecutable(String path) {
    try {
      final stat = File(path).statSync();
      return stat.type == FileSystemEntityType.file && (stat.mode & 0x49) != 0;
    } catch (_) {
      return false;
    }
  }

  /// Absolute path of [name], or null if it is not installed.
  static Future<String?> find(String name, {bool refresh = false, String? home}) async {
    if (!refresh && _cache.containsKey(name)) return _cache[name];
    String? found;
    for (final d in candidateDirs(home)) {
      if (_isExecutable('$d/$name')) {
        found = '$d/$name';
        break;
      }
    }
    if (found == null && Platform.isMacOS) {
      try {
        final r = await Process.run('/bin/zsh', ['-lc', 'command -v $name'])
            .timeout(const Duration(seconds: 5));
        final out = (r.stdout as String).trim().split('\n').last.trim();
        if (r.exitCode == 0 && out.startsWith('/') && _isExecutable(out)) found = out;
      } catch (_) {}
    }
    return _cache[name] = found;
  }

  static void clearCache() => _cache.clear();
}

/// Runs a CLI once: prompt on stdin, stdout lines streamed back.
/// Prompts are never logged or written anywhere.
Stream<String> runCliLines({
  required String executable,
  required List<String> args,
  required String stdin,
  Duration timeout = const Duration(minutes: 5),
  required AiException Function(String stderr, int exitCode) onFailure,
}) async* {
  final dir = await Directory.systemTemp.createTemp('hearthmail_cli_');
  Process? process;
  final stderrBuf = StringBuffer();
  try {
    process = await Process.start(
      executable,
      args,
      workingDirectory: dir.path,
      environment: {
        // The shell PATH is missing in GUI apps; node-based CLIs need it.
        'PATH': [
          ...CliLocator.candidateDirs(),
          Platform.environment['PATH'] ?? '/usr/bin:/bin',
        ].join(':'),
      },
    );
    final errSub = process.stderr
        .transform(utf8.decoder)
        .listen((s) {
      if (stderrBuf.length < 4000) stderrBuf.write(s);
    });
    // Writing may fail if the process exits early; the exit code reports it.
    unawaited(() async {
      try {
        process!.stdin.write(stdin);
        await process.stdin.close();
      } catch (_) {}
    }());
    final lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(timeout, onTimeout: (sink) {
      sink.addError(AiException('The AI command took too long and was stopped.'));
      sink.close();
    });
    await for (final l in lines) {
      yield l;
    }
    final code = await process.exitCode;
    await errSub.cancel();
    if (code != 0) throw onFailure(stderrBuf.toString(), code);
  } on ProcessException {
    throw AiAuthException('Could not start $executable.');
  } finally {
    process?.kill();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
}

/// Folds a conversation into one stdin prompt for CLIs that take plain text.
String foldMessages(List<AiMessage> messages, {Map<String, dynamic>? jsonSchema}) {
  final b = StringBuffer();
  final system = messages.where((m) => m.role == AiRole.system).map((m) => m.content);
  if (system.isNotEmpty) {
    b.writeln('<instructions>\n${system.join('\n\n')}\n</instructions>\n');
  }
  final convo = messages.where((m) => m.role != AiRole.system).toList();
  if (convo.length == 1) {
    b.writeln(convo.first.content);
  } else {
    for (final m in convo) {
      b.writeln('${m.role == AiRole.user ? 'User' : 'Assistant'}:\n${m.content}\n');
    }
  }
  if (jsonSchema != null) {
    b.writeln('\nReply with ONLY a single JSON object that matches this JSON Schema. '
        'No prose, no code fences.\nSchema: ${jsonEncode(jsonSchema)}');
  }
  return b.toString();
}

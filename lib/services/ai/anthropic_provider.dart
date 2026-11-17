import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'ai_provider.dart';
import 'sse.dart';

/// Talks to the Anthropic Messages API with the user's own API key.
class AnthropicProvider extends AiProvider {
  AnthropicProvider({
    required this.apiKey,
    this.baseUrl = 'https://api.anthropic.com',
    http.Client? client,
  }) : _client = client ?? http.Client();

  static const writingModel = 'claude-sonnet-5-5';
  static const fastModel = 'claude-haiku-5-5';
  static const apiVersion = '2023-06-01';

  /// Name of the forced tool used for JSON-constrained replies.
  static const jsonToolName = 'respond';

  final String apiKey;
  final String baseUrl;
  final http.Client _client;

  @override
  String get name => 'Claude API';

  Map<String, String> get _headers => {
        'x-api-key': apiKey,
        'anthropic-version': apiVersion,
        'content-type': 'application/json',
      };

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse(baseUrl.replaceAll(RegExp(r'/+$'), '') + path)
          .replace(queryParameters: query);

  @override
  Future<List<String>> listModels() async {
    final http.Response res;
    try {
      res = await _client
          .get(_uri('/v1/models', {'limit': '100'}), headers: _headers)
          .timeout(const Duration(seconds: 15));
    } on SocketException {
      throw AiException('Could not reach the Claude API. Check your internet connection.');
    } on TimeoutException {
      throw AiException('The Claude API did not respond.');
    }
    if (res.statusCode != 200) throw _error(res.body, res.statusCode);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return [
      for (final m in (data['data'] as List? ?? const [])) (m as Map)['id'] as String
    ];
  }

  @override
  Stream<String> chat(
    List<AiMessage> messages, {
    required String model,
    double temperature = 0.4,
    Map<String, dynamic>? jsonSchema,
  }) async* {
    if (apiKey.trim().isEmpty) {
      throw AiAuthException('Add your Claude API key in Settings to use it.');
    }
    final system = messages
        .where((m) => m.role == AiRole.system)
        .map((m) => m.content)
        .join('\n\n');
    final body = <String, dynamic>{
      'model': model,
      'max_tokens': 4096,
      'stream': true,
      'temperature': temperature,
      if (system.isNotEmpty) 'system': system,
      'messages': [
        for (final m in messages)
          if (m.role != AiRole.system) {'role': m.role.name, 'content': m.content}
      ],
      if (jsonSchema != null) ...{
        'tools': [
          {
            'name': jsonToolName,
            'description': 'Return the answer as structured data.',
            'input_schema': jsonSchema,
          }
        ],
        'tool_choice': {'type': 'tool', 'name': jsonToolName},
      },
    };
    final req = http.Request('POST', _uri('/v1/messages'))
      ..headers.addAll(_headers)
      ..body = jsonEncode(body);

    final http.StreamedResponse res;
    try {
      res = await _client.send(req);
    } on SocketException {
      throw AiException('Could not reach the Claude API. Check your internet connection.');
    }
    if (res.statusCode != 200) {
      throw _error(await res.stream.bytesToString(), res.statusCode);
    }

    await for (final e in parseSse(res.stream)) {
      final Map<String, dynamic> obj;
      try {
        obj = jsonDecode(e.data) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      switch (obj['type']) {
        case 'content_block_delta':
          final d = obj['delta'] as Map<String, dynamic>? ?? const {};
          if (d['type'] == 'text_delta' && jsonSchema == null) {
            final t = d['text'] as String?;
            if (t != null && t.isNotEmpty) yield t;
          } else if (d['type'] == 'input_json_delta') {
            final t = d['partial_json'] as String?;
            if (t != null && t.isNotEmpty) yield t;
          }
        case 'error':
          final err = obj['error'] as Map?;
          final msg = err?['message']?.toString() ?? 'unknown error';
          if (err?['type'] == 'overloaded_error' || err?['type'] == 'rate_limit_error') {
            throw AiLimitException('Claude API is busy or rate limited: $msg');
          }
          throw AiException('Claude API error: $msg');
        case 'message_stop':
          return;
      }
    }
  }

  static AiException _error(String body, int status) {
    String? msg;
    try {
      msg = ((jsonDecode(body) as Map)['error'] as Map?)?['message']?.toString();
    } catch (_) {}
    if (status == 401 || status == 403) {
      return AiAuthException('The Claude API key was rejected. Check it in Settings.');
    }
    if (status == 429 || status == 529) {
      return AiLimitException('Claude API rate limit or usage cap reached. ${msg ?? ''}'.trim());
    }
    return AiException('Claude API error (HTTP $status)${msg == null ? '' : ': $msg'}');
  }

  @override
  void close() => _client.close();
}

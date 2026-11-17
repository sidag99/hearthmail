import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'ai_provider.dart';
import 'sse.dart';

/// Talks to the OpenAI Chat Completions API with the user's own API key.
class OpenAiProvider extends AiProvider {
  OpenAiProvider({
    required this.apiKey,
    this.baseUrl = 'https://api.openai.com',
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Used when the user has not picked a model.
  static const defaultModel = 'gpt-5.5';

  final String apiKey;
  final String baseUrl;
  final http.Client _client;

  @override
  String get name => 'OpenAI API';

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $apiKey',
        'content-type': 'application/json',
      };

  Uri _uri(String path) =>
      Uri.parse(baseUrl.replaceAll(RegExp(r'/+$'), '') + path);

  /// Keeps ids of models that can chat; drops embeddings, audio, images, etc.
  static bool isChatModelId(String id) {
    if (!RegExp(r'^(gpt-|chatgpt-|o\d)').hasMatch(id)) return false;
    const skip = [
      'embedding', 'audio', 'realtime', 'image', 'tts', 'transcribe',
      'moderation', 'whisper', 'search', 'instruct', 'codex', 'dall-e', 'computer-use',
    ];
    return !skip.any(id.contains);
  }

  @override
  Future<List<String>> listModels() async {
    final http.Response res;
    try {
      res = await _client
          .get(_uri('/v1/models'), headers: _headers)
          .timeout(const Duration(seconds: 15));
    } on SocketException {
      throw AiException('Could not reach the OpenAI API. Check your internet connection.');
    } on TimeoutException {
      throw AiException('The OpenAI API did not respond.');
    }
    if (res.statusCode != 200) throw _error(res.body, res.statusCode);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return [
      for (final m in (data['data'] as List? ?? const []))
        if (isChatModelId((m as Map)['id'] as String)) m['id'] as String
    ]..sort();
  }

  /// Rewrites a JSON schema to satisfy OpenAI strict mode: every object gets
  /// `additionalProperties: false` and lists all its properties as required.
  static Map<String, dynamic> strictSchema(Map<String, dynamic> schema) {
    dynamic walk(dynamic node) {
      if (node is List) return [for (final x in node) walk(x)];
      if (node is! Map) return node;
      final out = <String, dynamic>{
        for (final e in node.entries) e.key as String: walk(e.value)
      };
      final props = out['properties'];
      if (out['type'] == 'object' || props is Map) {
        out['additionalProperties'] = false;
        out['required'] = [if (props is Map) ...props.keys.cast<String>()];
        out['properties'] ??= <String, dynamic>{};
      }
      return out;
    }

    return walk(schema) as Map<String, dynamic>;
  }

  /// Reasoning models only accept the default temperature.
  static bool _supportsTemperature(String model) =>
      !RegExp(r'^(o\d|gpt-5)').hasMatch(model);

  @override
  Stream<String> chat(
    List<AiMessage> messages, {
    required String model,
    double temperature = 0.4,
    Map<String, dynamic>? jsonSchema,
  }) async* {
    if (apiKey.trim().isEmpty) {
      throw AiAuthException('Add your OpenAI API key in Settings to use it.');
    }
    final body = <String, dynamic>{
      'model': model,
      'stream': true,
      'messages': [
        for (final m in messages) {'role': m.role.name, 'content': m.content}
      ],
      if (_supportsTemperature(model)) 'temperature': temperature,
      if (jsonSchema != null)
        'response_format': {
          'type': 'json_schema',
          'json_schema': {
            'name': 'response',
            'schema': strictSchema(jsonSchema),
            'strict': true,
          },
        },
    };
    final req = http.Request('POST', _uri('/v1/chat/completions'))
      ..headers.addAll(_headers)
      ..body = jsonEncode(body);

    final http.StreamedResponse res;
    try {
      res = await _client.send(req);
    } on SocketException {
      throw AiException('Could not reach the OpenAI API. Check your internet connection.');
    }
    if (res.statusCode != 200) {
      throw _error(await res.stream.bytesToString(), res.statusCode);
    }

    await for (final e in parseSse(res.stream)) {
      if (e.data.trim() == '[DONE]') return;
      final Map<String, dynamic> obj;
      try {
        obj = jsonDecode(e.data) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      if (obj['error'] != null) {
        final msg = '${(obj['error'] as Map)['message']}';
        if (looksLikeLimit(msg)) throw AiLimitException('OpenAI usage limit: $msg');
        throw AiException('OpenAI API error: $msg');
      }
      for (final c in (obj['choices'] as List? ?? const [])) {
        final delta = (c as Map)['delta'] as Map?;
        final t = delta?['content'] as String?;
        if (t != null && t.isNotEmpty) yield t;
        final refusal = delta?['refusal'];
        if (refusal is String && refusal.isNotEmpty) {
          throw AiException('OpenAI declined: $refusal');
        }
      }
    }
  }

  static AiException _error(String body, int status) {
    String? msg;
    try {
      msg = ((jsonDecode(body) as Map)['error'] as Map?)?['message']?.toString();
    } catch (_) {}
    if (status == 401 || status == 403) {
      return AiAuthException('The OpenAI API key was rejected. Check it in Settings.');
    }
    if (status == 429) {
      return AiLimitException('OpenAI rate limit or quota reached. ${msg ?? ''}'.trim());
    }
    return AiException('OpenAI API error (HTTP $status)${msg == null ? '' : ': $msg'}');
  }

  @override
  void close() => _client.close();
}

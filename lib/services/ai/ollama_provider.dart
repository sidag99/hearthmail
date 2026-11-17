import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'ai_provider.dart';

/// Talks to an Ollama server (by default the one on this Mac).
class OllamaProvider extends AiProvider {
  OllamaProvider({this.baseUrl = 'http://localhost:11434', http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  /// Same context size for every call, so Ollama never reloads the model
  /// just because a request asked for a different window.
  static const int contextTokens = 8192;

  @override
  String get name => 'Ollama';

  Uri _uri(String path) =>
      Uri.parse(baseUrl.replaceAll(RegExp(r'/+$'), '') + path);

  @override
  Future<List<String>> listModels() async {
    final http.Response res;
    try {
      res = await _client
          .get(_uri('/api/tags'))
          .timeout(const Duration(seconds: 5));
    } on SocketException {
      throw AiException(
          'Could not reach Ollama at $baseUrl. Is the Ollama app running?');
    } on TimeoutException {
      throw AiException('Ollama at $baseUrl did not respond.');
    }
    if (res.statusCode != 200) {
      throw AiException('Ollama returned HTTP ${res.statusCode}.');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final models = (data['models'] as List? ?? const [])
        .map((m) => (m as Map)['name'] as String)
        .toList()
      ..sort();
    return models;
  }

  @override
  Stream<String> chat(
    List<AiMessage> messages, {
    required String model,
    double temperature = 0.4,
    Map<String, dynamic>? jsonSchema,
  }) async* {
    final req = http.Request('POST', _uri('/api/chat'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'model': model,
        'messages': [
          for (final m in messages) {'role': m.role.name, 'content': m.content}
        ],
        'stream': true,
        // Email tasks don't benefit from long hidden reasoning; skip it for speed.
        'think': false,
        'keep_alive': '30m',
        'options': {'temperature': temperature, 'num_ctx': contextTokens},
        'format': ?jsonSchema,
      });

    final http.StreamedResponse res;
    try {
      res = await _client.send(req);
    } on SocketException {
      throw AiException(
          'Could not reach Ollama at $baseUrl. Is the Ollama app running?');
    }
    if (res.statusCode != 200) {
      final body = await res.stream.bytesToString();
      throw AiException(_errorText(body, res.statusCode, model));
    }

    final lines =
        res.stream.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final obj = jsonDecode(line) as Map<String, dynamic>;
      if (obj['error'] != null) throw AiException(obj['error'].toString());
      final content = (obj['message'] as Map?)?['content'] as String?;
      if (content != null && content.isNotEmpty) yield content;
      if (obj['done'] == true) break;
    }
  }

  @override
  Future<List<List<double>>> embed(List<String> inputs, {required String model}) async {
    if (inputs.isEmpty) return [];
    final http.Response res;
    try {
      res = await _client
          .post(_uri('/api/embed'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'model': model, 'input': inputs, 'truncate': true, 'keep_alive': '30m'}))
          .timeout(const Duration(minutes: 2));
    } on SocketException {
      throw AiException('Could not reach Ollama at $baseUrl. Is the Ollama app running?');
    } on TimeoutException {
      throw AiException('Ollama took too long to index.');
    }
    if (res.statusCode != 200) throw AiException(_errorText(res.body, res.statusCode, model));
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return [
      for (final e in data['embeddings'] as List) [for (final x in e as List) (x as num).toDouble()]
    ];
  }

  String _errorText(String body, int status, String model) {
    try {
      final err = (jsonDecode(body) as Map)['error']?.toString() ?? body;
      if (err.contains('not found')) {
        return 'Model "$model" is not installed in Ollama. '
            'Pick another in Settings or run: ollama pull $model';
      }
      return 'Ollama error: $err';
    } catch (_) {
      return 'Ollama returned HTTP $status.';
    }
  }

  @override
  void close() => _client.close();
}

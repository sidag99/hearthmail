import 'dart:convert';

/// A pluggable source of AI. Today this is Ollama on the local machine; later
/// it can be an on-device phone model or a remote Ollama on the user's own Mac.
abstract class AiProvider {
  String get name;

  /// Model names this provider can run.
  Future<List<String>> listModels();

  /// Streams the assistant's reply chunk by chunk.
  ///
  /// When [jsonSchema] is given, the reply is constrained to JSON matching it.
  Stream<String> chat(
    List<AiMessage> messages, {
    required String model,
    double temperature = 0.4,
    Map<String, dynamic>? jsonSchema,
  });

  /// Turns texts into vectors for semantic search (one per input).
  Future<List<List<double>>> embed(List<String> inputs, {required String model}) =>
      throw AiException('$name does not support embeddings.');

  void close() {}
}

enum AiRole { system, user, assistant }

class AiMessage {
  const AiMessage(this.role, this.content);
  const AiMessage.system(this.content) : role = AiRole.system;
  const AiMessage.user(this.content) : role = AiRole.user;
  const AiMessage.assistant(this.content) : role = AiRole.assistant;

  final AiRole role;
  final String content;
}

class AiException implements Exception {
  AiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Rate limit, usage cap or quota reached (HTTP 429, "usage limit", ...).
/// The UI can offer to retry with another engine.
class AiLimitException extends AiException {
  AiLimitException(super.message);
}

/// Missing/invalid key, not signed in, or the CLI is not installed.
class AiAuthException extends AiException {
  AiAuthException(super.message);
}

/// True when [text] looks like a usage-limit message from a CLI or API.
bool looksLikeLimit(String text) => RegExp(
        r'rate.?limit|usage limit|limit reached|quota|too many requests|\b429\b|overloaded|credit balance|out of credits',
        caseSensitive: false)
    .hasMatch(text);

/// True when [text] looks like an authentication problem.
bool looksLikeAuth(String text) => RegExp(
        r'not logged in|log ?in|sign ?in|unauthori[sz]ed|invalid api key|authentication|\b401\b|please run /login',
        caseSensitive: false)
    .hasMatch(text);

extension AiProviderHelpers on AiProvider {
  /// Runs a chat and returns the whole reply as one string.
  Future<String> complete(
    List<AiMessage> messages, {
    required String model,
    double temperature = 0.4,
  }) async {
    final buf = StringBuffer();
    await for (final chunk
        in chat(messages, model: model, temperature: temperature)) {
      buf.write(chunk);
    }
    return buf.toString().trim();
  }

  /// Runs a chat constrained to [schema] and decodes the JSON reply.
  Future<Map<String, dynamic>> completeJson(
    List<AiMessage> messages, {
    required String model,
    required Map<String, dynamic> schema,
    double temperature = 0.1,
  }) async {
    final buf = StringBuffer();
    await for (final chunk in chat(messages,
        model: model, temperature: temperature, jsonSchema: schema)) {
      buf.write(chunk);
    }
    final text = buf.toString().trim();
    try {
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      // Some models wrap JSON in prose or code fences; pull out the object.
      final start = text.indexOf('{');
      final end = text.lastIndexOf('}');
      if (start >= 0 && end > start) {
        return jsonDecode(text.substring(start, end + 1))
            as Map<String, dynamic>;
      }
      throw AiException('The model did not return valid JSON.');
    }
  }
}

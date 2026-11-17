import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hearthmail/services/ai/ai_provider.dart';
import 'package:hearthmail/services/ai/anthropic_provider.dart';
import 'package:hearthmail/services/ai/claude_cli_provider.dart';
import 'package:hearthmail/services/ai/codex_cli_provider.dart';
import 'package:hearthmail/services/ai/engines.dart';
import 'package:hearthmail/services/ai/openai_provider.dart';
import 'package:hearthmail/services/settings_store.dart';
import 'package:hearthmail/state/ai_engines.dart';
import 'package:hearthmail/state/app_state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.StreamedResponse sse(List<String> events, [int status = 200]) =>
    http.StreamedResponse(
      Stream.value(utf8.encode('${events.join('\n\n')}\n\n')),
      status,
    );

void main() {
  group('AnthropicProvider', () {
    test('streams text deltas with the right headers', () async {
      late http.BaseRequest seen;
      late Map<String, dynamic> body;
      final client = MockClient.streaming((req, bodyStream) async {
        seen = req;
        body = jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>;
        return sse([
          'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}',
          'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"lo"}}',
          'event: message_stop\ndata: {"type":"message_stop"}',
        ]);
      });
      final p = AnthropicProvider(apiKey: 'k', client: client);
      final out = await p.complete(
          const [AiMessage.system('be brief'), AiMessage.user('hi')],
          model: AnthropicProvider.writingModel);
      expect(out, 'Hello');
      expect(seen.headers['x-api-key'], 'k');
      expect(seen.headers['anthropic-version'], '2023-06-01');
      expect(body['system'], 'be brief');
      expect(body['stream'], true);
      expect(body.containsKey('tools'), false);
    });

    test('JSON mode uses a forced tool call', () async {
      late Map<String, dynamic> body;
      final client = MockClient.streaming((req, bodyStream) async {
        body = jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>;
        return sse([
          'data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{\\"a\\":"}}',
          'data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"1}"}}',
          'data: {"type":"message_stop"}',
        ]);
      });
      final p = AnthropicProvider(apiKey: 'k', client: client);
      final json = await p.completeJson(const [AiMessage.user('x')],
          model: 'm', schema: {'type': 'object', 'properties': {'a': {'type': 'integer'}}});
      expect(json, {'a': 1});
      expect(body['tool_choice'], {'type': 'tool', 'name': AnthropicProvider.jsonToolName});
      expect((body['tools'] as List).single['input_schema'], isA<Map>());
    });

    test('429 becomes AiLimitException, 401 AiAuthException', () async {
      for (final (status, type) in [(429, AiLimitException), (401, AiAuthException)]) {
        final client = MockClient.streaming((req, b) async => http.StreamedResponse(
            Stream.value(utf8.encode('{"error":{"message":"nope"}}')), status));
        final p = AnthropicProvider(apiKey: 'k', client: client);
        await expectLater(
            p.complete(const [AiMessage.user('x')], model: 'm'),
            throwsA(predicate((e) => e.runtimeType == type)));
      }
    });

    test('lists models', () async {
      final client = MockClient((req) async {
        expect(req.url.path, '/v1/models');
        return http.Response('{"data":[{"id":"claude-sonnet-5-5"},{"id":"claude-haiku-5-5"}]}', 200);
      });
      final p = AnthropicProvider(apiKey: 'k', client: client);
      expect(await p.listModels(), ['claude-sonnet-5-5', 'claude-haiku-5-5']);
    });
  });

  group('OpenAiProvider', () {
    test('streams deltas until [DONE]', () async {
      late Map<String, dynamic> body;
      late http.BaseRequest seen;
      final client = MockClient.streaming((req, bodyStream) async {
        seen = req;
        body = jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>;
        return sse([
          'data: {"choices":[{"delta":{"content":"Hi"}}]}',
          'data: {"choices":[{"delta":{"content":" there"}}]}',
          'data: [DONE]',
        ]);
      });
      final p = OpenAiProvider(apiKey: 'sk-test', client: client);
      expect(await p.complete(const [AiMessage.user('x')], model: 'gpt-4o'), 'Hi there');
      expect(seen.headers['Authorization'], 'Bearer sk-test');
      expect(body['temperature'], isNotNull);
    });

    test('JSON mode sends strict json_schema', () async {
      late Map<String, dynamic> body;
      final client = MockClient.streaming((req, bodyStream) async {
        body = jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>;
        return sse([
          'data: {"choices":[{"delta":{"content":"{\\"ok\\":true}"}}]}',
          'data: [DONE]',
        ]);
      });
      final p = OpenAiProvider(apiKey: 'k', client: client);
      final json = await p.completeJson(const [AiMessage.user('x')],
          model: 'gpt-4o',
          schema: {'type': 'object', 'properties': {'ok': {'type': 'boolean'}}});
      expect(json, {'ok': true});
      final rf = body['response_format'] as Map;
      expect(rf['type'], 'json_schema');
      expect(rf['json_schema']['strict'], true);
      expect(rf['json_schema']['schema']['additionalProperties'], false);
      expect(rf['json_schema']['schema']['required'], ['ok']);
    });

    test('429 becomes AiLimitException', () async {
      final client = MockClient.streaming((req, b) async => http.StreamedResponse(
          Stream.value(utf8.encode('{"error":{"message":"quota"}}')), 429));
      final p = OpenAiProvider(apiKey: 'k', client: client);
      await expectLater(p.complete(const [AiMessage.user('x')], model: 'gpt-4o'),
          throwsA(isA<AiLimitException>()));
    });

    test('lists only chat models', () async {
      final client = MockClient((req) async => http.Response(
          '{"data":[{"id":"gpt-4o"},{"id":"text-embedding-3-small"},{"id":"whisper-1"},{"id":"gpt-5.5"}]}',
          200));
      final p = OpenAiProvider(apiKey: 'k', client: client);
      expect(await p.listModels(), ['gpt-4o', 'gpt-5.5']);
    });
  });

  group('CLI providers (fake executables)', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('fakecli_'));
    tearDown(() => dir.deleteSync(recursive: true));

    String script(String name, String body) {
      final f = File('${dir.path}/$name')..writeAsStringSync('#!/bin/sh\n$body\n');
      Process.runSync('chmod', ['+x', f.path]);
      return f.path;
    }

    test('Claude CLI streams text deltas and reads the prompt from stdin', () async {
      final exe = script('claude', r'''
in=$(cat)
echo '{"type":"system"}'
echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"got:"}}}'
echo "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"$(echo $in | tr -d '\"\\' | cut -c1-20)\"}}}"
echo '{"type":"result","is_error":false,"result":"done"}'
''');
      final p = ClaudeCliProvider(executable: exe);
      final out = await p.complete(const [AiMessage.user('ping')], model: '');
      expect(out, startsWith('got:'));
      expect(out, contains('ping'));
    });

    test('Claude CLI usage limit maps to AiLimitException', () async {
      final exe = script('claude',
          'cat >/dev/null\necho \'{"type":"result","is_error":true,"result":"Claude AI usage limit reached"}\'\nexit 1');
      await expectLater(
          ClaudeCliProvider(executable: exe).complete(const [AiMessage.user('x')], model: ''),
          throwsA(isA<AiLimitException>()));
    });

    test('Claude CLI not signed in maps to AiAuthException', () async {
      final exe = script('claude', 'cat >/dev/null\necho "Please run /login" >&2\nexit 1');
      await expectLater(
          ClaudeCliProvider(executable: exe).complete(const [AiMessage.user('x')], model: ''),
          throwsA(isA<AiAuthException>()));
    });

    test('Codex CLI returns agent messages', () async {
      final exe = script('codex', r'''
cat >/dev/null
echo '{"type":"thread.started"}'
echo '{"type":"item.completed","item":{"type":"agent_message","text":"OK"}}'
echo '{"type":"turn.completed"}'
''');
      final p = CodexCliProvider(executable: exe);
      expect(await p.complete(const [AiMessage.user('x')], model: ''), 'OK');
    });

    test('Codex CLI failure maps to a limit error', () async {
      final exe = script('codex',
          'cat >/dev/null\necho \'{"type":"turn.failed","error":{"message":"You hit your usage limit"}}\'\nexit 1');
      await expectLater(
          CodexCliProvider(executable: exe).complete(const [AiMessage.user('x')], model: ''),
          throwsA(isA<AiLimitException>()));
    });

    test('missing executable is an auth/config error', () async {
      await expectLater(
          ClaudeCliProvider(executable: '/nonexistent/claude')
              .complete(const [AiMessage.user('x')], model: ''),
          throwsA(isA<AiException>()));
    });
  });

  group('WritingChoice routing', () {
    late AppState state;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      state = AppState(await SettingsStore.open());
      state.availableModels = ['gemma4:12b', 'nomic-embed-text'];
    });

    test('lists local chat models only when nothing else is configured', () {
      expect(state.writingChoices.map((c) => c.label), ['gemma4:12b · Local']);
      expect(state.currentWritingChoice.engine, AiEngine.local);
      expect(state.fallbackFor(state.writingChoices.first), isNull);
    });

    test('labels and fallback prefer local', () {
      const cloud = WritingChoice(AiEngine.claudeApi, 'claude-sonnet-5-5', 'Claude Sonnet 5.5 · API');
      expect(EngineHub.label(AiEngine.claudeApi, 'claude-sonnet-5-5'), 'Claude Sonnet 5.5 · API');
      expect(cloud.isCloud, true);
      final fb = state.fallbackFor(cloud);
      expect(fb?.engine, AiEngine.local);
      expect(fb?.model, 'gemma4:12b');
    });

    test('setWritingChoice persists local choice; unconfigured cloud falls back to local', () async {
      await state.setWritingChoice(
          const WritingChoice(AiEngine.claudeApi, 'claude-sonnet-5-5', 'x'));
      expect(state.settings.writingEngine, AiEngine.claudeApi);
      // No key configured, so the effective choice is still local.
      expect(state.currentWritingChoice.engine, AiEngine.local);
      await state.setWritingChoice(
          const WritingChoice(AiEngine.local, 'gemma4:12b', 'gemma4:12b · Local'));
      expect(state.settings.writingEngine, AiEngine.local);
      expect(state.settings.writingModel, 'gemma4:12b');
    });

    test('prettyClaude', () {
      expect(EngineHub.prettyClaude('claude-haiku-5-5'), 'Claude Haiku 5.5');
      expect(EngineHub.prettyClaude('claude-sonnet-4-5-20250929'), 'Claude Sonnet 4.5');
    });
  });
}

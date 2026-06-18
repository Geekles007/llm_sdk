import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llm_sdk/llm_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('ClaudeProvider — aller (encodage)', () {
    test('extrait system, encode messages, tools et tool_choice', () async {
      late Map<String, dynamic> sentBody;

      final mock = MockClient((req) async {
        sentBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'content': [
              {'type': 'text', 'text': 'ok'},
            ],
            'stop_reason': 'end_turn',
            'usage': {'input_tokens': 10, 'output_tokens': 2},
          }),
          200,
        );
      });

      final provider = ClaudeProvider(apiKey: 'k', httpClient: mock);

      await provider.generate(
        [Message.system('Tu es utile.'), Message.user('Salut')],
        tools: [
          Tool(
            name: 'getMeteo',
            description: 'météo',
            parameters: {'type': 'object'},
            run: (_) async => '',
          ),
        ],
        forceTool: 'getMeteo',
      );

      // system extrait hors du tableau messages.
      expect(sentBody['system'], 'Tu es utile.');
      expect(sentBody['messages'], hasLength(1));
      expect((sentBody['messages'] as List).first['role'], 'user');
      // max_tokens toujours présent.
      expect(sentBody['max_tokens'], isNotNull);
      // tools : `input_schema`, pas `parameters`.
      final tool = (sentBody['tools'] as List).first as Map;
      expect(tool['input_schema'], {'type': 'object'});
      expect(tool.containsKey('parameters'), isFalse);
      // tool_choice forcé.
      expect(sentBody['tool_choice'], {'type': 'tool', 'name': 'getMeteo'});
    });

    test('encode un résultat d\'outil en message user/tool_result', () async {
      late Map<String, dynamic> sentBody;
      final mock = MockClient((req) async {
        sentBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'content': [
              {'type': 'text', 'text': 'fini'},
            ],
            'stop_reason': 'end_turn',
          }),
          200,
        );
      });
      final provider = ClaudeProvider(apiKey: 'k', httpClient: mock);

      await provider.generate([
        Message(Role.tool, [ToolResultPart('call_1', '29 °C')]),
      ]);

      final msg = (sentBody['messages'] as List).first as Map;
      expect(msg['role'], 'user'); // pas de rôle `tool` chez Anthropic
      final block = (msg['content'] as List).first as Map;
      expect(block['type'], 'tool_result');
      expect(block['tool_use_id'], 'call_1');
      expect(block['content'], '29 °C');
    });
  });

  group('ClaudeProvider — retour (décodage non-streamé)', () {
    test('décode texte + usage + finishReason', () async {
      final mock = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'content': [
              {'type': 'text', 'text': 'Bonjour'},
            ],
            'stop_reason': 'end_turn',
            'usage': {'input_tokens': 5, 'output_tokens': 3},
          }),
          200,
        );
      });
      final provider = ClaudeProvider(apiKey: 'k', httpClient: mock);

      final res = await provider.generate([Message.user('hi')]);

      expect(res.text, 'Bonjour');
      expect(res.finishReason, FinishReason.stop);
      expect(res.usage?.inputTokens, 5);
      expect(res.usage?.outputTokens, 3);
    });

    test('décode un tool_use en ToolCallPart', () async {
      final mock = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'content': [
              {
                'type': 'tool_use',
                'id': 'toolu_1',
                'name': 'getMeteo',
                'input': {'ville': 'Douala'},
              },
            ],
            'stop_reason': 'tool_use',
          }),
          200,
        );
      });
      final provider = ClaudeProvider(apiKey: 'k', httpClient: mock);

      final res = await provider.generate([Message.user('météo ?')]);

      expect(res.finishReason, FinishReason.toolUse);
      final call = res.toolCalls.single;
      expect(call.id, 'toolu_1');
      expect(call.name, 'getMeteo');
      expect(call.arguments, {'ville': 'Douala'});
    });

    test('ignore les blocs thinking sans crasher', () async {
      final mock = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'content': [
              {'type': 'thinking', 'thinking': '...'},
              {'type': 'text', 'text': 'réponse'},
            ],
            'stop_reason': 'end_turn',
          }),
          200,
        );
      });
      final provider = ClaudeProvider(apiKey: 'k', httpClient: mock);

      final res = await provider.generate([Message.user('hi')]);
      expect(res.message.parts, hasLength(1));
      expect(res.text, 'réponse');
    });

    test('lève LlmException sur statut non-200', () async {
      final mock = MockClient((req) async => http.Response('boom', 429));
      final provider = ClaudeProvider(apiKey: 'k', httpClient: mock);

      expect(
        () => provider.generate([Message.user('hi')]),
        throwsA(
          isA<LlmException>().having((e) => e.statusCode, 'statusCode', 429),
        ),
      );
    });
  });

  group('ClaudeProvider — streaming SSE', () {
    // Construit une réponse SSE à partir d'une liste d'events JSON.
    http.StreamedResponse sse(List<Map<String, dynamic>> events) {
      final buffer = StringBuffer();
      for (final e in events) {
        buffer.write('event: ${e['type']}\n');
        buffer.write('data: ${jsonEncode(e)}\n\n');
      }
      final bytes = utf8.encode(buffer.toString());
      return http.StreamedResponse(Stream.value(bytes), 200);
    }

    test('émet des TextDelta puis un StreamDone assemblé', () async {
      final mock = MockClient.streaming((req, bodyStream) async {
        return sse([
          {
            'type': 'message_start',
            'message': {
              'usage': {'input_tokens': 7, 'output_tokens': 0},
            },
          },
          {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'text', 'text': ''},
          },
          {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'text_delta', 'text': 'Hello '},
          },
          {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'text_delta', 'text': 'world'},
          },
          {'type': 'content_block_stop', 'index': 0},
          {
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn'},
            'usage': {'output_tokens': 2},
          },
          {'type': 'message_stop'},
        ]);
      });
      final provider = ClaudeProvider(apiKey: 'k', httpClient: mock);

      final events = await provider.generateStream([
        Message.user('hi'),
      ]).toList();

      final deltas = events.whereType<TextDelta>().map((e) => e.text).toList();
      expect(deltas, ['Hello ', 'world']);

      final done = events.whereType<StreamDone>().single;
      expect(done.response.text, 'Hello world');
      expect(done.response.finishReason, FinishReason.stop);
      expect(done.response.usage?.inputTokens, 7);
      expect(done.response.usage?.outputTokens, 2);
    });

    test('assemble un appel d\'outil depuis input_json_delta', () async {
      final mock = MockClient.streaming((req, bodyStream) async {
        return sse([
          {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {
              'type': 'tool_use',
              'id': 'toolu_9',
              'name': 'getMeteo',
            },
          },
          {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'input_json_delta', 'partial_json': '{"ville"'},
          },
          {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'input_json_delta', 'partial_json': ':"Douala"}'},
          },
          {'type': 'content_block_stop', 'index': 0},
          {
            'type': 'message_delta',
            'delta': {'stop_reason': 'tool_use'},
          },
          {'type': 'message_stop'},
        ]);
      });
      final provider = ClaudeProvider(apiKey: 'k', httpClient: mock);

      final events = await provider.generateStream([
        Message.user('météo ?'),
      ]).toList();

      final call = events.whereType<ToolCallDelta>().single.call;
      expect(call.id, 'toolu_9');
      expect(call.name, 'getMeteo');
      expect(call.arguments, {'ville': 'Douala'});

      final done = events.whereType<StreamDone>().single;
      expect(done.response.toolCalls.single.arguments, {'ville': 'Douala'});
    });
  });
}

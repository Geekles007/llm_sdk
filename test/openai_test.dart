import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llm_sdk/llm_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('OpenAIProvider — aller (encodage)', () {
    test('garde system dans messages, encode tools et tool_choice', () async {
      late Map<String, dynamic> sentBody;
      String? authHeader;
      final mock = MockClient((req) async {
        sentBody = jsonDecode(req.body) as Map<String, dynamic>;
        authHeader = req.headers['authorization'];
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
            'usage': {'prompt_tokens': 10, 'completion_tokens': 2},
          }),
          200,
        );
      });
      final provider = OpenAIProvider(apiKey: 'k', httpClient: mock);

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

      // system reste dans le tableau messages (≠ Anthropic).
      final messages = sentBody['messages'] as List;
      expect(messages, hasLength(2));
      expect(messages.first['role'], 'system');
      expect(messages.first['content'], 'Tu es utile.');
      // tools : enveloppe `function`, avec `parameters` (≠ input_schema).
      final tool = (sentBody['tools'] as List).first as Map;
      expect(tool['type'], 'function');
      expect(tool['function']['parameters'], {'type': 'object'});
      // tool_choice forcé.
      expect(sentBody['tool_choice'], {
        'type': 'function',
        'function': {'name': 'getMeteo'},
      });
      // Authorization Bearer.
      expect(authHeader, 'Bearer k');
    });

    test('clé vide (endpoint local) → pas de header Authorization', () async {
      Map<String, String>? headers;
      final mock = MockClient((req) async {
        headers = req.headers;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      });
      // baseUrl local, aucune clé : cas Ollama / LM Studio / llama.cpp.
      final provider = OpenAIProvider(
        baseUrl: 'http://localhost:11434/v1',
        model: 'llama3.2',
        httpClient: mock,
      );

      await provider.generate([Message.user('Salut')]);

      expect(headers!.containsKey('authorization'), isFalse);
    });

    test('encode un appel + résultat d\'outil au format OpenAI', () async {
      late Map<String, dynamic> sentBody;
      final mock = MockClient((req) async {
        sentBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'fini'},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      });
      final provider = OpenAIProvider(apiKey: 'k', httpClient: mock);

      await provider.generate([
        Message.user('Météo ?'),
        Message(Role.assistant, [
          ToolCallPart('call_1', 'getMeteo', {'ville': 'Douala'}),
        ]),
        Message(Role.tool, [ToolResultPart('call_1', '29 °C')]),
      ]);

      final messages = sentBody['messages'] as List;
      // assistant avec tool_calls, arguments = string JSON.
      final assistant = messages[1] as Map;
      expect(assistant['role'], 'assistant');
      expect(assistant['content'], isNull); // que des appels d'outils
      final call = (assistant['tool_calls'] as List).first as Map;
      expect(call['type'], 'function');
      expect(call['function']['name'], 'getMeteo');
      expect(call['function']['arguments'], '{"ville":"Douala"}');
      // résultat = message rôle `tool` avec tool_call_id (≠ message user).
      final toolMsg = messages[2] as Map;
      expect(toolMsg['role'], 'tool');
      expect(toolMsg['tool_call_id'], 'call_1');
      expect(toolMsg['content'], '29 °C');
    });

    test('un message tool à N résultats devient N messages OpenAI', () async {
      late Map<String, dynamic> sentBody;
      final mock = MockClient((req) async {
        sentBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      });
      final provider = OpenAIProvider(apiKey: 'k', httpClient: mock);

      await provider.generate([
        Message(Role.tool, [
          ToolResultPart('c1', 'A'),
          ToolResultPart('c2', 'B'),
        ]),
      ]);

      final messages = sentBody['messages'] as List;
      expect(messages, hasLength(2));
      expect(messages[0]['tool_call_id'], 'c1');
      expect(messages[1]['tool_call_id'], 'c2');
    });
  });

  group('OpenAIProvider — retour (décodage non-streamé)', () {
    test('décode texte + usage + finishReason', () async {
      final mock = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'Bonjour'},
                'finish_reason': 'stop',
              },
            ],
            'usage': {'prompt_tokens': 5, 'completion_tokens': 3},
          }),
          200,
        );
      });
      final provider = OpenAIProvider(apiKey: 'k', httpClient: mock);

      final res = await provider.generate([Message.user('hi')]);

      expect(res.text, 'Bonjour');
      expect(res.finishReason, FinishReason.stop);
      expect(res.usage?.inputTokens, 5);
      expect(res.usage?.outputTokens, 3);
    });

    test(
      'décode un tool_call (arguments string JSON) en ToolCallPart',
      () async {
        final mock = MockClient((req) async {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': null,
                    'tool_calls': [
                      {
                        'id': 'call_9',
                        'type': 'function',
                        'function': {
                          'name': 'getMeteo',
                          'arguments': '{"ville":"Douala"}',
                        },
                      },
                    ],
                  },
                  'finish_reason': 'tool_calls',
                },
              ],
            }),
            200,
          );
        });
        final provider = OpenAIProvider(apiKey: 'k', httpClient: mock);

        final res = await provider.generate([Message.user('météo ?')]);

        expect(res.finishReason, FinishReason.toolUse);
        final call = res.toolCalls.single;
        expect(call.id, 'call_9');
        expect(call.name, 'getMeteo');
        expect(call.arguments, {'ville': 'Douala'});
      },
    );

    test('lève LlmException sur statut non-200', () async {
      final mock = MockClient((req) async => http.Response('boom', 401));
      final provider = OpenAIProvider(apiKey: 'k', httpClient: mock);

      expect(
        () => provider.generate([Message.user('hi')]),
        throwsA(
          isA<LlmException>().having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    });
  });

  group('OpenAIProvider — streaming SSE', () {
    http.StreamedResponse sse(List<Map<String, dynamic>?> chunks) {
      final buffer = StringBuffer();
      for (final c in chunks) {
        buffer.write('data: ${c == null ? '[DONE]' : jsonEncode(c)}\n\n');
      }
      return http.StreamedResponse(
        Stream.value(utf8.encode(buffer.toString())),
        200,
      );
    }

    test('émet des TextDelta puis un StreamDone assemblé', () async {
      final mock = MockClient.streaming((req, body) async {
        return sse([
          {
            'choices': [
              {
                'delta': {'content': 'Hello '},
                'finish_reason': null,
              },
            ],
          },
          {
            'choices': [
              {
                'delta': {'content': 'world'},
                'finish_reason': null,
              },
            ],
          },
          {
            'choices': [
              {'delta': {}, 'finish_reason': 'stop'},
            ],
          },
          {
            'choices': [],
            'usage': {'prompt_tokens': 7, 'completion_tokens': 2},
          },
          null, // [DONE]
        ]);
      });
      final provider = OpenAIProvider(apiKey: 'k', httpClient: mock);

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

    test('assemble un appel d\'outil depuis les deltas indexés', () async {
      final mock = MockClient.streaming((req, body) async {
        return sse([
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_7',
                      'function': {'name': 'getMeteo', 'arguments': ''},
                    },
                  ],
                },
                'finish_reason': null,
              },
            ],
          },
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'function': {'arguments': '{"ville"'},
                    },
                  ],
                },
                'finish_reason': null,
              },
            ],
          },
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'function': {'arguments': ':"Douala"}'},
                    },
                  ],
                },
                'finish_reason': 'tool_calls',
              },
            ],
          },
          null,
        ]);
      });
      final provider = OpenAIProvider(apiKey: 'k', httpClient: mock);

      final events = await provider.generateStream([
        Message.user('météo ?'),
      ]).toList();

      final call = events.whereType<ToolCallDelta>().single.call;
      expect(call.id, 'call_7');
      expect(call.name, 'getMeteo');
      expect(call.arguments, {'ville': 'Douala'});

      final done = events.whereType<StreamDone>().single;
      expect(done.response.toolCalls.single.arguments, {'ville': 'Douala'});
    });
  });
}

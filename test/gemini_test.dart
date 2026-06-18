import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llm_sdk/llm_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('GeminiProvider — aller (encodage)', () {
    test('system_instruction, contents, tools et tool_config', () async {
      late Map<String, dynamic> sentBody;
      String? apiKeyHeader;
      Uri? sentUrl;
      final mock = MockClient((req) async {
        sentBody = jsonDecode(req.body) as Map<String, dynamic>;
        apiKeyHeader = req.headers['x-goog-api-key'];
        sentUrl = req.url;
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'role': 'model',
                  'parts': [
                    {'text': 'ok'},
                  ],
                },
                'finishReason': 'STOP',
              },
            ],
            'usageMetadata': {
              'promptTokenCount': 10,
              'candidatesTokenCount': 2,
            },
          }),
          200,
        );
      });
      final provider = GeminiProvider(apiKey: 'k', httpClient: mock);

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

      // system extrait dans system_instruction.
      expect(sentBody['system_instruction'], {
        'parts': [
          {'text': 'Tu es utile.'},
        ],
      });
      // contents : seul le user reste.
      final contents = sentBody['contents'] as List;
      expect(contents, hasLength(1));
      expect(contents.first['role'], 'user');
      // tools enveloppés dans functionDeclarations.
      final decls =
          (sentBody['tools'] as List).first['functionDeclarations'] as List;
      expect(decls.first['name'], 'getMeteo');
      // forçage via tool_config mode ANY.
      expect(sentBody['tool_config'], {
        'function_calling_config': {
          'mode': 'ANY',
          'allowed_function_names': ['getMeteo'],
        },
      });
      // clé API en en-tête, endpoint generateContent.
      expect(apiKeyHeader, 'k');
      expect(sentUrl!.path, endsWith('models/gemini-1.5-pro:generateContent'));
    });

    test(
      'assistant → role model, résultat outil → functionResponse par nom',
      () async {
        late Map<String, dynamic> sentBody;
        final mock = MockClient((req) async {
          sentBody = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'fini'},
                    ],
                  },
                  'finishReason': 'STOP',
                },
              ],
            }),
            200,
          );
        });
        final provider = GeminiProvider(apiKey: 'k', httpClient: mock);

        await provider.generate([
          Message.user('Météo ?'),
          Message(Role.assistant, [
            // id == name côté Gemini.
            ToolCallPart('getMeteo', 'getMeteo', {'ville': 'Douala'}),
          ]),
          Message(Role.tool, [ToolResultPart('getMeteo', '29 °C')]),
        ]);

        final contents = sentBody['contents'] as List;
        // assistant encodé en role `model` avec functionCall (args = map).
        final modelMsg = contents[1] as Map;
        expect(modelMsg['role'], 'model');
        final fc = (modelMsg['parts'] as List).first['functionCall'] as Map;
        expect(fc['name'], 'getMeteo');
        expect(fc['args'], {'ville': 'Douala'});
        // résultat → message user avec functionResponse recollé par NOM.
        final toolMsg = contents[2] as Map;
        expect(toolMsg['role'], 'user');
        final fr = (toolMsg['parts'] as List).first['functionResponse'] as Map;
        expect(fr['name'], 'getMeteo');
        expect(fr['response'], {'result': '29 °C'});
      },
    );
  });

  group('GeminiProvider — retour (décodage non-streamé)', () {
    test('décode texte + usage + finishReason', () async {
      final mock = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'Bonjour'},
                  ],
                },
                'finishReason': 'STOP',
              },
            ],
            'usageMetadata': {'promptTokenCount': 5, 'candidatesTokenCount': 3},
          }),
          200,
        );
      });
      final provider = GeminiProvider(apiKey: 'k', httpClient: mock);

      final res = await provider.generate([Message.user('hi')]);

      expect(res.text, 'Bonjour');
      expect(res.finishReason, FinishReason.stop);
      expect(res.usage?.inputTokens, 5);
      expect(res.usage?.outputTokens, 3);
    });

    test('décode un functionCall en ToolCallPart (id == name)', () async {
      final mock = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'functionCall': {
                        'name': 'getMeteo',
                        'args': {'ville': 'Douala'},
                      },
                    },
                  ],
                },
                'finishReason': 'STOP',
              },
            ],
          }),
          200,
        );
      });
      final provider = GeminiProvider(apiKey: 'k', httpClient: mock);

      final res = await provider.generate([Message.user('météo ?')]);

      final call = res.toolCalls.single;
      expect(call.name, 'getMeteo');
      expect(call.id, 'getMeteo'); // recollage par nom
      expect(call.arguments, {'ville': 'Douala'});
    });

    test('lève LlmException sur statut non-200', () async {
      final mock = MockClient((req) async => http.Response('boom', 403));
      final provider = GeminiProvider(apiKey: 'k', httpClient: mock);

      expect(
        () => provider.generate([Message.user('hi')]),
        throwsA(
          isA<LlmException>().having((e) => e.statusCode, 'statusCode', 403),
        ),
      );
    });
  });

  group('GeminiProvider — streaming SSE', () {
    http.StreamedResponse sse(List<Map<String, dynamic>> chunks) {
      final buffer = StringBuffer();
      for (final c in chunks) {
        buffer.write('data: ${jsonEncode(c)}\n\n');
      }
      return http.StreamedResponse(
        Stream.value(utf8.encode(buffer.toString())),
        200,
      );
    }

    test('émet des TextDelta puis un StreamDone assemblé', () async {
      final mock = MockClient.streaming((req, body) async {
        // endpoint streamGenerateContent + alt=sse.
        expect(req.url.path, endsWith(':streamGenerateContent'));
        expect(req.url.queryParameters['alt'], 'sse');
        return sse([
          {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'Hello '},
                  ],
                },
              },
            ],
          },
          {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'world'},
                  ],
                },
                'finishReason': 'STOP',
              },
            ],
            'usageMetadata': {'promptTokenCount': 7, 'candidatesTokenCount': 2},
          },
        ]);
      });
      final provider = GeminiProvider(apiKey: 'k', httpClient: mock);

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

    test('émet un functionCall reçu en un bloc', () async {
      final mock = MockClient.streaming((req, body) async {
        return sse([
          {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'functionCall': {
                        'name': 'getMeteo',
                        'args': {'ville': 'Douala'},
                      },
                    },
                  ],
                },
                'finishReason': 'STOP',
              },
            ],
          },
        ]);
      });
      final provider = GeminiProvider(apiKey: 'k', httpClient: mock);

      final events = await provider.generateStream([
        Message.user('météo ?'),
      ]).toList();

      final call = events.whereType<ToolCallDelta>().single.call;
      expect(call.name, 'getMeteo');
      expect(call.arguments, {'ville': 'Douala'});

      final done = events.whereType<StreamDone>().single;
      expect(done.response.toolCalls.single.name, 'getMeteo');
    });
  });
}

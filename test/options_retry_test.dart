import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llm_sdk/llm_sdk.dart';
import 'package:test/test.dart';

/// Réponse OpenAI minimale valide (statut 200).
http.Response _openAiOk() => http.Response(
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

http.Response _claudeOk() => http.Response(
  jsonEncode({
    'content': [
      {'type': 'text', 'text': 'ok'},
    ],
    'stop_reason': 'end_turn',
  }),
  200,
);

http.Response _geminiOk() => http.Response(
  jsonEncode({
    'candidates': [
      {
        'content': {
          'parts': [
            {'text': 'ok'},
          ],
        },
        'finishReason': 'STOP',
      },
    ],
  }),
  200,
);

void main() {
  group('GenerationOptions — mapping par provider', () {
    const options = GenerationOptions(
      temperature: 0.2,
      topP: 0.9,
      stopSequences: ['STOP'],
    );

    test('Claude : temperature / top_p / stop_sequences', () async {
      late Map<String, dynamic> body;
      final mock = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return _claudeOk();
      });
      final provider = ClaudeProvider(apiKey: 'k', httpClient: mock);

      await provider.generate([Message.user('hi')], options: options);

      expect(body['temperature'], 0.2);
      expect(body['top_p'], 0.9);
      expect(body['stop_sequences'], ['STOP']);
    });

    test('OpenAI : temperature / top_p / stop', () async {
      late Map<String, dynamic> body;
      final mock = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return _openAiOk();
      });
      final provider = OpenAIProvider(apiKey: 'k', httpClient: mock);

      await provider.generate([Message.user('hi')], options: options);

      expect(body['temperature'], 0.2);
      expect(body['top_p'], 0.9);
      expect(body['stop'], ['STOP']);
    });

    test('Gemini : regroupe sous generationConfig', () async {
      late Map<String, dynamic> body;
      final mock = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return _geminiOk();
      });
      final provider = GeminiProvider(apiKey: 'k', httpClient: mock);

      await provider.generate([Message.user('hi')], options: options);

      final config = body['generationConfig'] as Map<String, dynamic>;
      expect(config['temperature'], 0.2);
      expect(config['topP'], 0.9);
      expect(config['stopSequences'], ['STOP']);
    });

    test('sans options : aucun réglage d\'échantillonnage envoyé', () async {
      late Map<String, dynamic> body;
      final mock = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return _openAiOk();
      });
      final provider = OpenAIProvider(apiKey: 'k', httpClient: mock);

      await provider.generate([Message.user('hi')]);

      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
      expect(body.containsKey('stop'), isFalse);
    });
  });

  group('RetryPolicy — backoff', () {
    test('délais exponentiels', () {
      const policy = RetryPolicy(
        initialDelay: Duration(milliseconds: 100),
        backoffFactor: 2.0,
      );
      expect(policy.delayFor(0), const Duration(milliseconds: 100));
      expect(policy.delayFor(1), const Duration(milliseconds: 200));
      expect(policy.delayFor(2), const Duration(milliseconds: 400));
    });
  });

  group('Retries au niveau provider (chemin generate)', () {
    // initialDelay nul → tests instantanés.
    const fast = RetryPolicy(maxRetries: 2, initialDelay: Duration.zero);

    test('rejoue un 503 transitoire puis réussit', () async {
      var calls = 0;
      final mock = MockClient((req) async {
        calls++;
        if (calls < 3) return http.Response('overloaded', 503);
        return _openAiOk();
      });
      final provider = OpenAIProvider(
        apiKey: 'k',
        retry: fast,
        httpClient: mock,
      );

      final res = await provider.generate([Message.user('hi')]);

      expect(res.text, 'ok');
      expect(calls, 3); // 1 essai + 2 retries
    });

    test('épuise les retries puis lève LlmException', () async {
      var calls = 0;
      final mock = MockClient((req) async {
        calls++;
        return http.Response('overloaded', 503);
      });
      final provider = OpenAIProvider(
        apiKey: 'k',
        retry: fast,
        httpClient: mock,
      );

      await expectLater(
        provider.generate([Message.user('hi')]),
        throwsA(isA<LlmException>()),
      );
      expect(calls, 3); // 1 essai + 2 retries, tous en échec
    });

    test('ne rejoue PAS un 400 non transitoire', () async {
      var calls = 0;
      final mock = MockClient((req) async {
        calls++;
        return http.Response('bad request', 400);
      });
      final provider = OpenAIProvider(
        apiKey: 'k',
        retry: fast,
        httpClient: mock,
      );

      await expectLater(
        provider.generate([Message.user('hi')]),
        throwsA(isA<LlmException>()),
      );
      expect(calls, 1); // aucun retry sur un 4xx client
    });

    test('RetryPolicy.none : un seul essai', () async {
      var calls = 0;
      final mock = MockClient((req) async {
        calls++;
        return http.Response('overloaded', 503);
      });
      final provider = OpenAIProvider(
        apiKey: 'k',
        retry: RetryPolicy.none,
        httpClient: mock,
      );

      await expectLater(
        provider.generate([Message.user('hi')]),
        throwsA(isA<LlmException>()),
      );
      expect(calls, 1);
    });

    test('rejoue une coupure réseau (ClientException)', () async {
      var calls = 0;
      final mock = MockClient((req) async {
        calls++;
        if (calls < 2) throw http.ClientException('connexion coupée');
        return _openAiOk();
      });
      final provider = OpenAIProvider(
        apiKey: 'k',
        retry: fast,
        httpClient: mock,
      );

      final res = await provider.generate([Message.user('hi')]);

      expect(res.text, 'ok');
      expect(calls, 2);
    });
  });

  group('sendWithRetry — timeout', () {
    test('lève TimeoutException si la requête dépasse le délai', () async {
      const policy = RetryPolicy(
        maxRetries: 0,
        timeout: Duration(milliseconds: 20),
      );

      await expectLater(
        sendWithRetry(() async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return http.Response('trop tard', 200);
        }, policy),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}

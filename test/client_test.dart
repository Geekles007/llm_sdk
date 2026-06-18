import 'package:llm_sdk/llm_sdk.dart';
import 'package:test/test.dart';

/// Provider scripté : renvoie des réponses prédéfinies, sans réseau.
/// Permet de valider toute la logique du [LlmClient] de façon isolée.
final class FakeProvider implements LlmProvider {
  final List<LlmResponse> scriptedResponses;
  int _index = 0;

  /// Capture les conversations reçues à chaque appel de [generate].
  final List<List<Message>> receivedConversations = [];

  /// Capture les `forceTool` reçus.
  final List<String?> receivedForceTools = [];

  FakeProvider(this.scriptedResponses);

  @override
  Future<LlmResponse> generate(
    List<Message> messages, {
    List<Tool> tools = const [],
    String? forceTool,
  }) async {
    receivedConversations.add(List.of(messages));
    receivedForceTools.add(forceTool);
    return scriptedResponses[_index++];
  }

  @override
  Stream<LlmStreamEvent> generateStream(
    List<Message> messages, {
    List<Tool> tools = const [],
  }) async* {
    for (final r in scriptedResponses) {
      for (final part in r.message.parts) {
        if (part is TextPart) yield TextDelta(part.text);
      }
      yield StreamDone(r);
    }
  }
}

void main() {
  group('LlmClient.generate — boucle d\'outils', () {
    test('renvoie directement une réponse sans appel d\'outil', () async {
      final provider = FakeProvider([
        LlmResponse(Message.assistant('Bonjour !')),
      ]);
      final client = LlmClient(provider);

      final res = await client.generate([Message.user('Salut')]);

      expect(res.text, 'Bonjour !');
      expect(provider.receivedConversations, hasLength(1));
    });

    test('exécute un outil puis reboucle vers la réponse finale', () async {
      final provider = FakeProvider([
        // Tour 1 : le modèle demande l'outil.
        LlmResponse(
          Message(Role.assistant, [
            ToolCallPart('call_1', 'getMeteo', {'ville': 'Douala'}),
          ]),
        ),
        // Tour 2 : réponse finale.
        LlmResponse(Message.assistant('Il fait 29 °C à Douala.')),
      ]);
      final client = LlmClient(provider);

      var toolRan = false;
      final meteo = Tool(
        name: 'getMeteo',
        description: 'Donne la météo',
        parameters: {'type': 'object'},
        run: (args) async {
          toolRan = true;
          expect(args['ville'], 'Douala');
          return '29 °C';
        },
      );

      final res = await client.generate(
        [Message.user('Météo Douala ?')],
        tools: [meteo],
      );

      expect(toolRan, isTrue);
      expect(res.text, 'Il fait 29 °C à Douala.');
      // 1er appel : user seul. 2e appel : user + assistant(tool_use) + tool_result.
      expect(provider.receivedConversations, hasLength(2));
      expect(provider.receivedConversations[1], hasLength(3));
      expect(provider.receivedConversations[1].last.role, Role.tool);
    });

    test('lève si le modèle demande un outil inconnu', () async {
      final provider = FakeProvider([
        LlmResponse(
          Message(Role.assistant, [ToolCallPart('call_1', 'inconnu', {})]),
        ),
      ]);
      final client = LlmClient(provider);

      expect(
        () => client.generate([Message.user('?')], tools: []),
        throwsStateError,
      );
    });

    test('lève si maxSteps est atteint sans réponse finale', () async {
      final loopingCall = LlmResponse(
        Message(Role.assistant, [ToolCallPart('c', 'boucle', {})]),
      );
      final provider = FakeProvider(List.filled(5, loopingCall));
      final client = LlmClient(provider, maxSteps: 2);

      final tool = Tool(
        name: 'boucle',
        description: '',
        parameters: {},
        run: (_) async => 'encore',
      );

      expect(
        () => client.generate([Message.user('go')], tools: [tool]),
        throwsStateError,
      );
    });
  });

  group('LlmClient.generateObject', () {
    test('force l\'outil-formulaire et reconstruit l\'objet typé', () async {
      final provider = FakeProvider([
        LlmResponse(
          Message(Role.assistant, [
            ToolCallPart('call_1', 'respond', {
              'client': 'Metchera',
              'montant': 1250.0,
            }),
          ]),
        ),
      ]);
      final client = LlmClient(provider);

      final result = await client
          .generateObject<({String client, double montant})>(
            [Message.user('Facture Metchera 1250€')],
            schema: {'type': 'object'},
            fromJson: (json) => (
              client: json['client'] as String,
              montant: (json['montant'] as num).toDouble(),
            ),
          );

      expect(result.client, 'Metchera');
      expect(result.montant, 1250.0);
      // Vérifie qu'on a bien forcé l'outil.
      expect(provider.receivedForceTools.single, 'respond');
    });
  });

  group('LlmClient.streamText', () {
    test('ne laisse passer que les fragments de texte', () async {
      final provider = FakeProvider([
        LlmResponse(Message.assistant('Hello world')),
      ]);
      final client = LlmClient(provider);

      final chunks = await client.streamText([Message.user('hi')]).toList();

      expect(chunks, ['Hello world']);
    });
  });
}

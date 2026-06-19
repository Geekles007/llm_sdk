// Démo pour le GIF du streaming.
//
// Exécute RÉELLEMENT `LlmClient.streamText` — la boucle de rendu mot à mot
// est du vrai code du SDK. Seul le provider est local (pas de réseau, pas de
// clé API) pour que le GIF soit reproductible : il émet des TextDelta avec un
// petit délai, exactement comme le ferait un vrai provider en SSE.
import 'dart:io';

import 'package:llm_sdk/llm_sdk.dart';

Future<void> main() async {
  final client = LlmClient(_TypewriterProvider());

  await for (final mot in client.streamText([
    Message.user('Raconte-moi une blague de développeur.'),
  ])) {
    // Affiche chaque fragment dès qu'il arrive : effet machine à écrire.
    stdout.write(mot);
  }
  stdout.writeln();
}

/// Provider local qui rejoue une réponse mot à mot, avec un délai réaliste.
final class _TypewriterProvider implements LlmProvider {
  static const _reply =
      'Pourquoi les développeurs préfèrent le noir ? '
      'Parce que la lumière attire les bugs. 🐛';

  @override
  Stream<LlmStreamEvent> generateStream(
    List<Message> messages, {
    List<Tool> tools = const [],
  }) async* {
    for (final word in _reply.split(' ')) {
      await Future<void>.delayed(const Duration(milliseconds: 90));
      yield TextDelta('$word ');
    }
    yield StreamDone(
      LlmResponse(Message.assistant(_reply), finishReason: FinishReason.stop),
    );
  }

  @override
  Future<LlmResponse> generate(
    List<Message> messages, {
    List<Tool> tools = const [],
    String? forceTool,
  }) async =>
      LlmResponse(Message.assistant(_reply));
}

import 'types.dart';

/// Le contrat que chaque provider (Claude, OpenAI, Gemini) implémente.
///
/// Le contrat se résume à **deux méthodes**. Toute la logique d'usage —
/// boucle d'outils, `streamText`, `generateObject` — est construite une
/// seule fois dans le [LlmClient] par-dessus ce contrat. Les providers
/// restent minces : ils ne font que traduire vers/depuis leur dialecte.
abstract interface class LlmProvider {
  /// Un aller-retour simple (chemin `Future`).
  ///
  /// [forceTool], s'il est fourni, contraint le modèle à appeler l'outil
  /// portant ce nom — base des sorties structurées.
  Future<LlmResponse> generate(
    List<Message> messages, {
    List<Tool> tools = const [],
    String? forceTool,
  });

  /// La version streamée : émet des [LlmStreamEvent] au fil de la réponse,
  /// et termine par un [StreamDone] portant la réponse assemblée.
  Stream<LlmStreamEvent> generateStream(
    List<Message> messages, {
    List<Tool> tools = const [],
  });
}

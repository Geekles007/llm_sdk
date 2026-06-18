/// Types qui circulent dans le SDK, indépendants de tout provider.
///
/// Ce fichier est le vocabulaire commun : chaque adaptateur traduit
/// vers/depuis ces types, et le [LlmClient] ne manipule qu'eux.
library;

/// Le rôle d'un message dans la conversation.
enum Role { system, user, assistant, tool }

/// Un morceau de contenu d'un [Message].
///
/// Un message est une liste de [Part] : du texte, une demande d'appel
/// d'outil, ou un résultat d'outil. Découper ainsi évite un refactor le
/// jour où l'on mélange texte et outils dans un même tour.
sealed class Part {
  const Part();
}

/// Du texte brut.
final class TextPart extends Part {
  final String text;
  const TextPart(this.text);
}

/// Une demande de l'assistant d'exécuter un outil.
final class ToolCallPart extends Part {
  /// Identifiant de l'appel, à recoller sur le [ToolResultPart] correspondant.
  final String id;

  /// Nom de l'outil à exécuter.
  final String name;

  /// Arguments fournis par le modèle (déjà décodés en map).
  final Map<String, dynamic> arguments;

  const ToolCallPart(this.id, this.name, this.arguments);
}

/// Le résultat d'un outil, réinjecté dans la conversation.
final class ToolResultPart extends Part {
  /// Identifiant de l'appel d'outil ([ToolCallPart.id]) auquel ce résultat répond.
  final String callId;

  /// Sortie de l'outil, sérialisée en texte.
  final String result;

  const ToolResultPart(this.callId, this.result);
}

/// Un message de la conversation.
final class Message {
  final Role role;
  final List<Part> parts;

  const Message(this.role, this.parts);

  /// Raccourci : message système en texte.
  factory Message.system(String text) => Message(Role.system, [TextPart(text)]);

  /// Raccourci : message utilisateur en texte.
  factory Message.user(String text) => Message(Role.user, [TextPart(text)]);

  /// Raccourci : message assistant en texte.
  factory Message.assistant(String text) =>
      Message(Role.assistant, [TextPart(text)]);
}

/// Un outil que le modèle peut demander d'exécuter.
final class Tool {
  final String name;
  final String description;

  /// Schéma JSON des paramètres (manuel — pas de réflexion runtime en Flutter).
  final Map<String, dynamic> parameters;

  /// Fonction réellement exécutée quand le modèle appelle l'outil.
  final Future<String> Function(Map<String, dynamic> args) run;

  const Tool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.run,
  });
}

/// Pourquoi le modèle a arrêté de générer.
///
/// Normalisé : chaque provider mappe son propre vocabulaire dessus.
enum FinishReason {
  /// Fin naturelle de la réponse.
  stop,

  /// Limite de tokens atteinte.
  length,

  /// Le modèle a demandé un ou plusieurs outils.
  toolUse,

  /// Filtré par la modération du provider.
  contentFilter,

  /// Raison non reconnue.
  unknown,
}

/// Comptage de tokens, quand le provider le fournit.
final class Usage {
  final int inputTokens;
  final int outputTokens;

  const Usage({required this.inputTokens, required this.outputTokens});

  int get totalTokens => inputTokens + outputTokens;
}

/// Enveloppe de réponse.
///
/// L'enveloppe permet d'ajouter des métadonnées ([usage], [finishReason])
/// sans casser la signature de `generate`.
final class LlmResponse {
  final Message message;
  final FinishReason? finishReason;
  final Usage? usage;

  const LlmResponse(this.message, {this.finishReason, this.usage});

  /// Le texte concaténé de tous les [TextPart] de la réponse.
  String get text =>
      message.parts.whereType<TextPart>().map((p) => p.text).join();

  /// Les appels d'outils demandés par le modèle.
  List<ToolCallPart> get toolCalls =>
      message.parts.whereType<ToolCallPart>().toList();
}

/// Événement de streaming typé.
sealed class LlmStreamEvent {
  const LlmStreamEvent();
}

/// Un fragment de texte arrivé en streaming.
final class TextDelta extends LlmStreamEvent {
  final String text;
  const TextDelta(this.text);
}

/// Un appel d'outil complet, une fois ses arguments entièrement reçus.
final class ToolCallDelta extends LlmStreamEvent {
  final ToolCallPart call;
  const ToolCallDelta(this.call);
}

/// Fin du flux : porte la réponse assemblée complète.
final class StreamDone extends LlmStreamEvent {
  final LlmResponse response;
  const StreamDone(this.response);
}

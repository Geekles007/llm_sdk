import 'provider.dart';
import 'types.dart';

/// La surface publique du SDK.
///
/// On l'instancie avec un [LlmProvider] ; tout le reste de l'API est
/// agnostique du provider. Changer d'IA = changer le provider passé ici,
/// rien d'autre ne bouge.
final class LlmClient {
  final LlmProvider _provider;

  /// Nombre maximum d'allers-retours d'outils avant d'abandonner.
  /// Borne la boucle pour éviter un cycle infini.
  final int maxSteps;

  LlmClient(this._provider, {this.maxSteps = 5});

  /// Génère une réponse, en orchestrant automatiquement la boucle d'outils.
  ///
  /// Tant que le modèle demande des outils, on les exécute, on réinjecte
  /// leurs résultats, et on reboucle — jusqu'à une réponse finale ou
  /// [maxSteps]. [options] transmet les réglages d'échantillonnage au provider.
  Future<LlmResponse> generate(
    List<Message> messages, {
    List<Tool> tools = const [],
    GenerationOptions? options,
  }) async {
    final conversation = [...messages]; // copie modifiable

    for (var step = 0; step < maxSteps; step++) {
      final response = await _provider.generate(
        conversation,
        tools: tools,
        options: options,
      );
      final calls = response.toolCalls;

      if (calls.isEmpty) return response; // réponse finale → on sort

      conversation.add(response.message); // on garde la demande de l'assistant

      final results = <Part>[];
      for (final call in calls) {
        final tool = tools.firstWhere(
          (t) => t.name == call.name,
          orElse: () => throw StateError(
            'Le modèle a demandé un outil inconnu : ${call.name}',
          ),
        );
        final output = await tool.run(call.arguments);
        results.add(ToolResultPart(call.id, output));
      }
      conversation.add(Message(Role.tool, results)); // réinjecte et reboucle
    }
    throw StateError('maxSteps ($maxSteps) atteint sans réponse finale');
  }

  /// Convenance texte : génère et renvoie directement le texte final.
  Future<String> generateText(
    List<Message> messages, {
    List<Tool> tools = const [],
    GenerationOptions? options,
  }) async {
    final response = await generate(messages, tools: tools, options: options);
    return response.text;
  }

  /// Streaming de texte mot à mot (effet machine à écrire).
  ///
  /// Filtre le flux d'événements pour ne garder que les fragments de texte.
  /// Note v1 : streaming et outils ne cohabitent pas — n'utilise pas d'outils ici.
  Stream<String> streamText(
    List<Message> messages, {
    GenerationOptions? options,
  }) async* {
    await for (final event in _provider.generateStream(
      messages,
      options: options,
    )) {
      if (event is TextDelta) yield event.text;
    }
  }

  /// Le flux d'événements brut, pour qui veut aussi les appels d'outils
  /// ou la réponse finale assemblée.
  Stream<LlmStreamEvent> streamEvents(
    List<Message> messages, {
    List<Tool> tools = const [],
    GenerationOptions? options,
  }) {
    return _provider.generateStream(messages, tools: tools, options: options);
  }

  /// Sorties structurées : force le modèle à remplir un « formulaire » typé.
  ///
  /// Recycle le mécanisme d'outils : on déclare un outil dont le schéma est
  /// celui de l'objet voulu, on force son appel, et ses arguments *sont*
  /// l'objet. [fromJson] reconstruit l'objet Dart typé (pas de réflexion
  /// runtime en Flutter, donc schéma + désérialisation manuels).
  Future<T> generateObject<T>(
    List<Message> messages, {
    required Map<String, dynamic> schema,
    required T Function(Map<String, dynamic> json) fromJson,
    String description = 'Réponds en remplissant ce format.',
    GenerationOptions? options,
  }) async {
    const toolName = 'respond';
    final responseTool = Tool(
      name: toolName,
      description: description,
      parameters: schema,
      run: (args) async => '', // jamais exécuté : on capte ses arguments
    );

    final response = await _provider.generate(
      messages,
      tools: [responseTool],
      forceTool: toolName,
      options: options,
    );

    final calls = response.toolCalls;
    if (calls.isEmpty) {
      throw StateError(
        "Le modèle n'a pas rempli le formulaire structuré attendu.",
      );
    }
    return fromJson(calls.first.arguments); // les arguments SONT l'objet
  }
}

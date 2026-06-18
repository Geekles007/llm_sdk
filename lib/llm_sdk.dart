/// Une trousse à outils unifiée pour parler aux LLM depuis Dart / Flutter.
///
/// Multi-provider, streaming, tool calling et sorties structurées derrière
/// une seule interface. Changer d'IA = changer le provider passé au
/// [LlmClient].
library;

export 'src/client.dart';
export 'src/exceptions.dart';
export 'src/provider.dart';
export 'src/provider/claude.dart';
export 'src/provider/gemini.dart';
export 'src/provider/openai.dart';
export 'src/types.dart';

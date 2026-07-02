import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../exceptions.dart';
import '../provider.dart';
import '../retry.dart';
import '../types.dart';

/// Adaptateur pour l'API Generative Language de Google (Gemini).
///
/// De la traduction pure entre nos types et le dialecte de Gemini. Pièges
/// gérés ici, par contraste avec Claude / OpenAI :
/// - le rôle assistant s'appelle `model` ;
/// - `system` va dans `system_instruction` (champ top-level, clé propre) ;
/// - pas de rôle `tool` : les résultats voyagent dans un message `user` via
///   une part `functionResponse` ;
/// - **pas d'ID d'appel d'outil** : Gemini recolle appel et résultat par
///   *nom* de fonction. On mappe donc `ToolCallPart.id == name`, et on
///   ré-encode le résultat sous ce nom ;
/// - vocabulaire propre : `functionDeclarations`, `functionCall` (`args` =
///   map directe), `tool_config.function_calling_config.mode = ANY` pour
///   forcer un outil ;
/// - la clé API passe en en-tête `x-goog-api-key`.
final class GeminiProvider implements LlmProvider {
  final String apiKey;
  final String model;
  final int? maxTokens;
  final String baseUrl;

  /// Résilience réseau : retries (backoff) + timeout appliqués aux requêtes.
  final RetryPolicy retry;

  final http.Client _http;

  GeminiProvider({
    required this.apiKey,
    this.model = 'gemini-1.5-pro',
    this.maxTokens,
    this.baseUrl = 'https://generativelanguage.googleapis.com/v1beta',
    this.retry = const RetryPolicy(),
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  Uri _endpoint(String method, {bool sse = false}) =>
      Uri.parse('$baseUrl/models/$model:$method${sse ? '?alt=sse' : ''}');

  Map<String, String> get _headers => {
    'x-goog-api-key': apiKey,
    'content-type': 'application/json',
  };

  /// Libère le client HTTP interne.
  void close() => _http.close();

  // ---------------------------------------------------------------------------
  // Aller : encodage (nos types → dialecte Gemini)
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _buildBody(
    List<Message> messages, {
    List<Tool> tools = const [],
    String? forceTool,
    GenerationOptions? options,
  }) {
    final system = messages
        .where((m) => m.role == Role.system)
        .expand((m) => m.parts.whereType<TextPart>().map((p) => p.text))
        .join('\n');

    final contents = messages
        .where((m) => m.role != Role.system)
        .map(_encodeMessage)
        .toList();

    // Gemini regroupe max_tokens et l'échantillonnage sous `generationConfig`.
    final generationConfig = <String, dynamic>{
      if (maxTokens != null) 'maxOutputTokens': maxTokens,
      if (options?.temperature != null) 'temperature': options!.temperature,
      if (options?.topP != null) 'topP': options!.topP,
      if (options?.stopSequences != null)
        'stopSequences': options!.stopSequences,
    };

    return {
      'contents': contents,
      if (system.isNotEmpty)
        'system_instruction': {
          'parts': [
            {'text': system},
          ],
        },
      if (generationConfig.isNotEmpty) 'generationConfig': generationConfig,
      if (tools.isNotEmpty)
        'tools': [
          {'functionDeclarations': tools.map(_encodeTool).toList()},
        ],
      if (forceTool != null)
        'tool_config': {
          'function_calling_config': {
            'mode': 'ANY',
            'allowed_function_names': [forceTool],
          },
        },
    };
  }

  Map<String, dynamic> _encodeMessage(Message m) {
    // assistant → `model` ; user et tool (résultats) → `user`.
    final role = m.role == Role.assistant ? 'model' : 'user';
    return {'role': role, 'parts': m.parts.map(_encodePart).toList()};
  }

  Map<String, dynamic> _encodePart(Part p) => switch (p) {
    TextPart(:final text) => {'text': text},
    ToolCallPart(:final name, :final arguments) => {
      'functionCall': {'name': name, 'args': arguments},
    },
    // Gemini recolle par nom : `callId` porte le nom de la fonction.
    // La réponse doit être un objet → on emballe le résultat texte.
    ToolResultPart(:final callId, :final result) => {
      'functionResponse': {
        'name': callId,
        'response': {'result': result},
      },
    },
  };

  Map<String, dynamic> _encodeTool(Tool t) => {
    'name': t.name,
    'description': t.description,
    'parameters': t.parameters,
  };

  // ---------------------------------------------------------------------------
  // Retour : décodage non-streamé (dialecte Gemini → nos types)
  // ---------------------------------------------------------------------------

  @override
  Future<LlmResponse> generate(
    List<Message> messages, {
    List<Tool> tools = const [],
    String? forceTool,
    GenerationOptions? options,
  }) async {
    final body = jsonEncode(
      _buildBody(
        messages,
        tools: tools,
        forceTool: forceTool,
        options: options,
      ),
    );
    final res = await sendWithRetry(
      () => _http.post(
        _endpoint('generateContent'),
        headers: _headers,
        body: body,
      ),
      retry,
    );

    if (res.statusCode != 200) {
      throw LlmException(res.statusCode, res.body);
    }

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final candidate =
        (json['candidates'] as List).first as Map<String, dynamic>;
    final parts = _decodeParts(candidate['content'] as Map<String, dynamic>?);

    return LlmResponse(
      Message(Role.assistant, parts),
      finishReason: _mapFinishReason(candidate['finishReason'] as String?),
      usage: _decodeUsage(json['usageMetadata'] as Map<String, dynamic>?),
    );
  }

  List<Part> _decodeParts(Map<String, dynamic>? content) {
    if (content == null) return const [];
    final parts = <Part>[];
    for (final raw in (content['parts'] as List? ?? const [])) {
      final part = raw as Map<String, dynamic>;
      if (part['text'] != null) {
        parts.add(TextPart(part['text'] as String));
      } else if (part['functionCall'] != null) {
        final fc = part['functionCall'] as Map<String, dynamic>;
        final name = fc['name'] as String;
        final args =
            (fc['args'] as Map?)?.cast<String, dynamic>() ??
            <String, dynamic>{};
        // Pas d'id chez Gemini : on recolle par nom → id == name.
        parts.add(ToolCallPart(name, name, args));
      }
    }
    return parts;
  }

  Usage? _decodeUsage(Map<String, dynamic>? usage) {
    if (usage == null) return null;
    return Usage(
      inputTokens: (usage['promptTokenCount'] as int?) ?? 0,
      outputTokens: (usage['candidatesTokenCount'] as int?) ?? 0,
    );
  }

  FinishReason? _mapFinishReason(String? reason) => switch (reason) {
    'STOP' => FinishReason.stop,
    'MAX_TOKENS' => FinishReason.length,
    'SAFETY' ||
    'BLOCKLIST' ||
    'PROHIBITED_CONTENT' => FinishReason.contentFilter,
    null => null,
    _ => FinishReason.unknown,
  };

  // ---------------------------------------------------------------------------
  // Streaming SSE (dialecte Gemini → flux de nos LlmStreamEvent)
  // ---------------------------------------------------------------------------

  @override
  Stream<LlmStreamEvent> generateStream(
    List<Message> messages, {
    List<Tool> tools = const [],
    GenerationOptions? options,
  }) async* {
    final request =
        http.Request('POST', _endpoint('streamGenerateContent', sse: true))
          ..headers.addAll(_headers)
          ..body = jsonEncode(
            _buildBody(messages, tools: tools, options: options),
          );

    // Timeout de connexion seulement : rejouer un flux entamé n'est pas sûr.
    final response = await _http.send(request).timeout(retry.timeout);

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw LlmException(response.statusCode, body);
    }

    final textBuffer = StringBuffer();
    final toolCalls = <ToolCallPart>[];
    var inputTokens = 0;
    var outputTokens = 0;
    FinishReason? finishReason;

    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;

      final chunk = jsonDecode(payload) as Map<String, dynamic>;

      final usage = chunk['usageMetadata'] as Map<String, dynamic>?;
      if (usage != null) {
        inputTokens = (usage['promptTokenCount'] as int?) ?? inputTokens;
        outputTokens = (usage['candidatesTokenCount'] as int?) ?? outputTokens;
      }

      final candidates = chunk['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) continue;
      final candidate = candidates.first as Map<String, dynamic>;

      finishReason =
          _mapFinishReason(candidate['finishReason'] as String?) ??
          finishReason;

      // Gemini envoie chaque part complète (texte incrémental, functionCall
      // d'un bloc) : pas d'assemblage d'arguments partiels à faire.
      for (final part in _decodeParts(
        candidate['content'] as Map<String, dynamic>?,
      )) {
        switch (part) {
          case TextPart(:final text):
            textBuffer.write(text);
            yield TextDelta(text);
          case ToolCallPart():
            toolCalls.add(part);
            yield ToolCallDelta(part);
          case ToolResultPart():
            break; // le modèle n'en émet pas
        }
      }
    }

    final parts = <Part>[
      if (textBuffer.isNotEmpty) TextPart(textBuffer.toString()),
      ...toolCalls,
    ];

    yield StreamDone(
      LlmResponse(
        Message(Role.assistant, parts),
        finishReason: finishReason,
        usage: Usage(inputTokens: inputTokens, outputTokens: outputTokens),
      ),
    );
  }
}

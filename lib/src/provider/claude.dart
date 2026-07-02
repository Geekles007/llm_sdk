import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../exceptions.dart';
import '../provider.dart';
import '../retry.dart';
import '../types.dart';

/// Adaptateur pour l'API Messages d'Anthropic (Claude).
///
/// De la traduction pure entre nos types et le dialecte d'Anthropic, dans
/// les deux sens. Particularités gérées ici :
/// - `system` est un champ top-level séparé (pas un message) ;
/// - pas de rôle `tool` : les résultats d'outils voyagent dans un message
///   `user` via des blocs `tool_result` ;
/// - vocabulaire propre : `input_schema`, bloc `tool_use` avec `input` ;
/// - `max_tokens` est obligatoire.
final class ClaudeProvider implements LlmProvider {
  final String apiKey;
  final String model;
  final int maxTokens;

  /// Résilience réseau : retries (backoff) + timeout appliqués aux requêtes.
  final RetryPolicy retry;

  final http.Client _http;

  ClaudeProvider({
    required this.apiKey,
    this.model = 'claude-opus-4-8',
    this.maxTokens = 1024,
    this.retry = const RetryPolicy(),
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  static const _endpoint = 'https://api.anthropic.com/v1/messages';

  Map<String, String> get _headers => {
    'x-api-key': apiKey,
    'anthropic-version': '2023-06-01',
    'content-type': 'application/json',
  };

  /// Libère le client HTTP interne. À appeler quand le provider n'est plus utilisé.
  void close() => _http.close();

  // ---------------------------------------------------------------------------
  // Aller : encodage (nos types → dialecte Anthropic)
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _buildBody(
    List<Message> messages, {
    List<Tool> tools = const [],
    String? forceTool,
    GenerationOptions? options,
    bool stream = false,
  }) {
    final system = messages
        .where((m) => m.role == Role.system)
        .expand((m) => m.parts.whereType<TextPart>().map((p) => p.text))
        .join('\n');

    final apiMessages = messages
        .where((m) => m.role != Role.system)
        .map(_encodeMessage)
        .toList();

    return {
      'model': model,
      'max_tokens': maxTokens,
      'messages': apiMessages,
      if (system.isNotEmpty) 'system': system,
      if (stream) 'stream': true,
      if (tools.isNotEmpty) 'tools': tools.map(_encodeTool).toList(),
      if (forceTool != null) 'tool_choice': {'type': 'tool', 'name': forceTool},
      if (options?.temperature != null) 'temperature': options!.temperature,
      if (options?.topP != null) 'top_p': options!.topP,
      if (options?.stopSequences != null)
        'stop_sequences': options!.stopSequences,
    };
  }

  Map<String, dynamic> _encodeMessage(Message m) {
    // Anthropic n'a pas de rôle `tool` : les résultats d'outils sont des
    // messages `user` contenant des blocs `tool_result`.
    final apiRole = m.role == Role.assistant ? 'assistant' : 'user';
    return {'role': apiRole, 'content': m.parts.map(_encodePart).toList()};
  }

  Map<String, dynamic> _encodePart(Part p) => switch (p) {
    TextPart(:final text) => {'type': 'text', 'text': text},
    ToolCallPart(:final id, :final name, :final arguments) => {
      'type': 'tool_use',
      'id': id,
      'name': name,
      'input': arguments,
    },
    ToolResultPart(:final callId, :final result) => {
      'type': 'tool_result',
      'tool_use_id': callId,
      'content': result,
    },
  };

  Map<String, dynamic> _encodeTool(Tool t) => {
    'name': t.name,
    'description': t.description,
    'input_schema': t.parameters,
  };

  // ---------------------------------------------------------------------------
  // Retour : décodage non-streamé (dialecte Anthropic → nos types)
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
      () => _http.post(Uri.parse(_endpoint), headers: _headers, body: body),
      retry,
    );

    if (res.statusCode != 200) {
      throw LlmException(res.statusCode, res.body);
    }

    final json = jsonDecode(res.body) as Map<String, dynamic>;

    final parts = (json['content'] as List)
        .map((block) => _decodePart(block as Map<String, dynamic>))
        .whereType<Part>() // filtre les blocs ignorés (thinking…)
        .toList();

    return LlmResponse(
      Message(Role.assistant, parts),
      finishReason: _mapStopReason(json['stop_reason'] as String?),
      usage: _decodeUsage(json['usage'] as Map<String, dynamic>?),
    );
  }

  /// Décode un bloc de contenu. Renvoie `null` pour les blocs qu'on ignore
  /// volontairement (ex. `thinking`) plutôt que de crasher.
  Part? _decodePart(Map<String, dynamic> block) => switch (block['type']) {
    'text' => TextPart(block['text'] as String),
    'tool_use' => ToolCallPart(
      block['id'] as String,
      block['name'] as String,
      (block['input'] as Map).cast<String, dynamic>(),
    ),
    'thinking' || 'redacted_thinking' => null,
    _ => null, // données externes : on tolère l'inconnu
  };

  Usage? _decodeUsage(Map<String, dynamic>? usage) {
    if (usage == null) return null;
    return Usage(
      inputTokens: (usage['input_tokens'] as int?) ?? 0,
      outputTokens: (usage['output_tokens'] as int?) ?? 0,
    );
  }

  FinishReason? _mapStopReason(String? reason) => switch (reason) {
    'end_turn' || 'stop_sequence' => FinishReason.stop,
    'max_tokens' => FinishReason.length,
    'tool_use' => FinishReason.toolUse,
    null => null,
    _ => FinishReason.unknown,
  };

  // ---------------------------------------------------------------------------
  // Streaming SSE (dialecte Anthropic → flux de nos LlmStreamEvent)
  // ---------------------------------------------------------------------------

  @override
  Stream<LlmStreamEvent> generateStream(
    List<Message> messages, {
    List<Tool> tools = const [],
    GenerationOptions? options,
  }) async* {
    final request = http.Request('POST', Uri.parse(_endpoint))
      ..headers.addAll(_headers)
      ..body = jsonEncode(
        _buildBody(messages, tools: tools, options: options, stream: true),
      );

    // Timeout de connexion seulement : rejouer un flux entamé n'est pas sûr.
    final response = await _http.send(request).timeout(retry.timeout);

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw LlmException(response.statusCode, body);
    }

    // Accumulateurs pour assembler la réponse finale + les appels d'outils.
    final assembled = <int, _BlockBuilder>{};
    var inputTokens = 0;
    var outputTokens = 0;
    FinishReason? finishReason;

    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;

      final event = jsonDecode(payload) as Map<String, dynamic>;
      switch (event['type']) {
        case 'message_start':
          final usage =
              (event['message'] as Map<String, dynamic>?)?['usage']
                  as Map<String, dynamic>?;
          inputTokens = (usage?['input_tokens'] as int?) ?? 0;

        case 'content_block_start':
          final index = event['index'] as int;
          final block = event['content_block'] as Map<String, dynamic>;
          assembled[index] = _BlockBuilder.fromStart(block);

        case 'content_block_delta':
          final index = event['index'] as int;
          final delta = event['delta'] as Map<String, dynamic>;
          final builder = assembled[index];
          if (builder == null) continue;

          switch (delta['type']) {
            case 'text_delta':
              final text = delta['text'] as String;
              builder.text.write(text);
              yield TextDelta(text);
            case 'input_json_delta':
              builder.jsonBuffer.write(delta['partial_json'] as String);
          }

        case 'content_block_stop':
          final index = event['index'] as int;
          final builder = assembled[index];
          if (builder != null && builder.isToolCall) {
            final call = builder.buildToolCall();
            yield ToolCallDelta(call);
          }

        case 'message_delta':
          final delta = event['delta'] as Map<String, dynamic>?;
          finishReason = _mapStopReason(delta?['stop_reason'] as String?);
          final usage = event['usage'] as Map<String, dynamic>?;
          outputTokens = (usage?['output_tokens'] as int?) ?? outputTokens;

        case 'message_stop':
          // Fin du flux : on assemble la réponse complète.
          final parts = (assembled.keys.toList()..sort())
              .map((i) => assembled[i]!.toPart())
              .whereType<Part>()
              .toList();
          yield StreamDone(
            LlmResponse(
              Message(Role.assistant, parts),
              finishReason: finishReason,
              usage: Usage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
              ),
            ),
          );
      }
    }
  }
}

/// Assemble un bloc de contenu reçu en streaming, morceau par morceau.
final class _BlockBuilder {
  final String type;
  final String? toolId;
  final String? toolName;
  final StringBuffer text = StringBuffer();
  final StringBuffer jsonBuffer = StringBuffer();

  _BlockBuilder({required this.type, this.toolId, this.toolName});

  factory _BlockBuilder.fromStart(Map<String, dynamic> block) => _BlockBuilder(
    type: block['type'] as String,
    toolId: block['id'] as String?,
    toolName: block['name'] as String?,
  );

  bool get isToolCall => type == 'tool_use';

  ToolCallPart buildToolCall() {
    final raw = jsonBuffer.toString();
    final args = raw.isEmpty
        ? <String, dynamic>{}
        : (jsonDecode(raw) as Map).cast<String, dynamic>();
    return ToolCallPart(toolId ?? '', toolName ?? '', args);
  }

  /// Convertit le bloc assemblé en [Part], ou `null` si on l'ignore.
  Part? toPart() => switch (type) {
    'text' => TextPart(text.toString()),
    'tool_use' => buildToolCall(),
    _ => null,
  };
}

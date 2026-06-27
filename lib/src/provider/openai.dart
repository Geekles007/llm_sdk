import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../exceptions.dart';
import '../provider.dart';
import '../types.dart';

/// Adaptateur pour l'API Chat Completions d'OpenAI.
///
/// De la traduction pure entre nos types et le dialecte d'OpenAI. Pièges
/// gérés ici, par contraste avec Anthropic :
/// - `system` reste un message du tableau (`role: system`), pas un champ ;
/// - le rôle `tool` existe : **un message par résultat d'outil**, recollé
///   via `tool_call_id` (alors qu'Anthropic groupe dans un message `user`) ;
/// - les appels d'outils de l'assistant vivent dans `tool_calls`, et leurs
///   `arguments` sont une **chaîne JSON** (≠ map) à décoder ;
/// - vocabulaire propre : `{type: function, function: {...}}`, `tool_choice`
///   `{type: function, function: {name}}` ;
/// - `max_tokens` est optionnel.
final class OpenAIProvider implements LlmProvider {
  /// Clé d'API. Optionnelle : les serveurs locaux compatibles OpenAI
  /// (Ollama, LM Studio, llama.cpp, vLLM) l'ignorent — laisse la chaîne vide.
  final String apiKey;
  final String model;

  /// Optionnel chez OpenAI (`null` = laisser le modèle décider).
  final int? maxTokens;

  /// Racine de l'API. Pointe-la sur un endpoint local pour les modèles
  /// auto-hébergés, p. ex. `http://localhost:11434/v1` (Ollama).
  final String baseUrl;
  final http.Client _http;

  OpenAIProvider({
    this.apiKey = '',
    this.model = 'gpt-4o',
    this.maxTokens,
    this.baseUrl = 'https://api.openai.com/v1',
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  Uri get _endpoint => Uri.parse('$baseUrl/chat/completions');

  Map<String, String> get _headers => {
    // Omis quand vide : un endpoint local n'attend pas de Bearer.
    if (apiKey.isNotEmpty) 'authorization': 'Bearer $apiKey',
    'content-type': 'application/json',
  };

  /// Libère le client HTTP interne.
  void close() => _http.close();

  // ---------------------------------------------------------------------------
  // Aller : encodage (nos types → dialecte OpenAI)
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _buildBody(
    List<Message> messages, {
    List<Tool> tools = const [],
    String? forceTool,
    bool stream = false,
  }) {
    return {
      'model': model,
      // system reste dans le tableau messages chez OpenAI.
      'messages': messages.expand(_encodeMessage).toList(),
      if (maxTokens != null) 'max_tokens': maxTokens,
      if (stream) 'stream': true,
      if (stream) 'stream_options': {'include_usage': true},
      if (tools.isNotEmpty) 'tools': tools.map(_encodeTool).toList(),
      if (forceTool != null)
        'tool_choice': {
          'type': 'function',
          'function': {'name': forceTool},
        },
    };
  }

  /// Un [Message] peut produire **plusieurs** messages OpenAI : un message de
  /// rôle `tool` portant N résultats devient N messages `tool` distincts.
  Iterable<Map<String, dynamic>> _encodeMessage(Message m) {
    switch (m.role) {
      case Role.system:
        return [
          {'role': 'system', 'content': _textOf(m)},
        ];

      case Role.user:
        return [
          {'role': 'user', 'content': _textOf(m)},
        ];

      case Role.tool:
        // Un message OpenAI par résultat d'outil.
        return m.parts.whereType<ToolResultPart>().map(
          (p) => {
            'role': 'tool',
            'tool_call_id': p.callId,
            'content': p.result,
          },
        );

      case Role.assistant:
        final text = _textOf(m);
        final toolCalls = m.parts
            .whereType<ToolCallPart>()
            .map(
              (c) => {
                'id': c.id,
                'type': 'function',
                'function': {
                  'name': c.name,
                  'arguments': jsonEncode(
                    c.arguments,
                  ), // arguments = string JSON
                },
              },
            )
            .toList();

        return [
          {
            'role': 'assistant',
            // content null s'il n'y a que des appels d'outils.
            'content': text.isEmpty ? null : text,
            if (toolCalls.isNotEmpty) 'tool_calls': toolCalls,
          },
        ];
    }
  }

  String _textOf(Message m) =>
      m.parts.whereType<TextPart>().map((p) => p.text).join();

  Map<String, dynamic> _encodeTool(Tool t) => {
    'type': 'function',
    'function': {
      'name': t.name,
      'description': t.description,
      'parameters': t.parameters,
    },
  };

  // ---------------------------------------------------------------------------
  // Retour : décodage non-streamé (dialecte OpenAI → nos types)
  // ---------------------------------------------------------------------------

  @override
  Future<LlmResponse> generate(
    List<Message> messages, {
    List<Tool> tools = const [],
    String? forceTool,
  }) async {
    final res = await _http.post(
      _endpoint,
      headers: _headers,
      body: jsonEncode(
        _buildBody(messages, tools: tools, forceTool: forceTool),
      ),
    );

    if (res.statusCode != 200) {
      throw LlmException(res.statusCode, res.body);
    }

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final choice = (json['choices'] as List).first as Map<String, dynamic>;
    final message = choice['message'] as Map<String, dynamic>;

    return LlmResponse(
      Message(Role.assistant, _decodeParts(message)),
      finishReason: _mapFinishReason(choice['finish_reason'] as String?),
      usage: _decodeUsage(json['usage'] as Map<String, dynamic>?),
    );
  }

  List<Part> _decodeParts(Map<String, dynamic> message) {
    final parts = <Part>[];
    final content = message['content'] as String?;
    if (content != null && content.isNotEmpty) parts.add(TextPart(content));

    final toolCalls = message['tool_calls'] as List?;
    if (toolCalls != null) {
      for (final raw in toolCalls) {
        final call = raw as Map<String, dynamic>;
        final fn = call['function'] as Map<String, dynamic>;
        final argsStr = (fn['arguments'] as String?) ?? '';
        parts.add(
          ToolCallPart(
            call['id'] as String,
            fn['name'] as String,
            argsStr.isEmpty
                ? <String, dynamic>{}
                : (jsonDecode(argsStr) as Map).cast<String, dynamic>(),
          ),
        );
      }
    }
    return parts;
  }

  Usage? _decodeUsage(Map<String, dynamic>? usage) {
    if (usage == null) return null;
    return Usage(
      inputTokens: (usage['prompt_tokens'] as int?) ?? 0,
      outputTokens: (usage['completion_tokens'] as int?) ?? 0,
    );
  }

  FinishReason? _mapFinishReason(String? reason) => switch (reason) {
    'stop' => FinishReason.stop,
    'length' => FinishReason.length,
    'tool_calls' || 'function_call' => FinishReason.toolUse,
    'content_filter' => FinishReason.contentFilter,
    null => null,
    _ => FinishReason.unknown,
  };

  // ---------------------------------------------------------------------------
  // Streaming SSE (dialecte OpenAI → flux de nos LlmStreamEvent)
  // ---------------------------------------------------------------------------

  @override
  Stream<LlmStreamEvent> generateStream(
    List<Message> messages, {
    List<Tool> tools = const [],
  }) async* {
    final request = http.Request('POST', _endpoint)
      ..headers.addAll(_headers)
      ..body = jsonEncode(_buildBody(messages, tools: tools, stream: true));

    final response = await _http.send(request);

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw LlmException(response.statusCode, body);
    }

    final text = StringBuffer();
    // OpenAI streame les appels d'outils par `index`, sans marqueur de fin
    // par appel : on assemble tout et on émet à la clôture du flux.
    final toolCalls = <int, _ToolCallBuilder>{};
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
      if (payload == '[DONE]') break;

      final chunk = jsonDecode(payload) as Map<String, dynamic>;

      final usage = chunk['usage'] as Map<String, dynamic>?;
      if (usage != null) {
        inputTokens = (usage['prompt_tokens'] as int?) ?? inputTokens;
        outputTokens = (usage['completion_tokens'] as int?) ?? outputTokens;
      }

      final choices = chunk['choices'] as List?;
      if (choices == null || choices.isEmpty) continue;
      final choice = choices.first as Map<String, dynamic>;

      finishReason =
          _mapFinishReason(choice['finish_reason'] as String?) ?? finishReason;

      final delta = choice['delta'] as Map<String, dynamic>?;
      if (delta == null) continue;

      final content = delta['content'] as String?;
      if (content != null && content.isNotEmpty) {
        text.write(content);
        yield TextDelta(content);
      }

      final deltaCalls = delta['tool_calls'] as List?;
      if (deltaCalls != null) {
        for (final raw in deltaCalls) {
          final c = raw as Map<String, dynamic>;
          final index = c['index'] as int;
          final builder = toolCalls.putIfAbsent(index, _ToolCallBuilder.new);
          if (c['id'] != null) builder.id = c['id'] as String;
          final fn = c['function'] as Map<String, dynamic>?;
          if (fn != null) {
            if (fn['name'] != null) builder.name = fn['name'] as String;
            if (fn['arguments'] != null) {
              builder.arguments.write(fn['arguments'] as String);
            }
          }
        }
      }
    }

    // Clôture : on émet les appels d'outils assemblés, puis la réponse finale.
    final parts = <Part>[];
    if (text.isNotEmpty) parts.add(TextPart(text.toString()));
    for (final index in toolCalls.keys.toList()..sort()) {
      final call = toolCalls[index]!.build();
      parts.add(call);
      yield ToolCallDelta(call);
    }

    yield StreamDone(
      LlmResponse(
        Message(Role.assistant, parts),
        finishReason: finishReason,
        usage: Usage(inputTokens: inputTokens, outputTokens: outputTokens),
      ),
    );
  }
}

/// Assemble un appel d'outil reçu en streaming morceau par morceau.
final class _ToolCallBuilder {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();

  ToolCallPart build() {
    final raw = arguments.toString();
    final args = raw.isEmpty
        ? <String, dynamic>{}
        : (jsonDecode(raw) as Map).cast<String, dynamic>();
    return ToolCallPart(id, name, args);
  }
}

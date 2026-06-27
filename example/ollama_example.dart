// Demo: a 100% local model via Ollama, no API key and no cloud call.
//
// Prerequisites:
//   1) Install Ollama, then run a model:  ollama run llama3.2
//   2) Run:  dart run example/ollama_example.dart
//
// Any OpenAI-compatible server works the same way — just adapt `baseUrl`
// (LM Studio: http://localhost:1234/v1, llama.cpp / vLLM: their endpoint).

import 'dart:io';

import 'package:llm_sdk/llm_sdk.dart';

Future<void> main() async {
  // No API key: a local endpoint ignores it. Just change the baseUrl.
  final client = LlmClient(
    OpenAIProvider(baseUrl: 'http://localhost:11434/v1', model: 'llama3.2'),
  );

  // 1) Streaming: the text arrives word by word, from the local model.
  stdout.write('Joke: ');
  await for (final chunk in client.streamText([
    Message.user('Tell me a short joke.'),
  ])) {
    stdout.write(chunk);
  }
  stdout.writeln('\n');

  // 2) Tool calling: the SDK orchestrates the round-trip, even locally.
  //    (Requires a model that can call tools, e.g. llama3.2.)
  final weather = Tool(
    name: 'getWeather',
    description: 'Returns the current weather for a city',
    parameters: {
      'type': 'object',
      'properties': {
        'city': {'type': 'string'},
      },
      'required': ['city'],
    },
    run: (args) async => "It's 29 °C and humid in ${args['city']}.",
  );

  final response = await client.generate(
    [Message.user('What is the weather in Douala?')],
    tools: [weather],
  );
  stdout.writeln('Weather: ${response.text}');
}

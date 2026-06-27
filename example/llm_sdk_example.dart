// Demo: the 4 building blocks of the SDK on Claude.
//
// Run with:  dart run example/llm_sdk_example.dart
// (requires the ANTHROPIC_API_KEY environment variable)

import 'dart:io';

import 'package:llm_sdk/llm_sdk.dart';

Future<void> main() async {
  final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
  if (apiKey == null) {
    stderr.writeln('Set ANTHROPIC_API_KEY to run the demo.');
    exit(1);
  }

  // Pick the brain. Switching AI = changing this one line.
  final client = LlmClient(ClaudeProvider(apiKey: apiKey));

  // 1) Streaming: the text arrives word by word.
  stdout.write('Joke: ');
  await for (final chunk in client.streamText([
    Message.user('Tell me a short joke.'),
  ])) {
    stdout.write(chunk);
  }
  stdout.writeln('\n');

  // 2) Tool calling: the SDK orchestrates the round-trip on its own.
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
  stdout.writeln('Weather: ${response.text}\n');

  // 3) Structured outputs: fill a typed form.
  final invoice = await client.generateObject<Invoice>(
    [Message.user('Invoice issued on March 3, 2026 for Metchera, 1,250 EUR.')],
    schema: {
      'type': 'object',
      'properties': {
        'client': {'type': 'string'},
        'amount': {'type': 'number'},
        'date': {'type': 'string', 'description': 'ISO 8601'},
      },
      'required': ['client', 'amount', 'date'],
    },
    fromJson: Invoice.fromJson,
  );
  stdout.writeln(
    'Invoice: ${invoice.client} — ${invoice.amount} EUR — '
    '${invoice.date.toIso8601String()}',
  );
}

class Invoice {
  final String client;
  final double amount;
  final DateTime date;

  Invoice({required this.client, required this.amount, required this.date});

  factory Invoice.fromJson(Map<String, dynamic> json) => Invoice(
    client: json['client'] as String,
    amount: (json['amount'] as num).toDouble(),
    date: DateTime.parse(json['date'] as String),
  );
}

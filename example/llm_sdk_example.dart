// Démo : les 4 briques du SDK sur Claude.
//
// Lance avec :  dart run example/llm_sdk_example.dart
// (nécessite la variable d'environnement ANTHROPIC_API_KEY)

import 'dart:io';

import 'package:llm_sdk/llm_sdk.dart';

Future<void> main() async {
  final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
  if (apiKey == null) {
    stderr.writeln('Définis ANTHROPIC_API_KEY pour lancer la démo.');
    exit(1);
  }

  // On choisit le cerveau. Changer d'IA = changer cette ligne.
  final client = LlmClient(ClaudeProvider(apiKey: apiKey));

  // 1) Streaming : le texte arrive mot à mot.
  stdout.write('Blague : ');
  await for (final chunk in client.streamText([
    Message.user('Raconte-moi une blague courte.'),
  ])) {
    stdout.write(chunk);
  }
  stdout.writeln('\n');

  // 2) Tool calling : le SDK orchestre l'aller-retour tout seul.
  final meteo = Tool(
    name: 'getMeteo',
    description: "Donne la météo actuelle d'une ville",
    parameters: {
      'type': 'object',
      'properties': {
        'ville': {'type': 'string'},
      },
      'required': ['ville'],
    },
    run: (args) async => 'Il fait 29 °C et humide à ${args['ville']}.',
  );

  final reponse = await client.generate(
    [Message.user('Quel temps fait-il à Douala ?')],
    tools: [meteo],
  );
  stdout.writeln('Météo : ${reponse.text}\n');

  // 3) Sorties structurées : on remplit un formulaire typé.
  final facture = await client.generateObject<Facture>(
    [Message.user('Facture émise le 3 mars 2026 pour Metchera, 1 250 € TTC.')],
    schema: {
      'type': 'object',
      'properties': {
        'client': {'type': 'string'},
        'montant': {'type': 'number'},
        'date': {'type': 'string', 'description': 'ISO 8601'},
      },
      'required': ['client', 'montant', 'date'],
    },
    fromJson: Facture.fromJson,
  );
  stdout.writeln(
    'Facture : ${facture.client} — ${facture.montant} € — '
    '${facture.date.toIso8601String()}',
  );
}

class Facture {
  final String client;
  final double montant;
  final DateTime date;

  Facture({required this.client, required this.montant, required this.date});

  factory Facture.fromJson(Map<String, dynamic> json) => Facture(
    client: json['client'] as String,
    montant: (json['montant'] as num).toDouble(),
    date: DateTime.parse(json['date'] as String),
  );
}

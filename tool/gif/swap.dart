import 'package:llm_sdk/llm_sdk.dart';

Future<void> main() async {
  // 👇 La SEULE ligne à changer pour passer d'une IA à l'autre :
  final client = LlmClient(ClaudeProvider(apiKey: key));

  // Tout le reste est identique, quel que soit le provider :
  await for (final mot in client.streamText([
    Message.user('Raconte-moi une blague'),
  ])) {
    stdout.write(mot); // streaming, mot à mot
  }

  final facture = await client.generateObject<Facture>(
    [Message.user('Facture Metchera, 1 250 € TTC')],
    schema: factureSchema,
    fromJson: Facture.fromJson, // sortie typée, pas de texte à parser
  );
}

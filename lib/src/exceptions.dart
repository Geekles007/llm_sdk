/// Erreurs du SDK.
library;

/// Erreur renvoyée quand un provider répond avec un statut HTTP non-200,
/// ou qu'une réponse ne peut pas être interprétée.
final class LlmException implements Exception {
  /// Code HTTP renvoyé par le provider (0 si l'erreur n'est pas réseau).
  final int statusCode;

  /// Corps brut de la réponse, ou message d'erreur.
  final String body;

  const LlmException(this.statusCode, this.body);

  @override
  String toString() => 'LlmException($statusCode): $body';
}

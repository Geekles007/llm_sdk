/// Résilience réseau : retries avec backoff exponentiel + timeout.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

/// Politique de nouvelle tentative appliquée aux appels HTTP d'un provider.
///
/// Le chemin non-streamé (`generate`) rejoue la requête sur les erreurs
/// transitoires — statuts [retryStatusCodes] (429, 5xx…), timeouts et coupures
/// réseau — en espaçant les tentatives par un backoff exponentiel. Le chemin
/// streamé n'applique que le [timeout] de connexion : rejouer un flux déjà
/// entamé n'est pas sûr.
final class RetryPolicy {
  /// Nombre de tentatives *supplémentaires* après le premier essai.
  /// `0` désactive les retries (voir [RetryPolicy.none]).
  final int maxRetries;

  /// Délai avant la 1re nouvelle tentative. Doublé à chaque tentative
  /// (selon [backoffFactor]).
  final Duration initialDelay;

  /// Facteur multiplicatif du backoff entre deux tentatives.
  final double backoffFactor;

  /// Délai maximal d'une requête avant [TimeoutException].
  final Duration timeout;

  /// Statuts HTTP considérés comme transitoires (donc rejouables).
  final Set<int> retryStatusCodes;

  const RetryPolicy({
    this.maxRetries = 2,
    this.initialDelay = const Duration(milliseconds: 400),
    this.backoffFactor = 2.0,
    this.timeout = const Duration(seconds: 60),
    this.retryStatusCodes = const {408, 429, 500, 502, 503, 504},
  });

  /// Aucune nouvelle tentative — un seul essai, borné par [timeout].
  static const none = RetryPolicy(maxRetries: 0);

  /// Délai avant la tentative n° [attempt] (0-indexée).
  Duration delayFor(int attempt) {
    final ms = (initialDelay.inMilliseconds * math.pow(backoffFactor, attempt))
        .round();
    return Duration(milliseconds: ms);
  }
}

/// Exécute [send] avec timeout et retries selon [policy].
///
/// [send] doit être *idempotent* : il peut être rappelé plusieurs fois. On
/// rejoue sur timeout, coupure réseau ([http.ClientException]) et statut
/// listé dans [RetryPolicy.retryStatusCodes] ; sinon on renvoie la réponse
/// telle quelle (y compris un 4xx non transitoire, laissé à l'appelant).
Future<http.Response> sendWithRetry(
  Future<http.Response> Function() send,
  RetryPolicy policy,
) async {
  var attempt = 0;
  while (true) {
    try {
      final response = await send().timeout(policy.timeout);
      final transient = policy.retryStatusCodes.contains(response.statusCode);
      if (transient && attempt < policy.maxRetries) {
        await Future<void>.delayed(policy.delayFor(attempt));
        attempt++;
        continue;
      }
      return response;
    } on TimeoutException {
      if (attempt >= policy.maxRetries) rethrow;
      await Future<void>.delayed(policy.delayFor(attempt));
      attempt++;
    } on http.ClientException {
      if (attempt >= policy.maxRetries) rethrow;
      await Future<void>.delayed(policy.delayFor(attempt));
      attempt++;
    }
  }
}

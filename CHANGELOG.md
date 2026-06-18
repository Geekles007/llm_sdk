## 0.3.0

- Adaptateur `GeminiProvider` (API Generative Language `generateContent`) :
  rôle assistant → `model`, `system_instruction`, résultats d'outils en
  `functionResponse` recollés **par nom** (Gemini n'a pas d'ID d'appel — on
  mappe `ToolCallPart.id == name`), forçage via `tool_config` mode `ANY`,
  streaming SSE (`streamGenerateContent?alt=sse`), `usage` et `finishReason`.
  Clé API en en-tête `x-goog-api-key`, `baseUrl` configurable.
- +7 tests Gemini (29 au total). Aucun changement au noyau : les 3 providers
  partagent la même abstraction.

## 0.2.0

- Adaptateur `OpenAIProvider` (API Chat Completions) : encodage/décodage,
  tool calling (`tool_calls` + arguments string JSON), sorties structurées via
  tool forcé, streaming SSE (assemblage des appels d'outils par `index`),
  `usage` et `finishReason`. `baseUrl` configurable (compatible endpoints
  OpenAI-like). Aucun changement au noyau : l'abstraction tient telle quelle.
- +8 tests OpenAI (22 au total).

## 0.1.0

Première tranche : noyau agnostique + adaptateur Claude complet.

- Noyau : types (`Message`/`Part`/`Tool`/`LlmResponse`/`LlmStreamEvent`),
  contrat `LlmProvider` (`generate` + `generateStream`), `LlmClient` portant
  la boucle d'outils, `streamText`, `generateText` et `generateObject<T>`.
- Adaptateur `ClaudeProvider` (API Messages d'Anthropic) : encodage/décodage,
  tool calling, sorties structurées via tool forcé, streaming SSE
  (`TextDelta` / `ToolCallDelta` / `StreamDone`), `usage` et `finishReason`.
- 20 tests (logique client sur provider mocké + aller/retour/SSE Claude).

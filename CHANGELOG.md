## 0.5.0

- **Sampling options**: new `GenerationOptions` (`temperature`, `topP`,
  `stopSequences`) accepted by every `LlmClient` method (`generate`,
  `generateText`, `streamText`, `streamEvents`, `generateObject`) and mapped by
  each adapter to its own dialect (`temperature`/`top_p`/`stop` on OpenAI,
  `stop_sequences` on Claude, `generationConfig` on Gemini). A `null` field is
  omitted, so the model's default applies.
- **Network resilience**: new `RetryPolicy` (configurable per provider via the
  `retry:` constructor argument). The `generate` path now retries transient
  failures — HTTP 408/429/5xx, timeouts, and dropped connections — with
  exponential backoff, and every request is bounded by a `timeout`. Streaming
  applies the connection timeout only (replaying a started stream is unsafe).
  `RetryPolicy.none` opts out.
- +12 tests (42 total): options mapping per provider, backoff timing, retry /
  exhaustion / non-retryable-status / network-drop / timeout, and client-level
  options passthrough. No breaking change: the new parameters are optional.

## 0.4.0

- **Local models** via `OpenAIProvider`: `apiKey` is now optional (defaults to
  empty) and the `Authorization` header is omitted when empty, for self-hosted
  OpenAI-compatible servers (Ollama, LM Studio, llama.cpp, vLLM). `baseUrl` was
  already overridable — no other API change.
- Added `example/ollama_example.dart` (fully local streaming + tool calling).
- README: new "Local models" section.

## 0.3.1

- README: demo GIFs ("switch provider = 1 line", word-by-word streaming).
- pubspec: `screenshots:` (shown on pub.dev).
- No code or API change.

## 0.3.0

- `GeminiProvider` adapter (Generative Language `generateContent` API):
  assistant role → `model`, `system_instruction`, tool results re-attached
  **by name** as `functionResponse` (Gemini has no call ID — we map
  `ToolCallPart.id == name`), forcing via `tool_config` mode `ANY`, SSE
  streaming (`streamGenerateContent?alt=sse`), `usage` and `finishReason`.
  API key in the `x-goog-api-key` header, configurable `baseUrl`.
- +7 Gemini tests (29 total). No change to the core: all 3 providers share the
  same abstraction.

## 0.2.0

- `OpenAIProvider` adapter (Chat Completions API): encoding/decoding, tool
  calling (`tool_calls` + JSON-string arguments), structured outputs via forced
  tool, SSE streaming (assembling tool calls by `index`), `usage` and
  `finishReason`. Configurable `baseUrl` (compatible with OpenAI-like
  endpoints). No change to the core: the abstraction holds as-is.
- +8 OpenAI tests (22 total).

## 0.1.0

First slice: provider-agnostic core + complete Claude adapter.

- Core: types (`Message`/`Part`/`Tool`/`LlmResponse`/`LlmStreamEvent`),
  `LlmProvider` contract (`generate` + `generateStream`), `LlmClient` carrying
  the tool loop, `streamText`, `generateText` and `generateObject<T>`.
- `ClaudeProvider` adapter (Anthropic Messages API): encoding/decoding, tool
  calling, structured outputs via forced tool, SSE streaming
  (`TextDelta` / `ToolCallDelta` / `StreamDone`), `usage` and `finishReason`.
- 20 tests (client logic on a mocked provider + Claude round-trip/SSE).

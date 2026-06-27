# llm_sdk

> The unified toolkit for talking to any LLM from a Dart / Flutter app.
> **One interface, several interchangeable brains.**

On the web (JS) there is a polished toolkit for talking to LLMs (think Vercel AI
SDK). On the Dart / Flutter side, there was nothing equivalent — everyone
re-plumbs their own HTTP calls. `llm_sdk` is that clean bridge:
multi-provider, streaming, tool calling and structured outputs behind **one**
API.

### Switching AI = changing one line

![Switch provider in one line](doc/swap.gif)

### Streaming, word by word

![Typewriter-style streaming](doc/stream.gif)

---

## Table of contents

- [Why llm_sdk](#why-llm_sdk)
- [Install](#install)
- [Quick start](#quick-start)
- [Providers & configuration](#providers--configuration)
- [Local models (Ollama, LM Studio, llama.cpp, vLLM)](#local-models-ollama-lm-studio-llamacpp-vllm)
- [The 4 building blocks](#the-4-building-blocks)
  - [Text generation](#1-text-generation)
  - [Streaming](#2-streaming)
  - [Tool calling](#3-tool-calling)
  - [Structured outputs](#4-structured-outputs)
- [Error handling](#error-handling)
- [Resource cleanup](#resource-cleanup)
- [API reference](#api-reference)
- [Architecture](#architecture)
- [Status & limitations](#status--limitations)
- [Testing](#testing)
- [License](#license)

---

## Why llm_sdk

| Building block | What it does |
|---|---|
| **Multi-provider** | The same "buttons" no matter which vendor is behind them. |
| **Streaming** | Show the answer word by word, live. |
| **Tool calling** | The AI asks to run functions; the SDK orchestrates the round-trip. |
| **Structured outputs** | The AI fills a typed Dart object instead of returning free-form text. |

The contract a provider must implement is just **two methods**
(`generate`, `generateStream`). All the usage logic — the tool loop,
`streamText`, `generateObject` — is built **once** in `LlmClient`, on top of
that contract. Switching from Claude to OpenAI to Gemini changes a single
line; nothing else in your code moves.

## Install

Add the dependency:

```bash
dart pub add llm_sdk
```

or, in a Flutter project:

```bash
flutter pub add llm_sdk
```

or add it manually to your `pubspec.yaml`:

```yaml
dependencies:
  llm_sdk: ^0.4.0
```

Then import it:

```dart
import 'package:llm_sdk/llm_sdk.dart';
```

The only runtime dependency is [`http`](https://pub.dev/packages/http), so the
package works anywhere Dart runs (CLI, server, Flutter mobile/desktop/web).

## Quick start

```dart
import 'dart:io';
import 'package:llm_sdk/llm_sdk.dart';

Future<void> main() async {
  // Pick the brain. Switching AI = changing this one line.
  final client = LlmClient(
    ClaudeProvider(apiKey: Platform.environment['ANTHROPIC_API_KEY']!),
  );

  final answer = await client.generateText([
    Message.system('You are a concise assistant.'),
    Message.user('Give me one productivity tip.'),
  ]);

  print(answer);
}
```

> **Tip:** never hard-code API keys. Read them from environment variables
> (`Platform.environment['...']`) or your app's secret storage.

## Providers & configuration

Every provider implements the same `LlmProvider` contract, so they are fully
interchangeable inside an `LlmClient`. They differ only in their constructor
options and default model.

### Claude (Anthropic)

```dart
final provider = ClaudeProvider(
  apiKey: 'sk-ant-...',          // required
  model: 'claude-opus-4-8',      // default
  maxTokens: 1024,               // default — required by Anthropic
);
```

### OpenAI (and OpenAI-compatible servers)

```dart
final provider = OpenAIProvider(
  apiKey: 'sk-...',                       // optional — empty for local servers
  model: 'gpt-4o',                        // default
  maxTokens: null,                        // optional — null lets the model decide
  baseUrl: 'https://api.openai.com/v1',   // default — override for local models
);
```

### Gemini (Google)

```dart
final provider = GeminiProvider(
  apiKey: 'AIza...',                                            // required
  model: 'gemini-1.5-pro',                                      // default
  maxTokens: null,                                              // optional
  baseUrl: 'https://generativelanguage.googleapis.com/v1beta', // default
);
```

### Common options

| Option | Type | Notes |
|---|---|---|
| `apiKey` | `String` | Required for Claude & Gemini. Optional for OpenAI (empty for local servers). |
| `model` | `String` | Model id. Has a sensible default per provider. |
| `maxTokens` | `int` / `int?` | Required & defaults to `1024` on Claude; optional (`null`) on OpenAI & Gemini. |
| `baseUrl` | `String` | Available on OpenAI & Gemini to point at a different endpoint. |
| `httpClient` | `http.Client?` | Inject your own client (timeouts, proxy, tests). |

### Swapping providers

Because the surface is identical, swapping is a one-line change:

```dart
final client = LlmClient(ClaudeProvider(apiKey: myKey));
// ... or, without touching any other line:
final client = LlmClient(OpenAIProvider(apiKey: myKey));
final client = LlmClient(GeminiProvider(apiKey: myKey));
```

You can also tune the tool loop bound:

```dart
final client = LlmClient(provider, maxSteps: 8); // default is 5
```

## Local models (Ollama, LM Studio, llama.cpp, vLLM)

Any server that exposes an **OpenAI-compatible** API works out of the box: just
point `baseUrl` at your local endpoint. The API key is optional — a local
server ignores it.

```dart
final client = LlmClient(OpenAIProvider(
  baseUrl: 'http://localhost:11434/v1', // Ollama
  model: 'llama3.2',
));
```

All 4 building blocks (text, streaming, tool calling, structured outputs) stay
identical — only the `baseUrl` changes. No data leaves the machine.

Common endpoints:

| Server | `baseUrl` |
|---|---|
| Ollama | `http://localhost:11434/v1` |
| LM Studio | `http://localhost:1234/v1` |
| llama.cpp / vLLM | their own endpoint |

## The 4 building blocks

### 1. Text generation

`generate` returns a full `LlmResponse` (text, usage, finish reason, tool
calls). `generateText` is the shortcut that returns the final string directly.

```dart
final response = await client.generate([
  Message.user('Summarize relativity in one sentence.'),
]);

print(response.text);                       // the answer
print(response.usage?.totalTokens);         // token count, if provided
print(response.finishReason);               // FinishReason.stop, length, ...
```

Build conversations by stacking messages:

```dart
final messages = [
  Message.system('You are a helpful translator.'),
  Message.user('Translate "good morning" to French.'),
  Message.assistant('Bonjour.'),
  Message.user('And to Spanish?'),
];
final reply = await client.generateText(messages);
```

### 2. Streaming

Stream the answer word by word for a typewriter effect:

```dart
await for (final chunk in client.streamText([Message.user('Tell me a joke')])) {
  stdout.write(chunk); // typewriter effect
}
```

Need the raw event stream (text deltas, tool calls, and the assembled final
response)? Use `streamEvents`:

```dart
await for (final event in client.streamEvents([Message.user('Hi')])) {
  switch (event) {
    case TextDelta(:final text):       stdout.write(text);
    case ToolCallDelta(:final call):   print('tool: ${call.name}');
    case StreamDone(:final response):  print('\nusage: ${response.usage}');
  }
}
```

### 3. Tool calling

Declare a tool (name, description, JSON-schema parameters, and the function to
run). The SDK orchestrates the whole round-trip automatically.

```dart
final weather = Tool(
  name: 'getWeather',
  description: 'Returns the current weather for a city',
  parameters: {
    'type': 'object',
    'properties': {'city': {'type': 'string'}},
    'required': ['city'],
  },
  run: (args) async => '29 °C and humid in ${args['city']}',
);

final response = await client.generate(
  [Message.user('What is the weather in Douala?')],
  tools: [weather],
);
print(response.text); // "It's 29 °C and humid in Douala."
```

The SDK loops automatically (bounded by `maxSteps`): the AI asks →
`getWeather` runs → the result is sent back to the AI → final answer. You can
register multiple tools; the model picks which to call (and may call several).

### 4. Structured outputs

Make the model fill a typed "form" instead of returning free-form text. You
provide a JSON schema and a `fromJson` constructor; the model's tool arguments
*are* the object.

```dart
class Invoice {
  final String client;
  final double amount;
  Invoice(this.client, this.amount);
  factory Invoice.fromJson(Map<String, dynamic> j) =>
      Invoice(j['client'] as String, (j['amount'] as num).toDouble());
}

final invoice = await client.generateObject<Invoice>(
  [Message.user('Invoice for Metchera, 1,250 EUR incl. tax.')],
  schema: {
    'type': 'object',
    'properties': {
      'client': {'type': 'string'},
      'amount': {'type': 'number'},
    },
    'required': ['client', 'amount'],
  },
  fromJson: Invoice.fromJson,
);
print(invoice.client);  // "Metchera"
print(invoice.amount);  // 1250.0
```

> No runtime reflection in Flutter: the JSON schema and the `fromJson` are
> manual in v1. Codegen via annotations is planned for later.

## Error handling

When a provider returns a non-200 HTTP status, or a response cannot be parsed,
the SDK throws an `LlmException`:

```dart
try {
  final answer = await client.generateText([Message.user('Hello')]);
  print(answer);
} on LlmException catch (e) {
  print('Provider error ${e.statusCode}: ${e.body}');
}
```

| Field | Type | Meaning |
|---|---|---|
| `statusCode` | `int` | HTTP status from the provider (`0` if the error isn't network-level). |
| `body` | `String` | Raw response body, or an error message. |

A `StateError` is thrown if the tool loop hits `maxSteps` without a final
answer, or if the model requests a tool you didn't register.

## Resource cleanup

Each provider owns an internal `http.Client`. If you create a provider
manually (rather than injecting one), close it when you're done:

```dart
final provider = ClaudeProvider(apiKey: myKey);
// ... use it ...
provider.close();
```

For long-lived apps you usually create the provider once and keep it for the
process lifetime — no need to close per request.

## API reference

### `LlmClient`

| Member | Signature | Description |
|---|---|---|
| constructor | `LlmClient(LlmProvider provider, {int maxSteps = 5})` | Wraps a provider; `maxSteps` bounds the tool loop. |
| `generate` | `Future<LlmResponse> generate(List<Message>, {List<Tool> tools})` | Full response, with automatic tool loop. |
| `generateText` | `Future<String> generateText(List<Message>, {List<Tool> tools})` | Convenience: returns the final text. |
| `streamText` | `Stream<String> streamText(List<Message>)` | Text chunks, word by word. |
| `streamEvents` | `Stream<LlmStreamEvent> streamEvents(List<Message>, {List<Tool> tools})` | Raw typed event stream. |
| `generateObject` | `Future<T> generateObject<T>(List<Message>, {required Map schema, required T Function(Map) fromJson, String description})` | Typed structured output. |

### Core types

| Type | Purpose |
|---|---|
| `Message` | A conversation turn. Factories: `Message.system/user/assistant(text)`. |
| `Part` (sealed) | `TextPart`, `ToolCallPart`, `ToolResultPart`. |
| `Tool` | A callable tool: `name`, `description`, `parameters` (JSON schema), `run`. |
| `LlmResponse` | `message`, `text`, `toolCalls`, `usage`, `finishReason`. |
| `Usage` | `inputTokens`, `outputTokens`, `totalTokens`. |
| `FinishReason` | `stop`, `length`, `toolUse`, `contentFilter`, `unknown`. |
| `LlmStreamEvent` (sealed) | `TextDelta`, `ToolCallDelta`, `StreamDone`. |
| `LlmException` | Thrown on provider/HTTP errors. |

## Architecture

The contract boils down to **two methods** (`generate`, `generateStream`) that
each provider implements. All usage logic — the tool loop, `streamText`,
`generateObject` — is built **once** in `LlmClient`, on top of the contract.
Providers stay thin: they only translate to/from their own dialect.

```
LlmClient  ── tool loop, streamText, generateObject
   │
   └── LlmProvider (contract: generate + generateStream)
         ├── ClaudeProvider   ✅ (text, tools, structured outputs, SSE streaming)
         ├── OpenAIProvider   ✅ (same, Chat Completions dialect + local endpoints)
         └── GeminiProvider   ✅ (same, generateContent dialect)
```

## Status & limitations

**Current version: 0.4.0**

- ✅ Provider-agnostic core: types, contract, `LlmClient` (tool loop,
  `generateObject`, `streamText`).
- ✅ All **3 adapters** (Claude, OpenAI, Gemini) complete: `generate`, tool
  calling, structured outputs (via forced tool), SSE streaming.
- ✅ **Local models** via the OpenAI adapter (overridable `baseUrl`, optional
  key): Ollama, LM Studio, llama.cpp, vLLM.
- ✅ 29 tests (mocked client logic + round-trip/SSE for all 3 providers).
- 🎯 All 4 building blocks work across the 3 providers **with no change to the
  core** — the abstraction *is* the product, and it held.
- ⬜ Out of scope for v1: embeddings, vision/audio, cost tracking, caching,
  retries, multi-step agents beyond the tool loop.

### Known v1 limitation

Combining streaming **and** tools simultaneously is deferred: the automatic
tool loop lives on `generate` (the `Future` path); `streamText` stays simple.

## Testing

```bash
dart pub get
dart test
```

## License

See [LICENSE](LICENSE).

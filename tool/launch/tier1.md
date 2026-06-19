# Tier 1 — checklist de lancement

> But : visibilité rapide sur les canaux où les devs Flutter cherchent.
> Pré-requis : avoir republié **0.3.1** sur pub.dev (README + GIFs live) et
> poussé le repo GitHub public.

---

## 0. Avant tout (ordre)

1. `dart pub publish` → 0.3.1 (README + screenshots en ligne).
2. Vérifier que la page https://pub.dev/packages/llm_sdk affiche les GIFs.
3. Mettre une **description GitHub** + topics (voir plus bas).
4. Ensuite seulement : poster (Reddit, Gems, PRs).

---

## 1. r/FlutterDev — post « Show »

**Titre :**
```
I built the missing AI SDK for Flutter — one interface for Claude, OpenAI & Gemini (swap providers in a line)
```

**Corps :**
```
There's a polished SDK for talking to LLMs on the web (the Vercel AI SDK).
On the Dart/Flutter side there was nothing equivalent — everyone re-wires the
same plumbing (request shaping, SSE streaming, tool-call round-trips,
multi-provider) by hand.

So I built **llm_sdk**: one interface, three brains behind it.

- 🔁 Multi-provider — Claude, OpenAI, Gemini. Swapping is literally one line.
- ⌨️ Streaming — `streamText` gives you a `Stream<String>`, word by word.
- 🛠️ Tool calling — declare a `Tool`, the SDK orchestrates the whole loop.
- 📋 Structured outputs — `generateObject<T>` fills a typed Dart object.

The whole design rests on a 2-method provider contract; all the logic
(tool loop, streaming, structured outputs) lives once in the client. Adding a
provider is pure dialect translation.

Pure Dart package (no Flutter dependency), MIT, fully tested (mocked
request/response + SSE).

pub.dev: https://pub.dev/packages/llm_sdk
GitHub: https://github.com/Geekles007/llm_sdk

Feedback very welcome — especially on the API ergonomics and which provider
you'd want next (Mistral? Ollama? local?).
```

**Bonnes pratiques Reddit :** poster en semaine, le matin (heure US). Mettre
le GIF `swap.gif` en image du post. Répondre à TOUS les commentaires dans les
2 premières heures (l'algo et la communauté récompensent l'engagement). Ne pas
cross-poster le même jour partout.

---

## 2. Flutter Gems (fluttergems.dev)

Annuaire curé, gros trafic qualifié. Soumission via leur repo GitHub
`fluttergemsdev/fluttergems` :
- Ouvrir une issue « Add package » (ou PR) avec le lien pub.dev.
- Catégorie suggérée : **AI / Machine Learning** (sous-catégorie LLM).
- Pitch court : « Unified LLM client — Claude/OpenAI/Gemini, streaming, tools,
  structured outputs. »

---

## 3. Awesome Flutter (PR)

Repo : `Solido/awesome-flutter`. Section pertinente : **AI** (ou « Backend /
APIs » selon l'état du sommaire — vérifier le README au moment de la PR).

Ligne à ajouter (ordre alphabétique dans la section) :
```markdown
- [llm_sdk](https://github.com/Geekles007/llm_sdk) - Unified interface for Claude, OpenAI and Gemini: streaming, tool calling and typed structured outputs.
```

## 4. Awesome Dart (PR)

Repo : `yissachar/awesome-dart`. Section **Packages → AI / Machine Learning**
(ou « Networking » à défaut).
```markdown
- [llm_sdk](https://github.com/Geekles007/llm_sdk) - One interface for multiple LLM providers (Claude, OpenAI, Gemini) with streaming, tool calling and structured outputs.
```

> Pour les deux PRs : respecter le format exact du fichier (tirets, ordre,
> ponctuation finale). Lire le CONTRIBUTING avant. Une description sobre, pas
> markéteuse.

---

## 5. Maximiser le score pub.dev

- ✅ `screenshots:` ajoutés (carrousel sur la page).
- ✅ format/analyse/dartdoc/exemple/licence OSI/SDK récent.
- ⬜ **Likes** : demander à 2-3 personnes de cliquer « Like » sur la page
  pub.dev (être connecté avec un compte Google). Les likes pèsent dans le
  classement de recherche.
- ⬜ Vérifier le **pub points** réel sur la page après publish (viser 160/160).

---

## 6. Description + topics GitHub

About :
```
Unified Dart & Flutter SDK for LLMs (Claude, OpenAI, Gemini): multi-provider, streaming, tool calling, and typed structured outputs.
```
Topics :
```
dart flutter llm ai claude openai gemini anthropic streaming tool-calling sdk
```

## iblai-router (iblai-openclaw-router)

Der **iblai-router** ist ein Open-Source-Proxy von ibl.ai, der jede Anfrage an das günstigste fähige Modell routet — basierend auf einem **14-Dimensionen-Scoring-System** in unter 1 Millisekunde [^1].

### Wie es funktioniert

**3 Tiers:**

| Tier   | Modell (Default) | Preis/1M Tokens | Typische Tasks                         |
| ------ | ---------------- | --------------- | -------------------------------------- |
| LIGHT  | Haiku            | $1 / $5         | Simpel: Relays, Status-Checks          |
| MEDIUM | Sonnet           | $3 / $15        | Strukturiert: Issue-Erstellung, Triage |
| HEAVY  | Opus             | $15 / $75       | Deep Reasoning, Architektur, Analyse   |

**Ersparnis:** ~70% insgesamt. ~85% des Agent-Traffics sind simple Relays/strukturierte Tasks → Haiku. Nur ~15% echtes Deep-Reasoning → Opus [^1].

**Schlüsseleigenschaften:**

- **Nur User-Message wird gescored**, nicht der System-Prompt (sonst würde der keyword-rich System-Prompt alles zu Opus pushen) [^7]
- **Model-agnostic** — kann über OpenRouter beliebige Provider mischen (z.B. Gemini Flash-Lite für LIGHT, Sonnet für MEDIUM, o3 für HEAVY) [^1]
- **~250 Zeilen JavaScript, zero dependencies** — MIT-lizenziert, einfach zu forken [^1]
- **Hot-reload config.json** — Keyword-Listen, Gewichte und Tier-Grenzen ohne Restart anpassbar

---

## ClawRouter (das Original, das iblai inspiriert hat)

ClawRouter von BlockRun ist der **Ursprung** des Weighted-Scoring-Ansatzes. Es ist der offizielle OpenClaw-native Router mit einer etwas reicheren Architektur [^2].

### Die 14 Dimensionen mit Gewichten

| Dimension            | Gewicht | Was es misst                                   |
| -------------------- | ------- | ---------------------------------------------- |
| Reasoning Markers    | 0.18    | "prove", "theorem", formale Logik              |
| Code Presence        | 0.15    | "function", Code-Blocks, Programmier-Keywords  |
| Simple Indicators    | 0.12    | "what is", "define" → billigeres Modell        |
| Multi-Step Patterns  | 0.12    | "first...then", "step 1" Sequenzen             |
| Technical Terms      | 0.10    | "algorithm", "distributed"                     |
| Token Count          | 0.08    | Prompt-Länge relativ zu 50/500 Token-Schwellen |
| Creative Markers     | 0.05    | Storytelling, Brainstorming                    |
| Question Complexity  | 0.05    | 4+ Fragezeichen → hohe Komplexität             |
| Constraint Count     | 0.04    | "at most", "maximum"                           |
| Imperative Verbs     | 0.03    | "build", "implement"                           |
| Output Format        | 0.03    | JSON/YAML/Table-Requests                       |
| Domain Specificity   | 0.02    | "quantum", "genomics"                          |
| Reference Complexity | 0.02    | "the docs", "the API"                          |
| Negation Complexity  | 0.01    | "don't", "avoid"                               |

_(Gewichte summieren auf 1.0)_ [^3]

### 4 Tiers (eine mehr als iblai)

| Score       | Tier      |
| ----------- | --------- |
| < 0.00      | SIMPLE    |
| 0.00 – 0.15 | MEDIUM    |
| 0.15 – 0.25 | COMPLEX   |
| > 0.25      | REASONING |

### Zwei-Stufen-Klassifikation (ClawRouter's Vorteil über iblai)

1. **Stage 1:** Rule-based 14-Dimensionen-Scoring (reine Keyword-Matching + Arithmetik, <1ms, **kein LLM-Inference**) [^2]
2. **Stage 2: LLM Fallback** — Wenn die Sigmoid-basierte Confidence < 0.70 fällt, wird `google/gemini-2.5-flash` als Classifier benutzt, um eine zweite Meinung einzuholen [^3]

Außerdem: **Multilingual** — Keyword-Listen in 9 Sprachen (EN, ZH, JA, RU, DE, ES, PT, KO, AR). "证明这个定理" triggert dasselbe Reasoning-Tier wie "prove this theorem" [^4].

---

## Alternative Open-Source-Router

| Projekt                         | Ansatz                          | Besonderheit                                                                             |
| ------------------------------- | ------------------------------- | ---------------------------------------------------------------------------------------- |
| **FreeRouter** (openfreerouter) | Self-hosted, eigene API-Keys    | Kein Middleman, kein Markup, gratis [^11]                                                |
| **agent-router** (dabit3)       | Multi-Agent Task-Routing        | 4 Modi: Cost-Optimized, Latency, Specialty (Coding→coding agent), Quality [^5]           |
| **LLMRouter** (ulab-uiuc)       | Trainierte Router-Modelle       | 16+ Router-Modelle, akademisch fundiert, PyPI-Paket [^8]                                 |
| **RouteLLM**                    | Preference-Data-trainiert       | BERT/Causal-LLM basiert, OpenAI-Embeddings, veröffentlicht 2025 [^9]                     |
| **OpenRouter `:free`**          | Auto-Select aus gratis Modellen | Filtert nach Features (Image, Tool-Calling, etc.), `openrouter/free` als Model-Slug [^6] |
| **llm-routing (PyPI)**          | MCP-Server, Complexity-Routing  | Budget-aware, 20+ Provider, Claude/OpenAI/Gemini/Ollama [^10]                            |

---

## Welcher für deinen Use-Case?

**Wenn du genau das willst, was du beschrieben hast** ("basic Interaction, Verständnis, bisschen dümmer aber günstiger"):

| Bedarf                                        | Empfehlung                                                   |
| --------------------------------------------- | ------------------------------------------------------------ |
| **Maximale Einfachheit, selbst hosten**       | **iblai-router** — 250 Zeilen, zero-dep, just works          |
| **Robuster, mit LLM-Fallback & multilingual** | **ClawRouter** — 2-Stufen-Klassifikation, 9 Sprachen         |
| **Komplett gratis, keine API-Keys verwalten** | **OpenRouter `openrouter/free`** — auto-select aus free pool |
| **Self-hosted, eigene Keys, kein Markup**     | **FreeRouter**                                               |
| **Multi-Agent-Workflow mit Routing-Modi**     | **agent-router** (dabit3)                                    |
| **Akademisch fundiert, trainierter Router**   | **LLMRouter** (ulab-uiuc) oder **RouteLLM**                  |

**Die zentrale Einsicht** aus allen diesen Projekten: **~85% deines Traffics braucht kein teures Modell.** Ein simpler Keyword-Score in <1ms reicht, um "check status" von "prove this theorem" zu unterscheiden. Du zahlst nur für die ~15% echten Reasoning-Aufwand Opus-Preise — der Rest geht an Flash-Lite/Nano/Haiku für fast nichts [^1].

**References**

[^1]: [Introducing ibl.ai OpenClaw Router: Cut You... | ibl.ai Blog](https://ibl.ai/blog/iblai-openclaw-router-cost-optimizing-model-routing) (37%)

[^2]: [ClawRouter - BlockRun Docs](https://blockrun.ai/docs/products/routing/clawrouter) (12%)

[^3]: [14-Dimension Classification | blockrunai/clawrouter | DeepWiki](https://deepwiki.com/blockrunai/clawrouter/5.1-14-dimension-classification) (9%)

[^4]: [Inside ClawRouter's Decision Layer: Real-Time... | BlockRun Signal](https://blockrun.ai/signal/clawrouter-quality-vs-cost-real-time-routing) (7%)

[^5]: [Multi-Model Routing Open-Source Tools & Implementation: Getting the...](https://quidproquo.cc/posts/ai/2026-04-02-multi-model-routing-opensource-tools-en/) (6%)

[^6]: [Free Models Router - Zero-Cost AI Inference](https://openrouter.ai/docs/guides/routing/routers/free-router) (6%)

[^7]: [GitHub - iblai/iblai-openclaw-router: Route every request to the...](https://github.com/iblai/iblai-openclaw-router) (5%)

[^8]: [LLMRouter: An Open-Source Library for LLM Routing - GitHub](https://github.com/ulab-uiuc/LLMRouter) (5%)

[^9]: [RouteLLM: Learning to Route LLMs with Preference Data](https://arxiv.org/html/2406.18665v4) (5%)

[^10]: [llm-routing · PyPI](https://pypi.org/project/llm-routing/) (5%)

[^11]: [FreeRouter — Free, Self-Hosted AI Model Router - GitHub](https://github.com/openfreerouter/freerouter) (4%)

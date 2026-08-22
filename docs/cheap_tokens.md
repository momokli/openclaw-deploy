## Die günstigsten bezahlten Modelle (pro 1M Tokens)

| Modell                            | Input  | Output | Gut für                                                 |
| --------------------------------- | ------ | ------ | ------------------------------------------------------- |
| **DeepSeek V4 Flash**             | $0.22  | $0.66  | Allerbilligste paid Option, gut für einfache Tasks [^5] |
| **DeepSeek V4 Flash (Cache-Hit)** | $0.007 | —      | Wiederholter Kontext → ~30× günstiger [^6]              |
| **Gemini 2.5 Flash-Lite**         | $0.10  | $0.40  | Klassifizierung, Routing, 2M Kontext [^7]               |
| **GPT-5 Nano**                    | $0.05  | $0.40  | High-volume Klassifizierung, Extraktion [^8]            |
| **GPT-5 Nano (Batch/Flex)**       | $0.025 | $0.20  | Noch günstiger im Batch-Modus [^9]                      |

**DeepSeek V4 Flash** ist also tatsächlich so eine "DeepSeek Flash nur noch günstiger"-Kategorie — genau was du beschrieben hast. Preise oben = **off-peak** (Peak = 2×, 01–04 + 06–10 UTC). Cache-Hit ≈ **30×** günstiger ($0.007/$0.014). Zum Vergleich: `deepseek-v4-pro` = $0.66/$1.98 off-peak (offiziell [^2]).

---

## Sogar komplett gratis (Free Tiers)

| Anbieter                   | Modell                       | Free Limit                      | Hinweis                                        |
| -------------------------- | ---------------------------- | ------------------------------- | ---------------------------------------------- |
| **Google Gemini**          | 2.5 Flash / Flash-Lite       | ~1.500 Requests/Tag, 20 req/min | Keine Kreditkarte nötig, bleibt gratis [^3]    |
| **Groq / Cerebras**        | Open-Source-Modelle          | Rate-limited, gratis            | Sehr schnell, für echte Workloads nutzbar [^4] |
| **OpenRouter**             | Verschiedene `:free`-Modelle | Limitiert, rotierend            | Auto-Router wählt aus dem free-Pool [^1]       |
| **Hugging Face Inference** | Tausende Open-Source-Modelle | 2.000 Requests/Tag              | Für registrierte Nutzer gratis [^1]            |

---

## Was bedeutet das für dich?

**Für wirklich basic Interaction & Verständnis** reicht ein "dümmeres, aber günstiges" Modell völlig:

- **DeepSeek V4 Flash** — dein gesuchtes "Flash nur günstiger" Modell. $0.14/$0.28 per 1M Tokens, mit Cache sogar fast nichts. Gut genug für simple Textverständnis-Aufgaben.
- **Gemini 2.5 Flash-Lite** — $0.10 Input, riesiger Kontext, und es gibt sogar eine **kostenlose Stufe** die für viele Basics reicht.
- **GPT-5 Nano** — $0.05 Input, klassische OpenAI-Kompatibilität, perfekt für Klassifizierung und simple Extraktion.

**Fazit:** Die teuren Flaggschiff-Preise gelten für die großen Modelle. Die kleine, dumme, billige Kategorie ist 2026 **billiger als je zuvor** — und teilweise sogar gratis. Wenn du nur "liest mal kurz Text, versteht ihn, gibt was zurück" brauchst, zahlst du praktisch nichts mehr.

**References**

[^1]: [mnfst/awesome-free-llm-apis](https://github.com/mnfst/awesome-free-llm-apis) (21%)

[^2]: [Models & Pricing | DeepSeek API Docs](https://api-docs.deepseek.com/quick_start/pricing) (18%)

[^3]: [Free LLM APIs (April 2026 Update) : r/openclaw](https://www.reddit.com/r/openclaw/comments/1spgr25/free_llm_apis_april_2026_update/) (11%)

[^4]: [Free LLM APIs in 2026: 13 Providers Compared (OpenAI ...](https://klymentiev.com/blog/free-llm-api) (10%)

[^5]: [LLM API Providers (2026): 12 APIs Compared by Price per 1M ...](https://www.morphllm.com/llm-api) (9%)

[^6]: [DeepSeek V4 API Pricing 2026: Flash vs Pro Cost Guide](https://ofox.ai/blog/deepseek-api-pricing-guide-2026/) (8%)

[^7]: [Gemini API Pricing 2026: Complete Per-1M-Token Cost Guide with ...](https://www.aifreeapi.com/en/posts/gemini-api-pricing-2026) (8%)

[^8]: [OpenAI API Cheapest Model 2026: GPT-5 Nano Cost... - TokenMix Blog](https://tokenmix.ai/blog/openai-api-cheapest-model) (7%)

[^9]: [LLM API Pricing Comparison 2026: Cheapest Models by Input ...](https://blog.laozhang.ai/en/posts/cheapest-llm-models) (7%)

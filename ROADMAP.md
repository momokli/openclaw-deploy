# Roadmap — OpenClaw Deployment (Momo)

Stand: 2026-08-21. Source of truth: dieses Repo.
Grundlage: OpenClaw-Docs (memory, memory-search, groups, usage-tracking, hooks, config-agents, config-channels).

## 💸 Kosten (OpenRouter only, korrigiert 2026-08-21)

Die früher notierten Preise waren **~3× zu niedrig**. Modelle laufen über OpenRouter
(`openrouter/deepseek/deepseek-v4.1-flash` / `deepseek-v4-pro`); Preise vom Anbieter
(offiziell `api-docs.deepseek.com`, DeepSeek-Basis unter OpenRouter):

| Modell              | Input (cache miss)          | Input (cache hit)             | Output                      |
| ------------------- | --------------------------- | ----------------------------- | --------------------------- |
| `deepseek-v4-flash` | $0.22 off-peak / $0.44 peak | $0.007 off-peak / $0.014 peak | $0.66 off-peak / $1.32 peak |
| `deepseek-v4-pro`   | $0.66 off-peak / $1.32 peak | $0.022 off-peak / $0.044 peak | $1.98 off-peak / $3.96 peak |

- Context 1M, max Output 384K. **Thinking-Mode ist default** (erzeugt viele Output-Tokens).
- Pro = exakt **3×** Flash (cache miss + output). Cache-Hit ≈ **30×** günstiger → Prompt-Caching ist der größte Hebel.
- Off-peak = halber Preis. Peak: 01:00–04:00 + 06:00–10:00 UTC.

### Routing (umgesetzt)

- `main` → `openrouter/deepseek/deepseek-v4.1-flash` (default); Fallback `deepseek-v4-pro` (heavy coding).
- `feature-dev-*` (6 Agents) → `openrouter/deepseek/deepseek-v4.1-flash` + `thinkingDefault: "low"`.
- `agents.defaults.subagents.model` → `openrouter/deepseek/deepseek-v4.1-flash` (gespawnte Sub-Agents billig).
- `agents.defaults.utilityModel` → `openrouter/deepseek/deepseek-v4.1-flash` (Titel/Klassifizierung billig).
- `agents.defaults.compaction.model` → `openrouter/deepseek/deepseek-v4.1-flash` (Summaries billig).
- `agents.defaults.contextPruning: { mode: "cache-ttl" }` (alte Tool-Results trimmen).
- `session.reset: { mode: "idle", idleMinutes: 120 }` + `session.maintenance` (Kontext-Hygiene).
- `messages.responseUsage: "tokens"` → Usage-Footer sichtbar (`/usage cost`).

### Noch offen (Kosten)

- Free/Cheap-Fallback (Gemini Flash-Lite / Groq) als 2. Provider — Phase 2.
- ggf. LiteLLM mit hartem Monats-Budget (Phase 2).

## ✅ Erledigt

- **Native Deployment**: OpenClaw als systemd-User-Service (`openclaw-gateway.service`) auf `.149`;
  Docker/GHCR/Ansible-Flow entfernt (2026-09-16).
- **Semantisches Memory**: `memory.search.provider = "ollama"` (lokal, Modell `nomic-embed-text`) — self-hosted, kein externer Embedding-API-Call.

## ⬜ Offen (korrigiert nach Docs)

| #   | Baustein            | Nativer Weg (Docs)                                                                                             | Status                                              |
| --- | ------------------- | -------------------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| 1   | Vault mount         | Vault rw nach `/quill` mounten + Sync via `obsidian-headless` (**ersetzt Syncthing**)                          | ✅                                                  |
| 2   | Vault indexieren    | `agents.defaults.memorySearch.extraPaths: ["/quill"]`                                                          | ✅                                                  |
| 3   | Rollen je Gruppe    | `channels.telegram.groups.<id>.systemPrompt` (nativ, KEIN `before_prompt_build`-Plugin)                        | ⬜                                                  |
| 4   | Gruppen-Setup       | `groupPolicy: "allowlist"` + `groupAllowFrom` + `requireMention`                                               | ⬜                                                  |
| 5   | Kosten-Sichtbarkeit | `messages.responseUsage: "tokens"` (Footer). Kein Hard-Limit in OpenClaw — Hard-Limit = Provider-Billing-Alert | ✅ (Footer); ⬜ (`models.providers.cost`-Schätzung) |
| 6   | _(optional)_ QMD    | `memory.backend: "qmd"` + Reranking                                                                            | ⚪                                                  |

## Dependency-Kette

```
Vault mount (#1) → Vault indexieren (#2) → Rollen/Gruppen (#3+#4) → Usage-Footer (#5) → (optional) QMD (#6)
```

## Konzeptionelle Korrekturen (aus Docs, 2026-08-19)

- **Rollen** = nativer `channels.telegram.groups.<id>.systemPrompt`, kein Plugin-Hook nötig.
- **Kosten** = Footer-Display (`messages.responseUsage`), kein harter €-Limit in OpenClaw. Hard-Limit nur Provider-seitig.
- **Vault-Sync** = Syncthing wird durch **Obsidian Sync** (`obsidian-headless`, offizieller Client) **abgelöst**. Der `feature/obsidian-headless`-Branch ist der **richtige Weg** — verfolgen und mergen, NICHT verwerfen.
- **Memory-Konzept**: `MEMORY.md` (durable, injiziert) + `memory/*.md` (daily, nur indexiert) + `extraPaths` (zusätzliche Verzeichnisse wie `/quill`).

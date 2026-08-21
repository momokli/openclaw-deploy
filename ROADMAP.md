# Roadmap — OpenClaw Deployment (Momo)

Stand: 2026-08-21. Source of truth: dieses Repo.
Grundlage: OpenClaw-Docs (memory, memory-search, groups, usage-tracking, hooks, config-agents, config-channels).

## 💸 Kosten (korrigiert 2026-08-21 — DeepSeek Preiserhöhung)

Die früher notierten Preise waren **~3× zu niedrig**. Aktuell (offiziell `api-docs.deepseek.com`):

| Modell              | Input (cache miss)          | Input (cache hit)             | Output                      |
| ------------------- | --------------------------- | ----------------------------- | --------------------------- |
| `deepseek-v4-flash` | $0.22 off-peak / $0.44 peak | $0.007 off-peak / $0.014 peak | $0.66 off-peak / $1.32 peak |
| `deepseek-v4-pro`   | $0.66 off-peak / $1.32 peak | $0.022 off-peak / $0.044 peak | $1.98 off-peak / $3.96 peak |

- Context 1M, max Output 384K. **Thinking-Mode ist default** (erzeugt viele Output-Tokens).
- Pro = exakt **3×** Flash (cache miss + output). Cache-Hit ≈ **30×** günstiger → Prompt-Caching ist der größte Hebel.
- Off-peak = halber Preis. Peak: 01:00–04:00 + 06:00–10:00 UTC.

### Routing (umgesetzt)

- `main` + `coding-orchestrator` → `deepseek/deepseek-v4-pro` (das Nötigste).
- `feature-dev-*` (6 Agents) → `deepseek/deepseek-v4-flash`.
- `agents.defaults.compaction.model` → `deepseek-v4-flash` (Summaries billig).
- `messages.responseUsage: "tokens"` → Usage-Footer sichtbar (`/usage cost` für lokale Kostensumme).

### Noch offen (Kosten)

- `models.providers.deepseek.models[].cost` (input/output/cacheRead/cacheWrite) für `/usage cost`-Schätzung — erst gegen laufende Version (2026.7.1) `config validate` prüfen, ob der DeepSeek-Plugin-Katalog die Preise schon mitliefert.
- Thinking-Mode für Nicht-Kern-Agents abschalten (falls Modell es erlaubt) — großer Output-Token-Sparer.

## ✅ Erledigt

- **Deploy-Hook**: push `main` → CI → GHCR → HTTPS-Webhook → `.149` pull + recreate (ohne Tailscale/SSH).
- **Semantisches Memory**: `agents.defaults.memorySearch.provider = "gemini"` (modell `gemini-embedding-001`) + `GEMINI_API_KEY` verdrahtet.

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

# Roadmap — OpenClaw Deployment (Momo)

Stand: 2026-08-19. Source of truth: dieses Repo.
Grundlage: OpenClaw-Docs (memory, memory-search, groups, usage-tracking, hooks, config-agents, config-channels).

## ✅ Erledigt

- **Deploy-Hook**: push `main` → CI → GHCR → HTTPS-Webhook → `.149` pull + recreate (ohne Tailscale/SSH).
- **Semantisches Memory**: `agents.defaults.memorySearch.provider = "gemini"` (modell `gemini-embedding-001`) + `GEMINI_API_KEY` verdrahtet.

## ⬜ Offen (korrigiert nach Docs)

| # | Baustein | Nativer Weg (Docs) | Status |
|---|----------|--------------------|--------|
| 1 | Vault mount | Vault rw nach `/quill` mounten + Sync via `obsidian-headless` (**ersetzt Syncthing**) | ✅ |
| 2 | Vault indexieren | `agents.defaults.memorySearch.extraPaths: ["/quill"]` | ⬜ (braucht #1) |
| 3 | Rollen je Gruppe | `channels.telegram.groups.<id>.systemPrompt` (nativ, KEIN `before_prompt_build`-Plugin) | ⬜ |
| 4 | Gruppen-Setup | `groupPolicy: "allowlist"` + `groupAllowFrom` + `requireMention` | ⬜ |
| 5 | Kosten-Sichtbarkeit | `messages.responseUsage: "tokens"` (Footer). Kein Hard-Limit in OpenClaw — Hard-Limit = Provider-Billing-Alert | ⬜ |
| 6 | *(optional)* QMD | `memory.backend: "qmd"` + Reranking | ⚪ |

## Dependency-Kette

```
Vault mount (#1) → Vault indexieren (#2) → Rollen/Gruppen (#3+#4) → Usage-Footer (#5) → (optional) QMD (#6)
```

## Konzeptionelle Korrekturen (aus Docs, 2026-08-19)

- **Rollen** = nativer `channels.telegram.groups.<id>.systemPrompt`, kein Plugin-Hook nötig.
- **Kosten** = Footer-Display (`messages.responseUsage`), kein harter €-Limit in OpenClaw. Hard-Limit nur Provider-seitig.
- **Vault-Sync** = Syncthing wird durch **Obsidian Sync** (`obsidian-headless`, offizieller Client) **abgelöst**. Der `feature/obsidian-headless`-Branch ist der **richtige Weg** — verfolgen und mergen, NICHT verwerfen.
- **Memory-Konzept**: `MEMORY.md` (durable, injiziert) + `memory/*.md` (daily, nur indexiert) + `extraPaths` (zusätzliche Verzeichnisse wie `/quill`).

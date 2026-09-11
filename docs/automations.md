# Automations (cron) — Nutzung, Sichtbarkeit & as-code-vs-fluent-Grenze

Stand: 2026-09-10. Source-of-Truth: dieses Repo.

## Was Automations sind

Automations (= `cron`) sind **Runtime**-Objekte, die der Gateway verwaltet — **nicht**
`config/openclaw.json` und **nicht** git. Das ist Absicht: Struktur ist as-code, Dynamik
ist fluent (siehe „Grenze" unten). Sie überleben Deploys im Gateway-State (Named Volume),
nicht im Repo.

## Sehen & steuern

```sh
openclaw automations list            # alle anzeigen
openclaw automations list --json     # volle Details
openclaw automations show <id>       # einzelne anzeigen
openclaw automations get <id>        # als JSON
openclaw automations add             # neue anlegen (guided)
openclaw automations edit <id>       # patchen
openclaw automations enable|disable <id>
openclaw automations rm <id>         # löschen
openclaw automations run <id>        # jetzt manuell ausführen (debug)
openclaw automations runs            # Lauf-Historie
openclaw automations status          # Scheduler-Status
```

Im Container: `docker compose exec -u node openclaw openclaw automations …`
(oder im Control-UI). Ausführung ist ein Live-Eingriff — nicht im Repo versioniert.

## Inventar (live, 10.09.)

| ID (gekürzt) | Name | Schedule | Delivery | Modell | Hinweis |
|---|---|---|---|---|---|
| `c057d497` | `rbm-loop` | every 15m | `announce → telegram:13494915` | Flash (Worker: **Pro**) | autonomer Dev-Loop `riftbreaker-battle-mod` |
| `9a886b77` | `rbbattle-overnight-loop` | every 30m | `none → telegram:13494915` | Flash (Worker: **Pro**) | autonomer Dev-Loop `riftbreaker-battle-mod` |
| `e66c2b15` | `heartbeat:main` | every 30m | — | Flash | Heartbeat |
| `e8b12993` | `memory-core` (Memory Dreaming) | `0 3 * * *` | — | Flash | Memory-Promotion |
| `b6e516a4` … `e45fd8fc` | `skill-collection-review` **×10** | every 7d (gestaffelt) | — | Flash | **redundant** (1 pro Agent) |

## Befund: die zwei Kosten-Treiber

`rbm-loop` (15 min) und `rbbattle-overnight-loop` (30 min) sind **autonome
Coding-Pipelines** für `momokli/riftbreaker-battle-mod`: sie clonen, reviewen, mergen,
releasen und spawnen dabei `operator`-Worker auf **`deepseek/deepseek-v4-pro`**
(`timeoutSeconds` 840 bzw. 1500). Ein `rbm-loop`-Lauf dauerte zuletzt **553 s**.

Das erklärt den größten Teil des Pro-/Operator-Verbrauchs aus #55 (operator 2092 Pro-Turns,
main 2533 Pro-Turns): die Loops erzeugen im 15/30-Minuten-Takt teure Pro-Worker.

Beide liefern an **`telegram:13494915`** → koppeln an das Telegram-Disable in PR #59:
nach dem Merge hätten diese Deliveries kein Ziel mehr.

## as-code vs. fluent

| **as-code** (git, reviewbar, reproduzierbar) | **fluent** (Runtime, CLI/UI, NICHT git) |
|---|---|
| `config/openclaw.json` (Gateway/Agents/Model/Tools) | Sessions/Transcripts |
| `config/agents/*.md` (Personas) | Memory (runtime `MEMORY.md` + Index) |
| `workspace/*.md` (SOUL/AGENTS/USER) | Workspace-Runtime-Files |
| `workspace/skills/*` | Device-Pairing + Auth (gh/deepseek) |
| Deployment: `Dockerfile`, `docker-compose.yml`, `entrypoint.sh`, `scripts/*`, `ansible/*`, `.github/workflows/*` | Plugins |
| | **Automations/cron** |

**Regel:** Struktur (was der Agent *ist* / wohin er routet / welche Tools) = as-code.
Dynamik (welche Sessions existieren, welche Automations laufen, wer gepaart ist) = fluent.
Automations gehören **nicht** in `config/openclaw.json` — das wäre „too static".

## Deployment-as-code: Stand (auditiert 10.09.)

- ✅ `Dockerfile`: Base-Image **gepinnt** (`openclaw/openclaw:2026.8.1-slim`), nicht `:slim`-float.
- ✅ `scripts/test-branch.sh`: nutzt **git worktree + korrekte Mounts** (`config:/openclaw-config:ro`), kein alter scp/save-load-Flow.
- ✅ Deploy: GHCR-Flow in CI + Webhook + `build-and-deploy.sh` (GHCR pull).
- → Kein Deployment-Diff nötig. (Die früheren „offen"-Notizen in `AGENTS.md` sind überholt.)

## Cleanup-Empfehlung (Live-Eingriff — nicht ausgeführt)

1. **10× `skill-collection-review`** auf 1 reduzieren (oder entfernen):
   ```sh
   for id in b6e516a4-9b71-461a-b921-92b8d89bdb42 d3a2030b-a1d6-4b83-a9c5-ba402079bf42 \
            6ee6f06d-62c0-40af-8e76-eaf5c64ffb64 1d92e790-80f3-44a9-a783-0f5a4b8be109 \
            51b468c7-924e-45a6-a251-51fa761bf416 217d8ae1-8b9c-467e-a476-fc88f1890e6d \
            7f71989f-fe3b-4116-b7a5-f223ad15b771 8abdd082-3851-4672-9bfc-1f4c60d01d82 \
            0a98aafd-876e-4da7-837c-a80cfd99970e e45fd8fc-9c09-4f2c-97ed-84e967faf14c; do
     openclaw automations rm "$id"
   done
   ```

2. **`rbm-loop` + `rbbattle-overnight-loop`** bewusst entscheiden:
   - Delivery von `telegram:13494915` wegrepointen (auf Web/App oder `none`).
   - Worker-Modell von Pro → Flash prüfen, oder Kadenz (15 min → 30/60 min) senken.
   - Oder temporär `disable`, wenn gerade kein aktiver `riftbreaker-battle-mod`-Push nötig.

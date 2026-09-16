# OpenClaw Deployment 🦞

Self-hosted AI agent gateway (OpenRouter), multi-agent coding pipeline, nativ deployed.

## Architecture

```
.149 — natives Gateway (systemd-User-Service openclaw-gateway.service)
  └─ openclaw gateway --port 18789  (Caddy → 127.0.0.1:18789)

planet — Session-Host-Node (nativ gepaart, tools.exec.node = "planet")
  └─ schwere Worker-Turns (cargo/test/Playwright)
```

Kein Docker, kein GHCR, kein Auto-Deploy. Konfiguration wird **manuell oder per Code**
auf die Instanz gespielt; die **laufende Installation auf `.149` ist Source-of-Truth**.
Dieses Repo liefert den deklarativen Seed (Config, Agent-Personas, Workspace-Docs).

## Quick Start (Bootstrap / Converge)

```sh
# Bootstrap / Re-Seed (einmalig, idempotent) — Node + OpenClaw + Plugins + Gateway-Service:
sudo bash scripts/setup-native.sh momo

# Deklarative Config aus git → Runtime (erhält Runtime-Felder wie auth/plugins/identity):
sudo bash scripts/converge-openclaw-config.sh momo

# Agent-Personas aus git → per-agent workspaces/<id>/AGENTS.md:
sudo bash scripts/sync-agent-personas.sh momo
```

Gateway-Service (nach Bootstrap):

```sh
sudo -u momo -H openclaw gateway status
journalctl --user -u openclaw-gateway.service -f
```

## Admin-SSH: Mesh-first (Tailscale)

Admin-SSH zu allen Hosts läuft **immer über Tailscale** (Aliase `lan` / `planet` →
`100.x`-Adressen), nie über Public-IPs. Public-IPs sind ausschließlich für
Service-Endpoints (Web, Webhook, Minecraft-Ports).

```sh
ssh lan       # .149  → 100.85.52.13  (Tailscale)
ssh planet    # Hetzner → 100.77.143.105 (Tailscale)
```

> ⚠️ **Nicht** `ssh root@65.21.27.234` — SSH auf planet läuft nach dem Incident vom
> 2026-09-01 (ufw-LIMIT auf 22/tcp → „Connection refused“) nur noch über Tailscale.

Details, Host-Tabelle und Diagnose-Reihenfolge (ufw vor fail2ban):
**[`docs/mesh-first-access.md`](docs/mesh-first-access.md)**.

## Infra-Zugriff

Die Agent-Umgebung hat Zugriff auf die Cloud-APIs von **Hetzner** (zwei Projekte),
**Contabo** und **Cloudflare** (z. B. für den Dekommissionierungs-Plan des
Hetzner-Stacks). Details und curl-Beispiele:
[docs/infra-access.md](docs/infra-access.md).

Die Secrets (`HETZNER_API_TOKEN_MITTELERDE`, `HETZNER_API_TOKEN_STORAGEBOXES`,
`CONTABO_CLIENT_ID`, `CONTABO_CLIENT_SECRET`, `CONTABO_API_USER`,
`CONTABO_API_PASSWORD`, `CLOUDFLARE_API_TOKEN`) liegen in `~/.openclaw/.env` auf `.149`
(gitignored, nie committen — siehe [Secrets](#secrets)). Schnell-Check aller APIs:

```sh
./scripts/infra-status.sh
```

## Agents

| Agent                 | Model          | Purpose                 |
| --------------------- | -------------- | ----------------------- |
| main                  | V4.1 Flash     | Default assistant       |
| coding-orchestrator   | V4.1 Flash     | 7-stage coding pipeline |
| feature-dev-planner   | V4.1 Flash     | Spec → user stories     |
| feature-dev-setup     | V4.1 Flash     | Branch + build baseline |
| feature-dev-developer | V4.1 Flash     | Code + tests            |
| feature-dev-verifier  | V4.1 Flash     | Quality gate            |
| feature-dev-tester    | V4.1 Flash     | Integration tests       |
| feature-dev-reviewer  | V4.1 Flash     | Final PR review         |

Modell-Routing: alle Agents laufen auf `openrouter/deepseek/deepseek-v4.1-flash`;
Fallback + heavy coding = `openrouter/deepseek/deepseek-v4-pro` (siehe
`config/openclaw.json` → `agents.defaults.model`).

## Files

```
├── .env.example           # Secret-Template → ~/.openclaw/.env auf .149
├── AGENTS.md              # Repo-Kontext & Handoff
├── SETUP.md               # GitHub App „momo-bot" Setup (PAT → App Migration)
├── ssh_config             # Tailscale SSH-Aliase (lan / planet) + git hosts
├── config/
│   ├── openclaw.json      # Gateway config, agents, channels, media tools
│   ├── agents/            # Pipeline agent personas
│   └── automations/       # A/B-Runner-Prompts (triage/pr-gate)
├── workspace/             # SOUL.md, AGENTS.md, USER.md, MEMORY.md, skills/
├── scripts/
│   ├── setup-native.sh            # Native Bootstrap (Node + OpenClaw + Plugins + Gateway-Service)
│   ├── converge-openclaw-config.sh# Deklarative Config → Runtime (Merge, erhält Runtime-Felder)
│   ├── sync-agent-personas.sh     # config/agents/*.md → workspaces/<id>/AGENTS.md
│   ├── analytics.sh               # Event-Level-Report (Chats/Tools/Errors/Usage/Kosten)
│   ├── automations-apply.sh       # Automation-Prompts as-code → Runtime
│   ├── gh-bot-auth.sh             # GitHub-App Token-Mint + hosts.yml je Bot
│   ├── {clanker,claw}-{gh,git}    # Bot-Identity-Wrapper
│   └── ...
└── docs/                  # Runbooks, Analysen, Skills-Referenzen
```

## Secrets

### Runtime (`~/.openclaw/.env` auf `.149`)

Nie committen. Copy `.env.example` → `~/.openclaw/.env` auf dem Gateway-Host
(die echte Secret-Datei liegt unter `/home/momo/.openclaw/.env` auf `.149`):

- `OPENROUTER_API_KEY` — LLM-Provider (primary + fallback laufen über OpenRouter)
- `KAGI_API` — Web search
- `TELEGRAM_BOT_TOKEN` — Telegram channel
- `OPENCLAW_GATEWAY_TOKEN` — Gateway auth token
- `GH_TOKEN` — GitHub CLI auth (**aktuell**: persönliches PAT, Scopes `repo, workflow`)
  — wird durch GitHub App „momo-bot" abgelöst (Migration: [SETUP.md](SETUP.md)).
- `GH_APP_ID` / `GH_APP_INSTALLATION_ID` — GitHub App „momo-bot“ (optional, migriert
  die Auth vom PAT weg; Installation-Tokens ~1h, Mint-per-Call via `gh-bot-auth.sh`)
- `GH_APP_PRIVATE_KEY_FILE` — Pfad zum App-Private-Key auf `.149`
  (`~/.secrets/`, chmod 600; `gh-bot-auth.sh` fällt auf die neueste `*.pem` zurück)
- `GROQ_API_KEY` — Speech-to-text (primary)
- `DEEPGRAM_API_KEY` — Speech-to-text (fallback)
- `GEMINI_API_KEY` — Image/Vision
- `HETZNER_API_TOKEN_MITTELERDE` — Hetzner Cloud API, Projekt **mittelerde** (Server)
- `HETZNER_API_TOKEN_STORAGEBOXES` — Hetzner Cloud API, Projekt **StorageBoxes**
- `CONTABO_CLIENT_ID` / `CONTABO_CLIENT_SECRET` — Contabo Cloud API v2 (OAuth2-Client)
- `CONTABO_API_USER` / `CONTABO_API_PASSWORD` — Contabo API User + API Password
- `CLOUDFLARE_API_TOKEN` — Cloudflare API

## Config vs Runtime State (Trennung)

Das Deployment trennt sauber **Git-Config** (versioniert, Seed) von **Runtime-State**
(nicht versioniert, nur auf `.149`):

```
Git (openclaw-deploy Repo)          Runtime (~/.openclaw auf .149)
─────────────────────────────       ─────────────────────────────────
config/openclaw.json  ──(converge)► openclaw.json
config/agents/*.md    ──(copy)──►   workspaces/<id>/AGENTS.md
workspace/*.md        ──(copy)──►   workspace/
.env.example          ──(seed)──►   .env
                                     ├── state/       (SQLite: Sessions, Pairing)
                                     ├── credentials/ (Channel-Creds)
                                     ├── devices/     (Device-Pairing)
                                     ├── npm/         (Provider-Plugins)
                                     └── agents/      (Per-Agent Sessions)
```

- `config/` + `workspace/` sind der deklarative Seed (Source-of-Truth für Config)
- `converge-openclaw-config.sh` merged die git-Config mit den Runtime-Feldern
  (auth/plugins/migrations/identity), statt blind zu überschreiben
- Runtime-State (Sessions, Pairing, Plugins) lebt **nur** in `~/.openclaw` — überlebt
  kein `git status`-Verschmutzen, wird nie committed
- Secrets (`.env`) werden vom nativen Gateway-Daemon aus `~/.openclaw/.env` gelesen

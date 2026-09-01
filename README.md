# OpenClaw Deployment 🦞

Self-hosted AI agent gateway with DeepSeek V4, multi-agent coding pipeline, and automated Docker builds.

## Architecture

```
push to GitHub (main)
  └─ GitHub Actions (self-hosted runner on projectmellon.de, Hetzner 20 cores)
       ├─ docker build (openclaw + obsidian-sync)
       ├─ push both images to GHCR (ghcr.io/momokli/*)
       └─ POST https://deploy.openclaw.simonklimke.de/deploy   # deploy webhook

.149 (systemd timer every 30min, or immediately via webhook)
  └─ scripts/build-and-deploy.sh
       ├─ git pull origin main                        # config sync
       ├─ docker pull both images from GHCR           # image sync
       ├─ docker compose up -d openclaw obsidian-sync
       └─ hash comparison → skip if nothing new
```

The **build runs in GitHub Actions**, not on projectmellon.de.
`build-and-deploy.sh` on `.149` only pulls from GHCR.

## Quick Start

### Deploy (Ansible)

```sh
set -a; source .env; set +a    # or export each key from .env.example

cd ansible && ansible-playbook -i inventory.ini deploy.yml
```

The playbook provisions secrets into `config/.env` (non-destructive) and sets up
the repo, systemd timer, Docker Compose, Caddy and DNS. File/config sync after the
initial bootstrap is handled by the systemd timer pulling from git.

### Test a feature branch (without disturbing main)

```sh
ssh lan
cd /opt/apps/openclaw
./scripts/test-branch.sh feat/my-feature
```

### Manual build trigger

```sh
ssh lan "sudo systemctl start openclaw-build.service"
ssh lan "sudo journalctl -u openclaw-build.service -f"
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

## Obsidian Sync (Headless)

`openclaw` mounts the shared `quill_data` volume at `/quill` (read-write). The
`obsidian-sync` sidecar keeps that volume in sync with an Obsidian Sync remote
vault, using the official
[`obsidian-headless`](https://github.com/obsidianmd/obsidian-headless) client
(Node.js 22+). It replaces the old Syncthing sidecar.

### One-time setup

1. Start the sidecar and log in interactively. Credentials are stored in the
   persistent `obsidian_config` named volume, so image rebuilds keep you logged
   in — nothing is committed to this repo:

   ```sh
   docker compose up -d obsidian-sync
   docker compose exec obsidian-sync ob login
   ```

2. Pick the remote vault to sync with:

   ```sh
   docker compose exec obsidian-sync ob sync-list-remote
   docker compose exec obsidian-sync ob sync-setup --vault "<Vault Name>" --path /data/quill
   ```

   For an **end-to-end encrypted** vault, pass the password:

   ```sh
   docker compose exec obsidian-sync ob sync-setup --vault "<Vault Name>" --path /data/quill --password "<pwd>"
   ```

3. Restart to start continuous sync (bidirectional, watches for changes):

   ```sh
   docker compose restart obsidian-sync
   ```

The sidecar runs `ob sync --continuous`, watching `/data/quill` and pushing/
pulling changes to/from the remote vault. Credentials live only in the
`obsidian_config` volume; the `--password` for E2E encryption is passed
interactively at setup time and is never written to disk in this repo.

## Make Changes

1. Edit files in this repo
2. `git commit && git push`
3. Auto-deploy triggers within 30 min via systemd timer
4. Or trigger immediately: `ssh lan "sudo systemctl start openclaw-build.service"`

## Image Build

Both images are built in **GitHub Actions** (self-hosted runner on projectmellon.de)
and pushed to **GHCR**:

- `ghcr.io/momokli/openclaw-deploy` — gateway (`Dockerfile`).
- `ghcr.io/momokli/openclaw-obsidian-sync` — Obsidian Sync sidecar (`Dockerfile.obsidian-sync`).

To add new tools: edit the relevant Dockerfile, push, and the workflow rebuilds on `main`.

## Deploy Webhook

Instead of waiting for the 30-minute systemd timer, a push to `main` also triggers
a deploy immediately via an HTTPS webhook:

- Receiver: `scripts/webhook.py` (runs as `openclaw-deploy-webhook.service` on `.149:18791`).
- Caddy proxies `deploy.openclaw.simonklimke.de` → `127.0.0.1:18791`.
- Shared secret: `/opt/apps/openclaw/webhook-token` on `.149` == GitHub repo secret `DEPLOY_TOKEN`.

The workflow (`build.yml`) POSTs to `/deploy` with `Authorization: Bearer $DEPLOY_TOKEN`.
The receiver validates the token and starts `openclaw-build.service`.

## Infra-Zugriff

Die Agent-Umgebung hat Zugriff auf die Cloud-APIs von **Hetzner** (zwei Projekte),
**Contabo**, **Cloudflare** und den Domain-Registrar **INWX** (z. B. für den
Dekommissionierungs-Plan des Hetzner-Stacks). Details und curl-Beispiele:
[docs/infra-access.md](docs/infra-access.md).

Die Secrets (`HETZNER_API_TOKEN_MITTELERDE`, `HETZNER_API_TOKEN_STORAGEBOXES`,
`CONTABO_CLIENT_ID`, `CONTABO_CLIENT_SECRET`, `CONTABO_API_USER`,
`CONTABO_API_PASSWORD`, `CLOUDFLARE_API_TOKEN`, `INWX_API_USER`,
`INWX_API_PASSWORD`) liegen in `config/.env` auf `.149` (gitignored, nie committen —
siehe [Secrets](#secrets)). Schnell-Check aller APIs:

```sh
./scripts/infra-status.sh
```

## Agents

| Agent                 | Model    | Purpose                 |
| --------------------- | -------- | ----------------------- |
| main                  | V4 Flash | Default assistant       |
| coding-orchestrator   | V4 Pro   | 7-stage coding pipeline |
| feature-dev-planner   | V4 Flash | Spec → user stories     |
| feature-dev-setup     | V4 Flash | Branch + build baseline |
| feature-dev-developer | V4 Flash | Code + tests            |
| feature-dev-verifier  | V4 Flash | Quality gate            |
| feature-dev-tester    | V4 Flash | Integration tests       |
| feature-dev-reviewer  | V4 Flash | Final PR review         |

## Files

```
├── Dockerfile              # Rust, git, jq, gh, himalaya, ansible
├── Dockerfile.obsidian-sync # obsidian-headless sidecar
├── docker-compose.yml      # OpenClaw + Obsidian Sync sidecar
├── entrypoint.sh           # Syncs git config into runtime home on start
├── SETUP.md                # GitHub App „momo-bot" Setup (PAT → App Migration)
├── ssh_config              # Git host keys (copied into image)
├── config/
│   ├── openclaw.json       # Gateway config, agents, channels, media tools
│   └── agents/             # Pipeline agent personas
├── workspace/              # SOUL.md, AGENTS.md, USER.md, MEMORY.md
├── scripts/
│   ├── build-and-deploy.sh # GHCR pull + atomic swap
│   ├── generate-github-token.sh  # GitHub-App JWT (RS256) → ~1h Installation-Token
│   ├── gh-app-auth.sh      # hosts.yml + credential helper mit frischem App-Token
│   ├── obsidian-sync.sh    # Idempotent headless-sync entrypoint
│   ├── webhook.py          # Deploy webhook receiver (port 18791)
│   ├── openclaw-deploy-webhook.service  # systemd unit for webhook.py
│   ├── test-branch.sh      # Test feature branch image in isolation
│   └── openclaw-build.{service,timer}  # systemd units
└── ansible/
    ├── deploy.yml          # Secrets provisioning + bootstrap
    ├── inventory.ini       # .149 host
    └── ansible.cfg
```

## Secrets

### Runtime (`config/.env` on `.149`)

Never committed to this repo. Copy `.env.example` → `config/.env` on the deploy host
(the real secret file lives at `/opt/apps/openclaw/config/.env` on `.149`):

- `DEEPSEEK_API_KEY` — LLM provider
- `KAGI_API` — Web search
- `TELEGRAM_BOT_TOKEN` — Telegram channel
- `OPENCLAW_GATEWAY_TOKEN` — Gateway auth token
- `GH_TOKEN` — GitHub CLI auth (**aktuell**: persönliches PAT, Scopes `repo, workflow`)
  — wird durch GitHub App „momo-bot" abgelöst (Migration: [SETUP.md](SETUP.md));
  bis dahin aktiv als git HTTPS credential helper (seeded via `entrypoint.sh` Schritt 5c)
- `GH_APP_ID` / `GH_APP_INSTALLATION_ID` — GitHub App „momo-bot" (optional, migriert
  die Auth vom PAT weg; Installation-Tokens ~1h → frisches Token bei Containerstart
  via `gh-app-auth.sh`, on-demand bei 401)
- `GH_APP_PRIVATE_KEY_FILE` — Pfad zum App-Private-Key **im Container**
  (Host: `~/.secrets/` read-only nach `/home/node/.secrets` gemountet, chmod 600;
  generate-github-token.sh nutzt den konfigurierten Pfad und fällt auf die
  neueste `*.pem` im Verzeichnis zurück — GitHub-Download-Namen wie
  `<app-slug>.<datum>.private-key.pem` funktionieren ohne Umbenennen)
- `GROQ_API_KEY` — Speech-to-text (primary)
- `DEEPGRAM_API_KEY` — Speech-to-text (fallback)
- `GEMINI_API_KEY` — Image/Vision
- `HETZNER_API_TOKEN_MITTELERDE` — Hetzner Cloud API, Projekt **mittelerde** (Server)
- `HETZNER_API_TOKEN_STORAGEBOXES` — Hetzner Cloud API, Projekt **StorageBoxes** (StorageBoxes, migriert von der Robot-API)
- `CONTABO_CLIENT_ID` / `CONTABO_CLIENT_SECRET` — Contabo Cloud API v2 (OAuth2-Client)
- `CONTABO_API_USER` / `CONTABO_API_PASSWORD` — Contabo API User (= CCP-Email) und API Password (separates Passwort aus my.contabo.com/api/details, password grant)
- `CLOUDFLARE_API_TOKEN` — Cloudflare API
- `INWX_API_USER` / `INWX_API_PASSWORD` — INWX DomRobot (Domain-Registrar, User + Passwort)

### GitHub repo secrets (Actions)

- `DEPLOY_TOKEN` — deploy webhook bearer (matches `/opt/apps/openclaw/webhook-token`).
- `GHCR_TOKEN` — classic PAT (scope `write:packages`) used for the GHCR `docker login` in `build.yml`.

## Config vs Runtime State (Trennung)

Das Deployment trennt sauber **Git-Config** (versioniert) von **Runtime-State** (nicht versioniert):

```
Git (openclaw-deploy Repo)          Runtime (Docker Named Volumes)
─────────────────────────────       ─────────────────────────────────
config/openclaw.json  ──(ro)──►    openclaw_home:/home/node/.openclaw
config/agents/*.md    ──(copy)─►     ├── state/       (SQLite: Sessions, Pairing)
workspace/*.md        ──(copy)─►     ├── credentials/ (Channel-Creds)
config/.env           ──(copy)─►     ├── devices/     (Device-Pairing)
                                     ├── npm/         (Plugins: deepseek)
                                     └── agents/      (Per-Agent Sessions)
                                    openclaw_workspace:/home/node/.openclaw/workspace
```

- `config/` und `workspace/` werden **read-only** als `/openclaw-config` gemountet (Source of Truth)
- Der `entrypoint.sh` synct Config/Personas beim Start in den Runtime-Home
- Runtime-State (Sessions, Pairing, Plugins) lebt in **Named Volumes** — überlebt Deploys, verschmutzt kein `git status`
- Secrets (`.env`) werden aus `config/.env` gelesen und in den Container injiziert

### Migration (einmalig, schon erledigt)

```sh
ssh lan "cd /opt/apps/openclaw && ./scripts/migrate-state.sh"
```

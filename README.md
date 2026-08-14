# OpenClaw Deployment 🦞

Self-hosted AI agent gateway with DeepSeek V4, multi-agent coding pipeline, and automated Docker builds.

## Architecture

```
push to GitHub (main)
  └─ GitHub Actions (self-hosted runner on projectmellon.de, Hetzner 20 cores)
       ├─ docker build
       └─ push to GHCR ghcr.io/momokli/openclaw-deploy:latest

.149 systemd timer (scripts/openclaw-build.{service,timer}, every 30min)
  └─ scripts/build-and-deploy.sh
       ├─ git pull origin main            # config sync
       ├─ docker pull ghcr.io/...:latest  # image sync
       ├─ docker compose up -d --force-recreate openclaw
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

## Make Changes

1. Edit files in this repo
2. `git commit && git push`
3. Auto-deploy triggers within 30 min via systemd timer
4. Or trigger immediately: `ssh lan "sudo systemctl start openclaw-build.service"`

## Image Build

Images are built in **GitHub Actions** (self-hosted runner on projectmellon.de) and
pushed to **GHCR**. The Dockerfile includes: Rust, git, gh CLI, himalaya (email), ansible.

To add new tools: edit `Dockerfile`, push, and the workflow rebuilds on `main`.

## Agents

| Agent                 | Model  | Purpose                 |
| --------------------- | ------ | ----------------------- |
| main                  | V4 Pro | Default assistant       |
| coding-orchestrator   | V4 Pro | 7-stage coding pipeline |
| feature-dev-planner   | V4 Pro | Spec → user stories     |
| feature-dev-setup     | V4 Pro | Branch + build baseline |
| feature-dev-developer | V4 Pro | Code + tests            |
| feature-dev-verifier  | V4 Pro | Quality gate            |
| feature-dev-tester    | V4 Pro | Integration tests       |
| feature-dev-reviewer  | V4 Pro | Final PR review         |

## Files

```
├── Dockerfile              # Rust, git, gh, himalaya, ansible
├── docker-compose.yml      # OpenClaw + Syncthing sidecar
├── entrypoint.sh           # Syncs git config into runtime home on start
├── ssh_config              # Git host keys (copied into image)
├── config/
│   ├── openclaw.json       # Gateway config, agents, channels, media tools
│   └── agents/             # Pipeline agent personas
├── workspace/              # SOUL.md, AGENTS.md, USER.md, MEMORY.md
├── scripts/
│   ├── build-and-deploy.sh # GHCR pull + atomic swap
│   ├── test-branch.sh      # Test feature branch image in isolation
│   └── openclaw-build.{service,timer}  # systemd units
└── ansible/
    ├── deploy.yml          # Secrets provisioning + bootstrap
    ├── inventory.ini       # .149 host
    └── ansible.cfg
```

## Secrets

Never committed to this repo. Copy `.env.example` → `config/.env` on the deploy host
(the real secret file lives at `/opt/apps/openclaw/config/.env` on `.149`):

- `DEEPSEEK_API_KEY` — LLM provider
- `KAGI_API` — Web search
- `TELEGRAM_BOT_TOKEN` — Telegram channel
- `OPENCLAW_GATEWAY_TOKEN` — Gateway auth token
- `GH_TOKEN` — GitHub PR creation
- `GROQ_API_KEY` — Speech-to-text (primary)
- `DEEPGRAM_API_KEY` — Speech-to-text (fallback)
- `GEMINI_API_KEY` — Image/Vision

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

# OpenClaw Deployment 🦞

Self-hosted AI agent gateway with DeepSeek V4, multi-agent coding pipeline, and automated Docker builds.

## Architecture

```
push to GitHub
  └─ systemd timer (every 30min) on .149 (lan)
       ├─ git pull origin main
       ├─ if new commit → scp Dockerfile → projectmellon.de (Hetzner, 20 cores)
       ├─ docker build -t openclaw:<commit-hash>
       ├─ docker save | gzip → pipe to .149
       └─ docker load + compose up
```

## Quick Start

### Deploy (Ansible stamp)

```sh
export DEEPSEEK_API_KEY="sk-..."
export KAGI_API="..."
export TELEGRAM_BOT_TOKEN="123:..."
export GH_TOKEN="ghp_..."

cd ansible && ansible-playbook deploy.yml
```

### Test a feature branch (without disturbing main)

```sh
ssh lan
cd /opt/apps/openclaw

# Build + test on port 18790
./scripts/test-branch.sh feat/my-feature

# Verify
curl http://127.0.0.1:18790/healthz

# Promote to main
docker tag openclaw-test:feat-my-feature openclaw-local:latest
docker compose up -d openclaw

# Cleanup
docker rm -f openclaw-test
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

Images are built on **projectmellon.de** (fast Hetzner server) and transferred to `.149`.
The Dockerfile includes: Rust, git, gh CLI, himalaya (email).

To add new tools: edit `Dockerfile`, push, trigger build.

## Agents

| Agent | Model | Purpose |
|-------|-------|---------|
| main | V4 Pro | Default assistant |
| coding-orchestrator | V4 Pro | 7-stage coding pipeline |
| feature-dev-planner | V4 Pro | Spec → user stories |
| feature-dev-setup | V4 Pro | Branch + build baseline |
| feature-dev-developer | V4 Pro | Code + tests |
| feature-dev-verifier | V4 Pro | Quality gate |
| feature-dev-tester | V4 Flash | Integration tests |
| feature-dev-reviewer | V4 Pro | Final PR review |

## Files

```
├── Dockerfile              # Rust, git, gh, himalaya
├── docker-compose.yml      # OpenClaw + Syncthing sidecar
├── ssh_config              # Git host keys
├── config/
│   ├── openclaw.json       # Gateway config, agents, channels
│   └── agents/             # Pipeline agent personas
├── workspace/              # SOUL.md, AGENTS.md, USER.md, MEMORY.md
├── scripts/
│   ├── build-and-deploy.sh # CI/CD: git pull → build → deploy
│   ├── test-branch.sh      # Test feature branch image in isolation
│   └── openclaw-build.{service,timer}  # systemd units
└── ansible/
    └── deploy.yml          # Ansible stamp deployment
```

## Secrets

Never committed to this repo. Set via environment variables or `.env` file on the host:

- `DEEPSEEK_API_KEY` — LLM provider
- `KAGI_API` — Web search
- `TELEGRAM_BOT_TOKEN` — Telegram channel
- `GH_TOKEN` — GitHub PR creation
- `GROQ_API_KEY` — Speech-to-text (primary)
- `DEEPGRAM_API_KEY` — Speech-to-text (fallback)

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

- `config/` wird **read-only** als `/openclaw-config` gemountet (Source of Truth)
- Der `entrypoint.sh` synct Config/Persons beim Start in den Runtime-Home
- Runtime-State (Sessions, Pairing, Plugins) lebt in **Named Volumes** — überlebt Deploys, verschmutzt kein `git status`
- Secrets (`.env`) werden aus `config/.env` gelesen und in den Container injiziert

### Migration (einmalig, schon erledigt)

```sh
ssh lan "cd /opt/apps/openclaw && ./scripts/migrate-state.sh"
```

---
name: deploy-status
description: "OpenClaw-Deploy (GHCR-CI/CD, Deploy-Webhook, .149) prüfen und debuggen: Flow, Status-Checks, Gotchas."
metadata:
  {
    "openclaw":
      {
        "requires": { "bins": ["gh", "ssh"] },
      },
  }
---

# Deploy-Status (OpenClaw)

Use für Status-Checks und Debugging des OpenClaw-Deployments: GHCR-CI/CD-Flow, Deploy-Webhook und `.149`.

## Flow (IST)

```text
push main
  → GitHub Actions (self-hosted Runner auf projectmellon.de, Hetzner)
      ├ docker build openclaw + obsidian-sync
      ├ push beide → GHCR
      │   ghcr.io/momokli/openclaw-deploy / ghcr.io/momokli/openclaw-obsidian-sync
      └ POST https://deploy.openclaw.simonklimke.de/deploy   (Authorization: Bearer $DEPLOY_TOKEN)

.149: systemd-Timer alle 30min ODER sofort via Webhook
  → /opt/apps/openclaw/scripts/build-and-deploy.sh
      ├ git pull origin main
      ├ docker pull beide Images aus GHCR
      ├ Hash-Vergleich → skip wenn nichts neu
      ├ docker compose up -d --force-recreate --remove-orphans openclaw obsidian-sync
      ├ healthz-Check (fail-closed) → Caddy-Netzwerk reconnect → Hashes persistieren
```

## Zugriff

- `.149` via Tailscale: `ssh momo@lan` (= `100.85.52.13`; LAN-IP `192.168.178.149`).
- Deploy-Script: `/opt/apps/openclaw/scripts/build-and-deploy.sh`
- Webhook-Receiver: `scripts/webhook.py` (Port `18791`), systemd-Unit `openclaw-deploy-webhook.service`.
- Webhook startet `openclaw-build.service` → führt `build-and-deploy.sh` aus.

## Status prüfen

GitHub-Run (lokal, mit `GH_TOKEN`):

```bash
gh run list --branch main
gh run view <run-id> --log-failed
```

Auf `.149`:

```bash
ssh momo@lan 'docker ps --filter name=openclaw'
ssh momo@lan 'docker logs openclaw --tail 50'
ssh momo@lan 'docker logs openclaw-obsidian-sync --tail 50'
ssh momo@lan 'docker exec openclaw curl -sf http://localhost:18789/healthz'
```

Compose-Status (aus dem Deploy-Dir, Projektname ist fix `openclaw`):

```bash
ssh momo@lan 'cd /opt/apps/openclaw && docker compose ps'
```

## Gotchas

1. **Build NICHT mehr lokal auf projectmellon.de** — läuft in GitHub Actions (`runs-on: self-hosted`). projectmellon.de ist nur der Runner.
2. **`.149` pullt NUR aus GHCR** — kein lokaler Build/Save-Load mehr.
3. Push nach GHCR nur auf `main`; PRs bauen nur, pushen nicht.
4. GHCR-Login nutzt `GHCR_TOKEN` (classic PAT, `write:packages`) — built-in `github.token` scheitert (`permission_denied: write_package`).
5. Webhook-Shared-Secret: `/opt/apps/openclaw/webhook-token` (NICHT in git); GitHub hält denselben Wert als Repo-Secret `DEPLOY_TOKEN`. HTTP 401 = Token-Mismatch.
6. Deploy-Skip basiert auf Hash-Files unter `/opt/apps/openclaw/`: `.deploy-git-hash`, `.deploy-img-hash`, `.deploy-obsidian-img-hash`. „No changes — skipping" heißt nur: alle drei gleich geblieben.
7. Healthz-Check ist **fail-closed**: wird der Container nicht healthy, werden die Hashes NICHT persistiert → nächster Run versucht erneut.

## Stop-Regel

Deploy „hängt" oder „No changes" obwohl ein Change erwartet wird → NICHT blind Webhook re-triggern oder `docker compose up` variieren. Erst: (1) `gh run list` + Run-Log, (2) Hash-Files + Image-IDs auf `.149` vergleichen, (3) Webhook 401/Token prüfen. Unklar → Momo fragen.

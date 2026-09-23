# Migration: OpenClaw-Gateway von `.149` → `planet`

Status: **durchgeführt** 2026-09-23 (Seed für den laufenden Zustand; Runtime bleibt Source-of-Truth auf `planet`).

## Warum

`.149` ist eine **KVM-VM** (`QEMU HARDDISK`, Xeon E5-2650 v2, 16 vCPU) mit einer **einzelnen
rotierenden 1,6-TB-Partition** als Root — darauf ~50 Container, Download-Stack und Backups.
Am 2026-09-23 steckte der Writeback (`flush-8:0` > 1 h in `D`, 8,5 GB dirty), der
Gateway-Event-Loop fror wiederholt ~100 s ein, jede Management-RPC der CLI lief in
Timeouts und der `planet`-Node verlor den Rückkanal. `planet` hat dagegen **NVMe**
(`/srv`, 647 G frei) und mehr Cores.

## Zielzustand (IST nach der Migration)

```
planet
  ├─ openclaw-gateway.service (systemd --user)
  │    OPENCLAW_STATE_DIR=/srv/openclaw        (NVMe)
  │    OPENCLAW_CONFIG_PATH=/srv/openclaw/openclaw.json
  │    gateway.bind = loopback  (127.0.0.1:18789)
  ├─ openclaw-node.service  → ws://127.0.0.1:18789   (lokal, kein Umweg über DNS/Caddy)
  ├─ mellon-caddy (host-network) :443 → reverse_proxy 127.0.0.1:18789
  └─ DNS: openclaw.simonklimke.de  A → 65.21.27.234  (Cloudflare, proxied=false)

.149
  └─ openclaw-gateway.service: disabled + inactive (State unangetastet = Rollback)
```

## Schritte

1. **State umziehen** — Pre-Sync online (`rsync -aHAX`), Gateway auf `.149` stoppen,
   Delta-Sync mit `--delete`. (~33 GiB, u.a. `workspace/` 22 G und `agents/` 2 G.)
2. **Config anpassen** (`/srv/openclaw/openclaw.json`):
   - alle `/home/momo/.openclaw`-Pfade → `/srv/openclaw` (21 Vorkommen: `agents.entries.*.agentDir`
     und alle `workspace`-Pfade — sonst laden die Agent-Personas nicht),
   - `gateway.bind`: `lan` → `loopback`,
   - `channels.telegram` entfernen (Token auch aus `.env` und aus `OPENCLAW_SERVICE_MANAGED_ENV_KEYS`,
     sonst konfiguriert der Gateway den Kanal aus dem Env automatisch neu),
   - `gateway.trustedProxies`: `["127.0.0.1/32"]` (Caddy läuft host-network, kommt also von loopback).
3. **Service-Unit manuell schreiben** — `openclaw gateway install` **verweigert** einen Service,
   wenn `OPENCLAW_STATE_DIR` nicht der kanonische Pfad ist. Unit in
   `~/.config/systemd/user/openclaw-gateway.service` mit
   `OPENCLAW_STATE_DIR`/`OPENCLAW_CONFIG_PATH` und `RequiresMountsFor=/srv`.
4. **Toolchain + Bot-Identität** nach `planet` (fehlte dort komplett):
   `~/.local/bin/{clanker-gh,clanker-git,claw-gh,claw-git,gh-bot-auth.sh,generate-github-token.sh,rift-focus-milestone.sh,rift-stale-dispatch.sh}`,
   `~/.config/gh-bots/`, `~/.config/gh-momo-clanker/`, `~/.config/gh-momo-claw/`, `~/.secrets/*.pem`.
   (`gh`, `jq`, `git` sind auf `planet` unter `/usr/bin` vorhanden.)
5. **Caddy** — Block an `/home/momo/Caddyfile`, `docker exec mellon-caddy caddy reload`.
   Cert kommt per DNS-01 (Cloudflare) — DNS darf dabei noch auf `.149` zeigen.
6. **DNS** — Cloudflare-A-Record `openclaw.simonklimke.de` → `65.21.27.234`, `proxied=false`.
7. **Cron-Store-Key** — siehe Gotcha 3: die migrierten Jobs lagen in der SQLite unter dem
   alten State-Pfad als `store_key` und waren dadurch unsichtbar.

## Gotchas (live aufgetreten)

1. **`openclaw gateway install` bricht ab** bei nicht-kanonischem State-Dir
   (`service management skipped: non-default state dir`). Lösung: Unit von Hand.
2. **Plugin-Verifikation blockiert den Start** (`exit 78/CONFIG`): `@openclaw/perplexity-plugin`
   zieht `2026.9.5`, Runtime ist `2026.9.4`. Lösung: `openclaw update repair`, dann Start.
3. **Cron-Jobs hängen am `store_key`** = Pfad des State-Roots (`<state>/cron/jobs.json`,
   logischer Namespace, keine echte Datei). Nach dem Umzug landeten die live definierten
   Jobs (`rift-triage`, `rift-pr-gate`, `ocd-*`) unter dem alten Key und waren für
   `openclaw automations list` unsichtbar. Fix (Gateway gestoppt, DB-Update):
   ```sql
   UPDATE cron_jobs SET store_key='/srv/openclaw/cron/jobs.json'
   WHERE store_key='/home/momo/.openclaw/cron/jobs.json'
     AND declaration_key IN ('rift-triage:main','rift-pr-gate:main','ocd-triage:main','ocd-pr-gate:main');
   DELETE FROM cron_jobs WHERE store_key='/home/momo/.openclaw/cron/jobs.json';
   ```
   Die `job_json`-Spalte enthält die vollständige Live-Definition inkl. Prompt.
4. **`-v /home/momo/Caddyfile:/etc/caddy/Caddyfile` wird stale**, wenn die Datei ersetzt
   (neuer Inode) statt in-place geändert wird — der Container sah die alte Version, bis er
   per `docker restart mellon-caddy` neu gebunden wurde. Nach Caddyfile-Änderungen:
   `caddy reload` **und** bei ausbleibender Wirkung Container-Restart prüfen.
5. **`proxy_attribution_required` (403)** für Clients, die über Caddy kommen, wenn
   `gateway.trustedProxies` das Proxy-Netz nicht kennt. Gleiches Symptom für den
   Node-Rückkanal → Node bewusst auf `ws://127.0.0.1:18789` umgestellt.
6. **Fehlende Toolchain scheitert still**: die ersten Cron-Läufe liefen ohne
   `clanker-gh`/`rift-focus-milestone.sh` los und hingen; erst nach dem Nachinstallieren
   lief ein Pass sauber durch (`ok`).

## Verifikation

- `openclaw gateway status` → `Probe target: ws://127.0.0.1:18789`, `bind=loopback`.
- `openclaw sessions list --all-agents` → 1225 Sessions, 15 Stores (State vollständig).
- `openclaw nodes list` → `planet` „just now“.
- `curl https://openclaw.simonklimke.de/` → **200**, Control-UI.
- `openclaw automations list --all` → `rift-triage` (1 h) und `rift-pr-gate` (30 m) `ok`,
  `ocd-*` `disabled`.
- Triage-Lauf (`openclaw automations run <uuid>`) → Receipt `ok`, Status-Log geschrieben,
  Dispatch von `#393` (Label + `coding-orchestrator`-Worker).

## Rollback

`.149:~/.openclaw` ist unverändert; dort ist der Service nur `disable`d (nicht entfernt).
Rollback = DNS zurück auf `80.131.52.54`, `systemctl --user enable --now openclaw-gateway.service` auf `.149`.

## Offen / Follow-ups

- Secrets (`.env`) liegen jetzt auf **zwei** Hosts → Kopie auf `.149` entfernen.
- `/home/momo/rift-focus-deploy/` (Deploy-Baum auf `.149`) ist obsolet, seit `.149` keinen
  Gateway mehr fährt.
- `skill-workshop`-Migrationswarnungen (`/home/node/.openclaw/...` aus der Docker-Ära) sind
  kosmetisch (`openclaw doctor --fix` optional).
- Dashboard-Log-Flut „Worker disk-space probe failed … session-owned workspace“ ist
  **vorbestehend** und unabhängig von der Migration.
- `planet` `/` ist ein **RAID0** (keine Redundanz) und zu 92 % voll; `~/.openclaw` liegt
  bewusst auf `/srv`, aber `/var/lib/docker` weiterhin auf `/`.

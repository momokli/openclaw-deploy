# Runbook — Aero-Test RCON-Fix (Issue #43)

Betrifft die Minecraft-Test-Instanz `aero-test` auf planet (`/srv/aero-test`, Port `25582`).
Versioniert den bislang nur ad-hoc angewendeten RCON-Fix.

## Symptom

`docker compose stop aero-test` beendet den Server **nicht** graceful: itzg wartet
`stop_grace_period` (120 s) ab und killt dann per SIGKILL. Beim Klon war RCON im Container
nicht aktiv, obwohl `default-server.properties` `enable-rcon=true` erwartete.

## Root Cause

Zwei Ebenen greifen ineinander:

1. **Compose:** Ohne `ENABLE_RCON`/`RCON_PASSWORD` konfiguriert das itzg-Image kein RCON und
   kann `stop` nicht über RCON fahren.
2. **Pack-Mod „default-server-properties":** Beim ersten Boot überschreibt es
   `server.properties` aus `default-server.properties` und lässt `enable-rcon=false` stehen.
   Ein nur im Compose gesetztes RCON wird dadurch zur Laufzeit wieder ausgeschaltet.

Log-Beweis des funktionierenden Zustands (aero-test, 2026-09-02):

```
Thread RCON Listener started
RCON running on 0.0.0.0:25575
[Rcon: Stopping the server]          <- graceful stop über RCON
```

## Fix (Bestandteile)

| # | Artefakt | Zweck |
|---|---|---|
| 1 | `scripts/aero-test/compose.template.yaml` | Compose-Vorlage mit `ENABLE_RCON: "TRUE"`, `RCON_PASSWORD`, `stop_grace_period: 120s` |
| 2 | `scripts/aero-test/apply-rcon-fix.sh` | idempotenter Patch von `default-server.properties` **und** `server.properties` |
| 3 | RCON-Passwort in `/srv/aero-test/.env` (nicht im Repo) | Wert für `RCON_PASSWORD` |

Beides ist nötig: Compose aktiviert RCON, der Properties-Patch verhindert, dass der Pack-Mod es
beim Boot wieder abschaltet.

## Verfahren (nächster Klon)

```bash
# 1. Compose aus der Vorlage übernehmen
cp scripts/aero-test/compose.template.yaml /srv/aero-test/compose.yaml

# 2. RCON-Passwort setzen (nicht ins Repo committen)
printf 'RCON_PASSWORD=%s\n' "$(openssl rand -hex 16)" > /srv/aero-test/.env
chmod 600 /srv/aero-test/.env

# 3. Properties patchen (idempotent, mehrfach ausführbar)
cd /srv/aero-test
RCON_PASSWORD="$(sed -n 's/^RCON_PASSWORD=//p' .env)" \
  /srv/aero-test/apply-rcon-fix.sh --data-dir ./data

# 4. Start
docker compose up -d
```

Schritt 3 wird beim nächsten Klon von #42 (`clone-prod.sh`) mit übernommen.

## Verifikation

```bash
# Properties korrekt?
grep -E '^(enable-rcon|rcon\.password|rcon\.port|enable-query)=' /srv/aero-test/data/default-server.properties
grep -E '^(enable-rcon|rcon\.password|rcon\.port|enable-query)=' /srv/aero-test/data/server.properties

# Läuft RCON?
docker logs aero-test 2>&1 | grep -E "RCON running on|RCON Listener started"

# RCON antwortet? (rcon-cli im itzg-Image liest RCON_PASSWORD aus der Container-Env)
docker exec -i aero-test rcon-cli list

# Graceful-Stop-Beweis (sollte "[Rcon: Stopping the server]" loggen, kein SIGKILL)
docker compose stop aero-test && docker logs aero-test 2>&1 | tail -5
```

Erwartung: `enable-rcon=true`, Passwort gesetzt, `rcon.port=25575`, `enable-query=false`;
RCON-Listener auf `0.0.0.0:25575`; `list` liefert die Spielerliste.

## DoD-Check (Issue #43)

- Compose-Template inkl. RCON-Konfiguration ist im Repo (`scripts/aero-test/compose.template.yaml`).
- Fix im Runbook dokumentiert (diese Datei).
- Nächster Klon übernimmt den Fix aus der Vorlage + `apply-rcon-fix.sh` → kein Ad-hoc-Edit mehr.
- Offline-Nachweis: `tests/aero-test/run.sh` (alle Checks PASS).

## Rollback

RCON-Fix entfernen: im Compose `ENABLE_RCON`/`RCON_PASSWORD` löschen und die beiden
Property-Zeilen auf die Pack-Defaults zurücksetzen (`enable-rcon=false`, `rcon.password=`
entfernen) — dann stoppt `docker compose stop` wieder per SIGKILL nach Timeout.

## Siehe auch

- `docs/equip-agents.md` Block B5 (Kontext #41/#42/#43).
- Issue #42: idempotentes Klon-Setup (`clone-prod.sh`) + Preflight.
- Issue #44: FTB-Server-Installer-Persistenz (gleiche aero-Test-Familie).

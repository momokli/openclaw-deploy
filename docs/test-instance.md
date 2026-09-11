# Runbook — Aero-Test-Instanz (`aero-test`) auf planet (Issue #42)

Betrifft die Minecraft-**Test**-Instanz `aero-test` auf `planet` (`/srv/aero-test`, Port `25582`).
Zweck: Base-Update-Tests am PROD-Klon, ohne die PROD-Instanz `aero` (`/srv/aero`, Port `25580`)
zu berühren. Ergänzt das RCON-Runbook `docs/aero-test-rcon.md` (Issue #43).

> **Schritt 0 ist Pflicht.** Runbooks gehen **nicht** mehr von einer existierenden
> `aero-test`-Instanz aus. Erst Preflight, dann klonen — nie ad hoc improvisieren.

## Schritt 0 — Preflight: „Instanz vorhanden? sonst klonen"

Historischer Drift-Fall (2026-09-02): `/srv/aero-test` enthielt nur ein verwaistes
`monitoring/`, aber **keinen Container**. Der Test-Deploy lief ins Leere und die Instanz wurde
ad hoc rekonstruiert. Der Preflight erkennt genau das.

```bash
# Läuft ein aero-test-Container?
docker ps -a --format '{{.Names}}' | grep -qx aero-test && echo "vorhanden" || echo "fehlt/Drift"

# Ausführbarer Preflight (Exit 0 = vorhanden, 3 = fehlt/Drift):
scripts/clone-prod.sh --check
```

Ergebnis und Reaktion:

| `--check` | Bedeutung | Aktion |
|---|---|---|
| Exit `0` | Container `aero-test` existiert | weiter mit Schritt 1 |
| Exit `3` (Drift) | Verzeichnis/Compose da, Container fehlt | `scripts/clone-prod.sh --start` |
| Exit `3` (missing) | nichts vorhanden | `scripts/clone-prod.sh --start` |

Klonen/Sicherstellen (idempotent — zweiter Lauf ist ein No-op):

```bash
# Auf planet, aus einem openclaw-deploy-Checkout:
ssh planet 'cd /path/to/openclaw-deploy && scripts/clone-prod.sh --start'
```

Alternativ Script + Vorlage kopieren (das Script braucht die #43-Artefakte neben sich):

```bash
ssh planet 'mkdir -p /tmp/clone-prod/scripts/aero-test'
scp scripts/clone-prod.sh planet:/tmp/clone-prod/scripts/
scp scripts/aero-test/compose.template.yaml scripts/aero-test/apply-rcon-fix.sh \
    planet:/tmp/clone-prod/scripts/aero-test/
ssh planet 'bash /tmp/clone-prod/scripts/clone-prod.sh --start'
```

Was `clone-prod.sh` macht (Details: `--help`):

1. **Preflight** — vorhandener Container ⇒ No-op.
2. **Compose** aus der versionierten Vorlage `scripts/aero-test/compose.template.yaml` (#43)
   nach `/srv/aero-test/compose.yaml` kopieren.
3. **Freien Port** ab `25582` vergeben (`ss`/`netstat` + docker-Ports) und in `.env` schreiben.
4. **data klonen** per `rsync -a --delete` aus `/srv/aero/data` — **ohne** `world`, `world.*`,
   `ftbbackups3`, `logs`, `crash-reports`. Die Test-Welt wird beim ersten Boot frisch generiert;
   PROD-Backups (13 G) und die PROD-Welt (5.6 G) werden nicht blind kopiert.
5. **RCON-Test-Passwort** in `/srv/aero-test/.env` (`chmod 600`) setzen/schreiben
   (`--password`/`RCON_PASSWORD`, sonst generiert via `openssl rand -hex 16`).
6. **Properties patchen** via `scripts/aero-test/apply-rcon-fix.sh` (#43), damit RCON den
   `default-server-properties`-Reset übersteht (Ursache: `docs/aero-test-rcon.md`).

Die Vorlage und der Properties-Patch kommen aus **#43** (Compose-Template + RCON-Fix). Sind sie
im Checkout nicht vorhanden, bricht `clone-prod.sh` mit Exit `4` und klarer Meldung ab (kein
stiller Ad-hoc-Fix).

## IST-Stand (verifiziert auf planet, 2026-09-12)

| Artefakt | Pfad | Rolle |
|---|---|---|
| PROD-Compose | `/srv/aero/compose.yaml` | kanonisch: Service `aero` + `aero-webui`, `${MC_PORT:-25580}`, metrics `19565:19565`, `${DATA_DIR:-./data}` |
| PROD-Daten | `/srv/aero/data` | 25 G (`ftbbackups3` 13 G, `world` 5.6 G, `world.broken-*` 5.1 G, `mods` 912 M, `libraries` 177 M, `config` 103 M, `kubejs` 91 M, `datapacks` 53 M) |
| TEST-Compose | `/srv/aero-test/compose.yaml` | Service `aero-test`, `container_name: aero-test`, Port `25582:25565`, `stop_grace_period: 120s`, `MEMORY 6G`, `ENABLE_RCON TRUE`, `RCON_PASSWORD <.env>`, `restart: "no"` |
| TEST-Daten | `/srv/aero-test/data` | 1.4 G; frische `world` (20 M); `ftbbackups3`/`world.broken*` nicht geklont |
| TEST-Env | `/srv/aero-test/.env` | `MC_PORT`, `CONTAINER_NAME`, `DATA_DIR`, `MEMORY`, `RCON_PASSWORD` (gitignored, `chmod 600`) |
| Container | `docker ps -a` | PROD `aero` Up (healthy), `aero-webui`, `aero-grafana`, `aero-prometheus`; **kein** `aero-test` |
| Belegte Ports | `ss -tln` | 25565, 25566, 25567, 25570, 25580 → **25582 ist frei** |

Werkzeuge auf planet: `docker compose` v2.29.7, `rsync`, `python3`, `flock`, `sudo`
(kein `yq`/`jq`).

## Test-Deploy-Ablauf (nach Schritt 0)

```bash
# 1. PROD-Backup ziehen (vor jeder Änderung)
ssh planet 'sudo /srv/aero/data/ftbbackups3/backup.sh' 2>/dev/null \
  || echo "Backup-Schritt gemäß PROD-Runbook manuell ausführen"

# 2. Preflight / ensure (idempotent)
ssh planet 'cd <checkout> && scripts/clone-prod.sh'

# 3. Starten
ssh planet 'cd /srv/aero-test && docker compose up -d'

# 4. Boot beobachten (modded Server braucht Minuten)
ssh planet 'docker logs -f aero-test'

# 5. Update einspielen (jeweils PROD-Änderung zuerst am Klon testen)
#    ... Test-spezifischer Schritt des jeweiligen Issues ...

# 6. Verifikation (siehe unten), dann PROD erst nach grünem Test anfassen.
```

## Verifikation

```bash
# Instanz vorhanden?
ssh planet 'docker ps --filter name=aero-test --format "{{.Names}} {{.Status}} {{.Ports}}"'

# RCON aktiv? (Details: docs/aero-test-rcon.md)
ssh planet 'docker logs aero-test 2>&1 | grep -E "RCON running on|RCON Listener started"'

# Graceful-Stop-Beweis (kein SIGKILL nach stop_grace_period)
ssh planet 'docker compose -f /srv/aero-test/compose.yaml stop && docker logs aero-test 2>&1 | tail -5'
```

Erwartung: Container `aero-test` läuft, Port aus `.env` gemappt, RCON-Listener auf
`0.0.0.0:25575`, `[Rcon: Stopping the server]` beim Stop.

## Troubleshooting

| Symptom | Ursache | Fix |
|---|---|---|
| Kein Container, aber `/srv/aero-test` existiert | Drift (Ad-hoc-Reste) | `scripts/clone-prod.sh --start` |
| `clone-prod.sh` Exit `4` | Vorlage/`apply-rcon-fix.sh` fehlt (#43 nicht im Checkout) | #43 mergen/checkout oder `--compose-template`/`--rcon-fix` angeben |
| Port belegt | anderer MC-Server auf planet | Script vergibt automatisch den nächsten freien Port ≥ 25582 |
| `Permission denied` in `/srv/aero-test` | Verzeichnis `root`-owned | `sudo scripts/clone-prod.sh` |
| `docker compose stop` killt per SIGKILL | RCON im Container aus | `docs/aero-test-rcon.md` (Properties-Reset durch Pack-Mod) |

## Aufräumen / Rollback

```bash
ssh planet 'docker compose -f /srv/aero-test/compose.yaml down'
# Daten behalten (Neustart ohne Re-Klon) oder komplett entfernen:
ssh planet 'sudo rm -rf /srv/aero-test'
```

`clone-prod.sh --force` baut Compose/data neu auf; `--refresh-data` spiegelt `data` erneut
(auch wenn bereits gefüllt).

## DoD-Check (Issue #42)

- [x] Preflight „Instanz vorhanden? sonst klonen" als **Schritt 0** dokumentiert (diese Datei).
- [x] Idempotentes Setup-Script `scripts/clone-prod.sh` (compose + data klonen, freier Port,
      RCON-Test-Passwort setzen).
- [x] Runbook `docs/test-instance.md` an IST-Stand angeglichen (Tabelle oben, planet 2026-09-12).
- [x] Offline-Nachweis: `tests/clone-prod/run.sh` (red-before-green, alle Checks PASS).

## Siehe auch

- `docs/aero-test-rcon.md` — RCON-Fix-Compose-Template + Properties-Patch (Issue #43).
- `docs/equip-agents.md` Block B4 — Kontext & verifizierter IST-Stand.
- Issue #42: https://github.com/momokli/openclaw-deploy/issues/42

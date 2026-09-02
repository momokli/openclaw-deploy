# Equip-Agents-Runbook — Umgebungs-Doku & Workarounds für Agent-/WF-Arbeit

Stand: 2026-09-02. Zweck: künftige Agents/Workflows sollen die dokumentierten
Umgebungs-/Werkzeugfakten kennen, **bevor** sie bauen — statt jedes Mal dieselben
Workarounds neu zu erfinden (Meta-Issue: [#34](https://github.com/momokli/openclaw-deploy/issues/34)).

Diese Datei konsolidiert die Faktenblöcke zweier Issue-Sammlungen:

| Block | Quelle | Fakten-Issues |
|---|---|---|
| A — Agent-/Runtime-Plattform | Issue #34 (Meta) | #23–#33 |
| B — Build-Environment (Mod-/Pack-Builds) | Issue #47 (Meta) | #39–#46 |

---

## Block A — Agent-/Runtime-Plattform (aus #23–#33)

### A1 Analytics/Kosten: per-Agent-SQLite statt `.trajectory.jsonl` (Issue #23)

Seit der SQLite-Migration (2026-08-31) liegen Sessions + Usage **nicht mehr** in
`/home/node/.openclaw/agents/*/sessions/*.jsonl`, sondern in **per-Agent-SQLite**:
`/home/node/.openclaw/agents/<agent>/agent/openclaw-agent.sqlite`.

Geprüfte Tabellen:

- `session_nodes`: session_key, label, display_name, status, parent_session_key
- `session_windows`: session_key → session_id(s) (Kette über idle-resets),
  started_at/ended_at (**epoch ms**), model
- `transcript_events`: session_id, seq, event_json — Assistant-Messages mit
  `message.usage.{input,cacheRead,cacheWrite,output,reasoningTokens}` **und**
  `usage.cost.{input,cacheRead,output,total}` (echte, runtime-berechnete Kosten je Call)
- `trajectory_runtime_events`: session.started / model.completed (ts, sessionKey, usage)

Gotchas (nicht vergessen):

- `reasoning ⊆ output` — nie `output + reasoning` addieren; `total == input + cacheRead + output`.
- `est_cost` (offizielle off-peak Preise: Flash $0.22/$0.007/$0.66, Pro $0.66/$0.022/$1.98)
  ≠ `raw_cost/usage.cost` (OpenClaw) — nicht mischen; `usage.cost` bevorzugen.
- **Kein `sqlite3`-CLI garantiert** → `node:sqlite` (Node 24) bzw. JS/Node-Helper verwenden.
- Zeitfilter über `started_at/ended_at` der `session_windows` (epoch **ms**).

Betroffene Skripte im Repo: `scripts/analytics.sh`, `scripts/cost-report.sh`,
`scripts/cost-snapshot.sh`, `scripts/cost-dashboard.sh`. Ziel beim Umbau: gleiche
Public-API (Fenster START/END), Test gegen echte DB mit nicht-leerer Ausgabe.

### A2 gh-Health: `gh api user` statt `gh auth status` (Issue #24)

Ein toter secondary Account in `~/.config/gh/hosts.yml` (z. B. `momo-bot[bot]` mit
invalidem Token) macht `gh auth status` zum Exit-1 — naive Checks
(`if ! gh auth status`) alarmieren dann bei jedem Lauf falsch (GHFAIL).

Regel für Workflows:

- Tote Accounts entfernen: `env -u GH_TOKEN gh auth logout -u "<account>"` (Backup `hosts.yml.bak-<datum>`).
- Gesundheits-Check auf den **aktiven** Account: `gh api user --jq .login`, **nicht** `gh auth status`.

### A3 Cross-Context-FS: kein geteiltes `/tmp` — Shared-State über trigger.state/DB (Issue #25)

Trigger-Exec und Agent-Exec teilen sich **kein** gemeinsames `/tmp` (unterschiedliche
Sandbox-/Gateway-Namespaces). Eine Claim-/Lock-Datei aus einem Subagent
(`/tmp/.../issue-<n>.json`) ist für den Trigger-Check unsichtbar.

Regeln:

- Kein Shared-State über absolute `/tmp`-Pfade zwischen Trigger und Agent(en).
- Shared-Dedupe/Locks: `trigger.state` bzw. dauerhafte DB (SQLite); bei rein-isolierten
  Agent-Läufen Zustand explizit als Task-Ausgabe zurückgeben.
- Trigger-Exec läuft in eigenem Sandbox-Namespace (30s / 5 Tool-Calls / 16KB state).

### A4 Runtime: `sessionTarget`-Wahl & explizite Delivery-Ziele (Issue #26)

1. `sessionTarget:"current"` **blockiert, solange die interaktive Session mid-turn ist**
   (Lauf hing ~10 min in `running`; Commit an "current" will den Session-Lock des
   aktiven Turns). → Für Ledger-artige Jobs `sessionTarget: "session:<dashboard-key>"`
   (fester Ziel-Key) statt `"current"`.
2. Delivery löst bei "current"/webchat-Eigner fälschlich auf Telegram ohne chatId auf
   (`Delivering to Telegram requires target <chatId>`, `not-delivered`, obwohl der
   WebChat-Commit funktioniert; letzte Route der Session → Telegram mit leerem `to`).

Regeln: pro Job-Typ dokumentierte `sessionTarget`-Wahl + explizite Delivery-Ziele —
Kosten-Ledger → `session:<key>`; reine Auswertung ohne Chat → `isolated`;
Reminder an User → expliziter Kanal. Bei webchat-gebundenen Jobs `delivery.channel`/`to`
explizit setzen.

### A5 Subagent-Announcements: lang → truncated, identisch → Duplikate (Issue #27)

Beobachtet: lange Reports kommen als "[child result truncated]" (Text mitten im Satz ab,
Rest nur via `sessions_history` nachladbar); identische Reports kamen 3x als
Inter-Session-Message an (Duplikat-Zustellung).

Vorschläge/Regeln:

- Report-Länge im Announcement cappen (z. B. 1500 Zeichen), Details als Datei/PR-Comment.
- Duplikat-Zustellung vermeiden (Dedupe/Message-Hash); Announce-Pipeline-Timeouts für
  lange Texte prüfen.

### A6 Subagent-Completion-Delivery kann blocken (Issue #28)

Langer Lauf (52 min) endete mit `terminalOutcome: blocked` +
`"Required completion delivery failed … gateway request timeout for agent"` — der Report
erreichte die main-Session nie automatisch, nur via Statuscheck + `sessions_history`
auffindbar. Fehlersignaturen: "gateway request timeout for agent",
"requester settle wake deferred too many times".

Vorschläge: Completion-Delivery mit Retry/Backoff; best-effort-Modus (Status in
Session-History statt blocked); Completion-Timeout an erwartete Laufzeit koppeln.

### A7 Repo-Hygiene `.149`: Drift committen/gitignoren/aufräumen (Issue #29)

`/opt/apps/openclaw` (Prod-Checkout, Ausgang fürs Deploy) driftet: ungetrackte
`scripts/verify-app-auth.sh`, `scripts/webhook.py.bak-*`, `docker-compose.yml.bak-app-auth`,
`.doctor-fix.log`, `webhook-token`, `syncthing-config/`, `__pycache__/`.

Regeln:

- Je Artefakt entscheiden: committen (falls gewollt) oder `.gitignore`/aufräumen.
- `.gitignore` deckt nur `.deploy-hash/-git-hash/-img-hash` → ergänzen:
  `__pycache__/`, `*.bak*`, `*~`, `.doctor-fix.log`, ggf. `webhook-token` (Token gehört
  nie ins Repo).
- Ziel: `.149`-Checkout reproduzierbar auf `main`-Stand.

### A8 Token-/Laufzeit-Disziplin: Reporting-Contract statt 106k-Token-Diagnose (Issue #30)

Beispiel: wish-Diagnose 42k Input / 64k Output Tokens, 52 min für eine Standard-Diagnose
(df/free/docker/dmesg) — Agent verlor sich in Gedankenkette zu /tmp/_MEI-Verzeichnissen
(für den Fix irrelevant).

Regeln/Vorschläge:

- Operator-Prompt um strikten Reporting-Contract ergänzen (max. N Zeilen, vorgegebene
  Tabelle, keine narrativen Ausführungen).
- Thinking für Operator-Aufgaben auf low/off.
- Token-Budget je Task (toolBudget/run-Budget); bei Erreichen hart abbrechen + Kurzreport.
- "Script-first": ein SSH-Kommando pro Host sammelt alle Metriken in einem Rutsch.

### A9 SSH-Zeitfenster-Policy für überlastete/kaputte Hosts (Issue #31)

Überlasteter Host (wish, Load >300): 13 min für einen `systemctl stop` wegen
Retry-Schleifen. Bewährte Workarounds:

```sh
ssh -o ConnectTimeout=20 -o BatchMode=yes -o StrictHostKeyChecking=accept-new <host> …
```

- Retry-Loop max. 6 Versuche, 15s Pause dazwischen, bei Erfolg sofort aussteigen.
- Read-only-Verifikation nach Aktion (`systemctl is-active`, `uptime`, `free`).
- Regel: Host nach N Versuchen nicht erreichbar → sofort mit "unreachable" reporten,
  nicht endlos retryen.
- Optional: Health-Precheck vor jedem Host-Einsatz (Connectivity + Load).

### A10 Infra-Limitation `.149`: hohe Last — Timeout/Retry für Langläufer (Issues #32/#33)

Messung 2026-09-02 (14:33, `momo@lan`): 16 Cores, load average **7.07 / 12.54 / 14.09**
(1/5/15 min), `openclaw`-Container ~35% CPU und **~60,5 GiB RAM** (Host gesamt 105,5 GiB);
~20 aktive Container (caddy, stash, paperless+db, vaultwarden, pocket-id, ollama,
factorio, HA-Stack …) plus Subagent-Orchestrierung auf demselben Host. Symptome:
Announce-Delivery-Timeouts, lange Subagent-Laufzeiten (52 min Diagnose, 13 min Stopp),
hohe Latenz bei History-/Status-Tools; memory_search (ollama nomic-embed-text, lokal)
timeout nach 15s.

Take-into-account für Workflows:

- Langläufer (Analytics-Report, große Regression) mit **großzügigem Timeout und Retry**
  planen; nicht von niedriger Latenz ausgehen.
- Große SQLite-`transcript_events`-Scans über mehrere Agent-DBs: **Fenster einschränken**
  und/oder außerhalb der Spitzen (derzeit load ~14) ausführen.
- Offene Optionen (nicht sofort erzwingen): Container-Limits/Scheduling für den
  openclaw-Container (60 GiB), Auslagerung Gateway/Agenten auf planet (Hetzner Metal,
  Load 1.6, 62G RAM) bzw. Builds, Subagent-Concurrency-Limit, Embedding-Auslagerung.

---

## Block B — Build-Environment (aus #39–#46)

> Kontext: Fakten stammen aus Mod-Build-/Pack-Update-/PR-Arbeit (yogglez, aero).
> Jedes geschlossene Issue des Blocks hinterlässt hier eine Zeile (DoD von #47).

### B1 Persistente Build-Tools: JDK 21 + Gradle-Cache (Issue #39)

- Kein System-JDK 21, kein persistenter Gradle-Home → jeder Build ist Cold-Start
  (neoForm-Pipeline lädt neu, 3 min+; bei NeoForge-Versionswechsel komplett erneut).
- Soll: JDK 21 fest in Build-Umgebung (Agent-Image/Workspace-Provisioning); persistenter
  `GRADLE_USER_HOME` unter stabilem Pfad (**nicht** /tmp, nicht pro-Task neu).
- DoD: zweiter Build desselben Mods mit warmem Cache <1 min; kein manuelles
  `export JAVA_HOME`/`GRADLE_USER_HOME`.

### B2 gh-Metadaten-Edits über REST (Issue #40)

- `gh pr edit --body-file` scheitert ohne `read:org`-Scope (GraphQL-Query im Hintergrund:
  "'login' field requires … ['read:org']").
- Workaround-Standard: PR-Metadaten-Edits via REST
  `PATCH /repos/<owner>/<repo>/pulls/<n>` mit `Authorization: Bearer $GH_TOKEN`.
- `gh` nur für einfache Befehle (issue/view/list); Token-Scope-Erweiterung (`read:org`,
  ggf. `read:discussion`) als Alternative offen.

### B3 Mod-Build-Preflight: Dev-Env-Pins gegen Pack-Stack validieren (Issue #41)

- Drift-Beispiel: `gradle.properties` pinnte `neo_version=21.1.217` /
  `ponder_version=1.0.81`; Gametest gegen Pack (Create 6.0.10-281) scheiterte erst nach
  mehreren Boot-Versuchen ("Missing or unsupported mandatory dependencies: ponder
  '[1.0.82,)', neoforge '[21.1.219,)'").
- Soll: Preflight **vor** jedem Build — Pack-Stack (NeoForge/Create/Ponder/AE2 aus dem
  Pack-Manifest) gegen `gradle.properties` prüfen; kleines Check-Script im Repo
  (z. B. `scripts/check-pack-stack.sh`).
- DoD: Pin-Drift wird in Sekunden als Fehler gemeldet, nicht nach 3 min Boot.

### B4 Aero-Test-Instanz: idempotentes Klon-Setup (Issue #42)

- Drift: Runbook ging von existierender aero-test-Instanz aus; real enthielt
  `/srv/aero-test` nur verwaistes `monitoring/`, kein Container → ad hoc als
  PROD-Klon neu aufgebaut (`/srv/aero-test`, Port 25582, compose nach Muster + RCON-Fix).
- Soll: Preflight "Instanz vorhanden? sonst klonen" als Schritt 0 in jedem
  aero-Test-Runbook; idempotentes Setup-Script (`clone-prod.sh`: compose + data klonen,
  freien Port vergeben, RCON-Test-Passwort setzen); Runbook an IST-Stand angleichen.
- DoD: nächster Test-Deploy ohne manuelle Instanz-Rekonstruktion; Drift wird vom
  Preflight erkannt statt vom Agent improvisiert.

### B5 RCON-Fix im Compose-Template versionieren (Issue #43)

- RCON-Fix (RCON im Container passend zu `default-server.properties` mit
  `enable-rcon=true`) war Ad-hoc-Edit beim Klon und nirgends versioniert.
- Soll: Compose-Template inkl. RCON-Konfiguration im Repo festhalten, Fix im Runbook
  dokumentieren. DoD: nächster Klon übernimmt den Fix aus der Vorlage.

### B6 FTB-Server-Installer: gute Version persistieren, /tmp-Artefakte vermeiden (Issue #44)

- Neuer Installer-Build 24.622 ist für Pack 134 broken ("Modpack id not valid";
  modpacks.ch-API kennt Pack 134 nicht). Alter Installer **v1.0.49** mit
  `-pack 134 -version 100490 -dir …` funktioniert.
- Problem: Installer (`aero-173-server.bin`) und Referenz-Pack-Extraktion (`/tmp/aero191b`)
  lagen unter /tmp → überleben Reboot nicht.
- Soll: bekannte gute Installer-Version + SHA-256 persistent (z. B. `/srv/tools/ftb/`);
  Referenz-Pack-Extraktionen unter persistentem Pfad (z. B. `/srv/refs/`) mit
  Aufräum-Regel; Installer-Lesson (welcher Build für welches Pack) im Runbook.

### B7 Headless-Client-Verifikation: Limitation + manuelles Gate (Issue #45)

- Headless-Build/Container kann Client-Rendering **nicht** prüfen (HUD-Overlay,
  Lens-Zyklus, generell Client-Aspekte); Gametests decken nur Server-Logik ab →
  "war headless nicht prüfbar" blieb als offener Punkt im Review.
- Limitation: kein Client-Verifikations-Harness. Optionen: Xvfb + headless-Client
  (aufwändig/instabil), dedizierte Client-Dev-Instanz, manuelles Gate im Release-Prozess.
- Soll: Entscheidung dokumentieren — "Client-Verifikation = manueller Gate-Check auf
  aero-test" (aktuell realistisch) mit klarer Checkliste (HUD, Overlays, JEI, Rezepte);
  Xvfb-Harness als langfristige Option offen lassen.
- DoD: Release-Runbook enthält explizites Client-Gate.

### B8 Build-Host-Strategie (Issue #46)

- Schwere Build-Lasten (neoForm-Recompile 3 min+, Gametest-Server-Boots,
  FTB-Pack-Downloads/-Extractions 500+ Mods) laufen je nach Aufgabe auf .149/Sandbox
  bzw. planet; keine Baseline-Messungen, kein festgelegter Build-Host; fehlende
  persistente Caches verschärfen das (→ B1).
- Soll: (1) Zeit je Build-Phase auf .149 vs. planet messen; (2) Strategie festlegen und
  dokumentieren (Builds auf planet/c0 auslagern ODER dedizierter Build-Container mit
  persistenten Caches auf .149); (3) Laufzeiten als Baseline notieren.
- DoD: dokumentierte Build-Host-Strategie + bekannte Build-Laufzeiten als Baseline.

---

## Status

- Überbau/Koordinierung: [#34](https://github.com/momokli/openclaw-deploy/issues/34) (offen).
- Konsolidiert & geschlossen: [#47](https://github.com/momokli/openclaw-deploy/issues/47)
  (verweist auf dieses Runbook).
- Offene Einzel-Issues aus Block A/B liefern bei Schließung jeweils eine Zeile hierher.

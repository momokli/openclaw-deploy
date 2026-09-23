# Automations (cron) — Nutzung, Sichtbarkeit & as-code-vs-fluent-Grenze

Stand: 2026-09-23. Source-of-Truth: dieses Repo.

> Die `rift-*`-Runner arbeiten seit dem 2026-09-23 **fokus-milestone-getrieben**: kein
> Milestone-Name mehr im Prompt, der Fokus wird pro Lauf ermittelt. Details, Regeln und
> Betrieb: `docs/milestone-methodology.md`.

> **Host seit 2026-09-23:** Der Gateway läuft auf `planet`, der State liegt unter
> `/srv/openclaw` (`docs/migrate-gateway-planet.md`). Wichtig für dieses Dokument, weil
> `OPENCLAW_STATE_DIR` jetzt **≠** `$HOME/.openclaw` ist: Prompts/Skripte, die nach
> `$HOME/.openclaw/...` schreiben, laufen nur korrekt, weil `~/.openclaw/workspace`
> auf `/srv/openclaw/workspace` **symlinkt**. Neue Status-/Log-Pfade deshalb am besten
> aus dem State ableiten (`OPENCLAW_STATE_DIR`), nicht aus `$HOME`.

## Was Automations sind

Automations (= `cron`) sind **Runtime**-Objekte, die der Gateway verwaltet — **nicht**
`config/openclaw.json` und **nicht** git. Sie überleben Deploys im Gateway-State.

**Aber:** Die **Prompts** (was ein Runner _tut_) liegen as-code in
`config/automations/*.prompt.md`, und `scripts/automations-apply.sh` convergt sie
idempotent auf den laufenden Gateway (create-oder-edit über `--declaration-key`,
stale Jobs werden entfernt). Das ist die „as-code"-Hälfte; das **Anlegen/Aktivieren**
bleibt ein Live-Gateway-Eingriff (CLI/UI), der NICHT automatisch im Converge-Lauf steckt
(`converge-openclaw-config.sh` convergt nur `openclaw.json`, nicht die Cron-Objekte).

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

## Inventar (as-code, 23.09.): zwei Ebenen je Runner

Je Runner gibt es einen **billigen Shell-Tick** (5 min, 0 Tokens) und den **teuren
Agent-Turn** (6 h Fallback, wird vom Tick getriggert):

| Name                | declarationKey           | Art                 | Takt           | Repo                     | Rolle      |
| ------------------- | ------------------------ | ------------------- | -------------- | ------------------------ | ---------- |
| `rift-triage-tick`  | `rift-triage-tick:main`  | Shell (`--command`) | 5 min          | `riftbreaker-battle-mod` | Precheck A |
| `rift-pr-gate-tick` | `rift-pr-gate-tick:main` | Shell (`--command`) | 5 min          | `riftbreaker-battle-mod` | Precheck B |
| `rift-triage`       | `rift-triage:main`       | Agent-Turn          | 6 h (Fallback) | `riftbreaker-battle-mod` | A          |
| `rift-pr-gate`      | `rift-pr-gate:main`      | Agent-Turn          | 6 h (Fallback) | `riftbreaker-battle-mod` | B          |
| `ocd-triage`        | `ocd-triage:main`        | Agent-Turn          | 30 min         | `openclaw-deploy`        | A          |
| `ocd-pr-gate`       | `ocd-pr-gate:main`       | Agent-Turn          | 30 min         | `openclaw-deploy`        | B          |

`ocd-*` sind **disabled**. Milestone-Quelle der `rift-*`-Runner ist zur Laufzeit
`rift-focus-milestone.sh` (kleinster offener Versions-Titel) — kein Name im Prompt.

Daneben existieren noch **System-/Plugin-Jobs** (nicht in git, nicht von uns convergt):
`heartbeat:main`, `memory-core` (Memory Dreaming), und `skill-collection-review:*`
(plugin-owned — auf **1** reduziert, siehe unten).

## Zwei-Ebenen-Takt: billiger Tick, teurer Turn (23.09.)

**Problem:** Die Slot-Prüfung („ist ein Worker unterwegs / ist ein Fokus-PR offen?")
steckt im **Prompt** — also _innerhalb_ des Agent-Turns. Jeder Tick kostete damit einen
vollen Model-Turn (~50k Input-Tokens), auch wenn nichts zu tun war. Den Durchsatz deckelt
aber **WIP = 1**, nicht der Takt: häufiger laufen = nur mehr Tokens.

**Lösung:** Der deterministische Teil wanderte in **Shell** (`--command`-Payload, 0 Tokens):

```
alle 5 min  rift-triage-tick   (Shell)  → Slot frei? Leaf-Kandidat? → sonst Exit 10
alle 5 min  rift-pr-gate-tick  (Shell)  → aktionabler Fokus-PR?    → sonst Exit 10
              └─ nur bei „ja": `openclaw automations run <agent-job-id>`
                                    ↓
            rift-triage / rift-pr-gate (Agent-Turn, Tokens)
```

- Skripte: `scripts/rift-triage-tick.sh`, `scripts/rift-pr-gate-tick.sh` (live in
  `~/.local/bin`; brauchen `rift-focus-milestone.sh` und `clanker-gh` im PATH — die
  `--command`-Payloads erben PATH und `OPENCLAW_STATE_DIR`/`OPENCLAW_CONFIG_PATH`
  vom Gateway-Service).
- **`rift-triage-tick` entscheidet verbindlich.** Er läuft Guard + Schritt-4-Cleanup, prüft Slot
  und Leaf-Gate und wählt das Issue **deterministisch** (Epic-Checkliste von oben, sonst
  aufsteigende Nummer). Die Auswahl schreibt er nach
  `<OPENCLAW_STATE_DIR>/workspace/rift-triage-decision.md`; der Agent-Turn liest sie (Schritt 0 des
  Prompts, gültig < 15 min) und **wählt nicht mehr selbst**. Grund: `openclaw automations run
<id>` nimmt keine Parameter — die Datei ist der Kanal.
- **`rift-pr-gate-tick` mergt deterministisch:** bei `[VERDICT: APPROVE]` + `CLEAN` +
  ausschliesslich grünen Checks `gh pr merge --squash --delete-branch` (0 Tokens). Nur wenn
  Review/Rebase nötig ist, geht es an den Agent-Turn.
- Exit-Codes der Ticks: `0` = OK (Aktion **oder** nichts zu tun — welches steht im Log; ein
  Command-Payload mit Exit ≠ 0 gilt als Job-Fehler), `2` = Fehler. `RIFT_TICK_DRY=1` = Trockenlauf.
- Gate-Trigger-Regel: nur `mergeStateStatus` **CLEAN**/**BEHIND**/**UNSTABLE**. `BLOCKED`/`UNKNOWN`
  (wartet auf CI) und `DIRTY` (Konflikt) bewusst nicht — sonst Endlos-Trigger.
- Die **6-h-Takte der Agent-Jobs sind Fallback**, falls die Ticks mal nicht laufen.

**Bekannte Lücke (offen):** Der Triage-Tick gated auf `orchestrator:dispatched` und
verhindert damit auch den Agent-Turn, der den **Stale-Guard** und Schritt 4 (Aufräumen)
fahren würde. Ziel: Guard + Cleanup ebenfalls in die Shell-Ebene ziehen.

### Logrotation

`config/logrotate.openclaw` → `/etc/logrotate.d/openclaw` (root). Deckt
`/srv/openclaw/logs/*.log` (daily, `rotate 14`, `maxsize 10M`) und `/tmp/openclaw/*.log`
(daily, `rotate 7`, `maxsize 20M`). `copytruncate` + `su momo momo`, weil Gateway und
Ticks ihre Log-FDs offen halten. Der system-`logrotate.timer` läuft täglich um 00:00.

## Wichtige Invarianten

- **Eine Automation darf andere Automations NICHT per nativem `automations`-Tool
  inspizieren** (Fehler: „Automations tool is restricted to the current automation").
  Cross-Loop-Checks sind deshalb aus den Prompts entfernt — Runner A und B sind
  unabhängig. Wer doch eine andere Automation abfragen muss: `exec` →
  `openclaw automations get <id>`.
- **Modell bei `sessions_spawn` IMMER explizit setzen** (sonst erbt der Sub-Agent das
  falsche Modell, z. B. `deepseek-v4.1-flash` statt `v4-pro` → Issue #86).
- **Delivery = `none`** (`--no-deliver`), weil Telegram disabled ist; sonst failen die
  Runner mit „announce → last → no route".
- **`gh` läuft auf dem Gateway** (kein `exec host=node` für `gh`); Auth via `GH_TOKEN`
  (PAT), das der Gateway dem `exec`-Env injiziert (2026.8.1-Fix).
- **PR-Body MUSS den Issue schließen:** `Closes #<n>` (bzw. `Fixes #<n>`), **nicht**
  „Refs #<n>". Nur ein Closing-Keyword lässt GitHub das Issue beim Merge automatisch
  schließen; sonst klebt `orchestrator:dispatched` daran und der Fokus-Slot bleibt
  blockiert (real passiert bei #893/PR #897). Der PR-Quality-Check verlangt das inzwischen
  hart (`config/agents/{orchestrator,developer}.md`).

## Stale-Dispatch-Guard (`rift-triage`, 14.09., gehärtet 23.09.)

**Problem:** Runner A skippt Issues mit Label `orchestrator:dispatched` (Dedup). Stirbt der Worker
nach dem Dispatch (z. B. `non_deliverable_terminal_turn` → Session-Status `failed`), bleibt das
Label kleben → die Triage fasst das Issue nie wieder an: kein PR, kein Retry. Es ist gelockt
(real passiert mit #401: 3 fehlgeschlagene Dispatches, Label blieb).

**Lösung:** `scripts/rift-stale-dispatch.sh`, aufgerufen als Schritt 0 des `rift-triage`-Prompts
(`rift-stale-dispatch.sh -m <fokus-title>`, installiert in `~/.local/bin`). Es gibt stale Issues frei
(`orchestrator:dispatched` weg + `triage:redispatch` + Marker-Kommentar); der normale
Triage-Pfad dispatcht sie dann im selben Lauf.

`stale ⇔` Dispatch-Label älter als `--grace-min` (20) **und** kein **Outcome** (kein verlinkter
offener PR, kein gemergter PR, kein Label `triage:no-action`) **und** keine **menschliche**
Aktivität seit dem Dispatch (Commit-/PR-Referenz oder Kommentar eines Nicht-Bots; **Bot-Kommentare
zählen NICHT** — sonst hält sich ein Worker mit einer Zwischenmeldung selbst den Slot offen,
real passiert bei #895) **und** kein laufender Worker (`openclaw sessions list`: `running` nur
innerhalb `--running-ttl-min`, weil verwaiste Records nach Crash/Restart ewig `running` bleiben;
`failed`/`killed` = nicht gesund).

**Zwei Ausgänge statt eines Deadlocks:**

- **Freigabe (Retry):** kein gesunder Worker-Run seit dem Dispatch → Label weg +
  `triage:redispatch` + Marker-Kommentar; die Triage dispatcht neu.
- **Parken:** Worker `done`, aber **ohne** Outcome → Label weg + `question`. Der WIP=1-Slot ist
  frei und ein Mensch entscheidet — statt (wie früher) `NOTE escalate` bei stehenbleibendem
  Label, denn genau das war selbst der Deadlock (real: #895).

**Schritt 4 (Cleanup, `scripts/rift-triage-cleanup.sh`)** schließt ein Issue nur bei
`triage:no-action` (Maschinen-Signal des Workers) oder `[ALREADY-DONE]` (Altpfad). **Nicht**
mehr bei „gemergter PR erwähnt das Issue": eine Cross-Reference entsteht schon durch eine
bloße Erwähnung (real: PR #660 → #623 falsch geschlossen). Der saubere Weg ist `Closes #<n>`
im PR (schließt GitHub selbst) — erzwungen vom `pr-quality`-Check.

**Loop-Bremse (eigene Caps, zusätzlich zur Triage-Protection):** max. 3 Freigaben je Issue
(Zähler in den Marker-Kommentaren, nicht im Label — erneutes `--add-label` ist ein API-No-op);
am Hard Cap wird **geparkt** (Label weg + `question`) statt nur eskaliert; 30 min Cooldown; max. 2
Freigaben pro Lauf.

```sh
rift-stale-dispatch.sh -m 1.0.1 --dry-run    # Entscheidungen zeigen, nichts ändern
bash tests/rift-stale-dispatch/run.sh      # Offline-Harness (43 Checks, ohne Netz)
bash tests/rift-stale-dispatch/run.sh --red  # Beweis, dass der Guard-lose Fall durchfällt
```

## as-code vs. fluent

| **as-code** (git, reviewbar, reproduzierbar)                                                                                                                                                           | **fluent** (Runtime, CLI/UI, NICHT git)                             |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------- |
| `config/openclaw.json` (Gateway/Agents/Model/Tools)                                                                                                                                                    | Sessions/Transcripts                                                |
| `config/agents/*.md` (Personas)                                                                                                                                                                        | Memory (runtime `MEMORY.md` + Index)                                |
| `workspace/*.md` (SOUL/AGENTS/USER)                                                                                                                                                                    | Workspace-Runtime-Files                                             |
| `workspace/skills/*`                                                                                                                                                                                   | Device-Pairing + Auth (gh/openrouter)                               |
| Deployment: `config/*`, `workspace/*`, `scripts/setup-native.sh`, `scripts/converge-openclaw-config.sh`, `scripts/sync-agent-personas.sh`, `scripts/automations-apply.sh`, `config/logrotate.openclaw` | Plugins                                                             |
| `config/automations/*.prompt.md` (Runner-Prompts)                                                                                                                                                      | **Automations/cron-Objekte** (per `automations-apply.sh` converged) |

**Regel:** Struktur (was der Agent _ist_ / wohin er routet / welche Tools) = as-code.
Dynamik (welche Sessions existieren, welche Automations laufen, wer gepaart ist) = fluent.
Automation-**Prompts** gehören as-code; die **Job-Objekte** bleiben Runtime (converged,
nicht deklarativ in `openclaw.json`).

## Historie / Cleanup (12.09. erledigt)

- Alte Loops `rbm-loop`, `rbbattle-overnight-loop`, `rbb-triage-loop`,
  `milestone-orchestrator`, `triage-loop`, `mmm-loop`, `ci-cd-fix-loop` → **ersetzt
  bzw. entfernt** (die `rift-*`/`ocd-*`-Runner übernehmen deren Aufgabe).
- `skill-collection-review` von **15× → 1×** reduziert (plugin-owned, redundant pro Agent).
- Der `milestone-orchestrator`-Supervisor entfällt → behebt den „Automation kann
  rift-Triage nicht sehen"-Fehlalarm an der Wurzel.

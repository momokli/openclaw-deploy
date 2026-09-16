# Automations (cron) — Nutzung, Sichtbarkeit & as-code-vs-fluent-Grenze

Stand: 2026-09-12. Source-of-Truth: dieses Repo.

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

## Inventar (as-code, 12.09.)

Zwei **Runner** (A = Issue→Dispatch, B = PR→rebase/review/merge/reject), je Repo:

| Name           | declarationKey      | Takt | Repo                     | Milestone-Quelle                         | Rolle |
| -------------- | ------------------- | ---- | ------------------------ | ---------------------------------------- | ----- |
| `rift-triage`  | `rift-triage:main`  | 5m   | `riftbreaker-battle-mod` | GitHub (dynamisch, meiste offene Issues) | A     |
| `rift-pr-gate` | `rift-pr-gate:main` | 5m   | `riftbreaker-battle-mod` | GitHub (dynamisch)                       | B     |
| `ocd-triage`   | `ocd-triage:main`   | 30m  | `openclaw-deploy`        | Labels/Prio (kein Milestone)             | A     |
| `ocd-pr-gate`  | `ocd-pr-gate:main`  | 30m  | `openclaw-deploy`        | Labels/Prio                              | B     |

Daneben existieren noch **System-/Plugin-Jobs** (nicht in git, nicht von uns convergt):
`heartbeat:main`, `memory-core` (Memory Dreaming), und `skill-collection-review:*`
(plugin-owned — auf **1** reduziert, siehe unten).

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

## Stale-Dispatch-Guard (`rift-triage`, 14.09.)

**Problem:** Runner A skippt Issues mit Label `orchestrator:dispatched` (Dedup). Stirbt der Worker
nach dem Dispatch (z. B. `non_deliverable_terminal_turn` → Session-Status `failed`), bleibt das
Label kleben → die Triage fasst das Issue nie wieder an: kein PR, kein Retry. Es ist gelockt
(real passiert mit #401: 3 fehlgeschlagene Dispatches, Label blieb).

**Lösung:** `scripts/rift-stale-dispatch.sh`, aufgerufen als Schritt 0 des `rift-triage`-Prompts
(`rift-stale-dispatch.sh -m 1.0`, installiert in `~/.local/bin`). Es gibt stale Issues frei
(`orchestrator:dispatched` weg + `triage:redispatch` + Marker-Kommentar); der normale
Triage-Pfad dispatcht sie dann im selben Lauf.

`stale ⇔` Dispatch-Label älter als `--grace-min` (20) **und** kein verlinkter offener PR
(Branch/Body-Konvention + Timeline-Cross-Reference) **und** keine Aktivität auf dem Issue seit
dem Dispatch (Kommentar/Cross-Ref/Commit — Fallback, weil Session-Labels die Issue-Nummer nicht
immer tragen) **und** kein gesunder Worker-Run seit dem Dispatch (`openclaw sessions list`:
`done` = gesund; `running` nur innerhalb `--running-ttl-min`, weil verwaiste Records nach
Crash/Restart ewig auf `running` stehen bleiben; `failed`/`killed` = nicht gesund).

**Loop-Bremse (eigene Caps, zusätzlich zur Triage-Protection):** max. 3 Freigaben je Issue
(Zähler in den Marker-Kommentaren, nicht im Label — erneutes `--add-label` ist ein API-No-op),
danach nur noch `NOTE <n> escalate`; 30 min Cooldown; max. 2 Freigaben pro Lauf.

```sh
rift-stale-dispatch.sh -m 1.0 --dry-run    # Entscheidungen zeigen, nichts ändern
bash tests/rift-stale-dispatch/run.sh      # Offline-Harness (43 Checks, ohne Netz)
bash tests/rift-stale-dispatch/run.sh --red  # Beweis, dass der Guard-lose Fall durchfällt
```

## as-code vs. fluent

| **as-code** (git, reviewbar, reproduzierbar)                                                                     | **fluent** (Runtime, CLI/UI, NICHT git)                             |
| ---------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `config/openclaw.json` (Gateway/Agents/Model/Tools)                                                              | Sessions/Transcripts                                                |
| `config/agents/*.md` (Personas)                                                                                  | Memory (runtime `MEMORY.md` + Index)                                |
| `workspace/*.md` (SOUL/AGENTS/USER)                                                                              | Workspace-Runtime-Files                                             |
| `workspace/skills/*`                                                                                             | Device-Pairing + Auth (gh/openrouter)                                |
| Deployment: `config/*`, `workspace/*`, `scripts/setup-native.sh`, `scripts/converge-openclaw-config.sh`, `scripts/sync-agent-personas.sh`, `scripts/automations-apply.sh` | Plugins                                                             |
| `config/automations/*.prompt.md` (Runner-Prompts)                                                                | **Automations/cron-Objekte** (per `automations-apply.sh` converged) |

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

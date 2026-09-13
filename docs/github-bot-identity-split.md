# GitHub-Bot-Identity-Split: `clanker` (coder) + `claw` (reviewer)

Stand: 2026-09-12. Status: **Plan + Code bereit, App-Registrierung ausstehend (manuell).**

## Ziel

Die A/B-Runner sollen in der GitHub-UI als **zwei getrennte Bots** sichtbar sein:

| Rolle                       | Bot            | UI-Login            | Was er tut                                   |
| --------------------------- | -------------- | ------------------- | -------------------------------------------- |
| Runner A (triage/coder)     | `momo-clanker` | `momo-clanker[bot]` | Issues labeln, PRs erstellen, Commits pushen |
| Runner B (pr-gate/reviewer) | `momo-claw`    | `momo-claw[bot]`    | Reviews posten, mergen, rejecten             |

## Befund (verifiziert)

- Heute läuft **alles als `momokli`** (ein PAT). Commits sogar als `Molty 🦞 <molty@…>`
  (git-Identity aus `setup-native.sh`), nicht mal als `momokli`.
- OpenClaws nativer Per-Agent-GitHub-Identity (`agents.entries.<id>.github` +
  `tools.github`) ist **OAuth-Device-Flow only** (`kind: "oauth"`) → kann keine
  `[bot]`-App-Identity erzeugen. Verworfen.
- Das `exec`-Tool injiziert nur `GH_TOKEN`/`GITHUB_TOKEN`; `GH_CONFIG_DIR` und
  `GH_APP_*` sind **nicht** geblockt und erben aus `process.env`.
- Es existiert **eine** App `momo-clanker` (Private-Key vorhanden, Token-Mint
  funktioniert), aber sie ist auf **~30 andere** Repos installiert — **NICHT** auf
  `momokli/riftbreaker-battle-mod` / `momokli/openclaw-deploy`.

## Mechanismus

`GH_CONFIG_DIR`-Isolation + pro-Bot-Wrapper. Jeder Wrapper mintet ein frisches
~1h-App-Token in ein eigenes `hosts.yml` und `exec`t das echte `gh`/`git`. Der Agent
tauscht nur `gh`→`clanker-gh` / `git`→`clanker-git` (bzw. `claw-*`) — kein `export`
über `exec`-Aufrufe hinweg nötig.

```
clanker-gh pr create …   →  mintet Token → ~/.config/gh-clanker/hosts.yml → gh
claw-gh pr review …      →  mintet Token → ~/.config/gh-claw/hosts.yml    → gh
clanker-git commit …     →  + GIT_AUTHOR/COMMITTER = clanker[bot]
claw-git merge …         →  + GIT_* = claw[bot]
```

App-Config je Bot liegt in `~/.config/gh-bots/<app>.env`:
`GH_APP_ID`, `GH_APP_INSTALLATION_ID`, `GH_APP_PRIVATE_KEY_FILE`.

## Was gebaut ist (as-code)

- `scripts/gh-bot-auth.sh` — Mint + `hosts.yml` je App, `--token`, `--bot-id`.
- `scripts/{clanker,claw}-gh` und `scripts/{clanker,claw}-git` — Wrapper.
- `.env.example` — erweitert um `CLANKER_*` + `CLAW_*` (6 Keys).
- Prompt-Verdrahtung (Runner A → `clanker-*`, Runner B → `claw-*`) ist eingebaut. Die
  Wrapper fallen ohne App-Config **graceful auf die Default-Identity zurück** — d.h.
  man kann jederzeit convergen: bis die Apps registriert sind läuft alles als `momokli`,
  danach automatisch als `clanker[bot]`/`claw[bot]`.

## Manueller Rest (Web-UI, ~10 min — kann kein Agent)

1. **App `clanker` anlegen** (oder `momo-clanker` umbenennen): Name `clanker`,
   Permissions: Contents RW, Issues RW, Pull requests RW, Metadata R.
2. **App `claw` anlegen**: gleiche Permissions.
3. Beide Apps auf **`momokli/riftbreaker-battle-mod`** + **`momokli/openclaw-deploy`**
   installieren (Installation → „Only select repositories").
4. Je App: Private Key herunterladen → `/home/momo/.secrets/clanker.pem` + `claw.pem`
   (chmod 600). App-ID + Installation-ID notieren.
5. `~/.config/gh-bots/{clanker,claw}.env` befüllen (siehe `.env.example`).

Danach: Prompt-Verdrahtung convergen + Smoke-Test (Mint beider Token, `gh api user`-Äquiv,
ein Test-PR/Review), dann Monitoring der ersten A/B-Läufe.

## Gotchas

- **Ambientes `GH_TOKEN` hebelt die Bot-Identität aus** (Issue #103): `gh` gibt
  `GH_TOKEN`/`GITHUB_TOKEN`/`GH_ENTERPRISE_TOKEN` aus der Umgebung Vorrang vor der
  `hosts.yml` in `GH_CONFIG_DIR` — die Wrapper liefen dann still als Ambient-User
  (`momokli`) statt als `[bot]`. Die Wrapper (`clanker-gh`/`claw-gh` und, weil der
  git-Credential-Helper `gh auth git-credential` denselben Token liest,
  `clanker-git`/`claw-git`) neutralisieren die drei Variablen daher, sobald die
  App-Config greift; `gh-bot-auth.sh` ruft sein eigenes `gh auth setup-git` mit
  `env -u …` auf. Im **Fallback** (App nicht konfiguriert) bleiben sie bewusst
  unangetastet, damit der Wrapper wie dokumentiert auf die Default-Identität fällt.
  Offline-Nachweis: `bash tests/clanker-gh/run.sh` (14 Fälle, PATH-Shims, kein Netz),
  red-before-green via `bash tests/clanker-gh/run.sh --red`.
- App-Token laufen ~1h ab → Mint-per-Call (robust, <2s).
- Commit-Email = `<bot_user_id>+<app>[bot]@users.noreply.github.com` (BOT-USER-ID,
  **nicht** App-ID).
- `gh pr merge`/`review` werden automatisch dem App zugeordnet (kein git-Identity nötig).

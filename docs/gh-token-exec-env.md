# GH_TOKEN in exec- & Sub-Agent-Umgebung

> Problem: `gh`-Kommandos aus dem `exec`-Tool (und damit aus Sub-Agents wie
> `feature-dev-*`) fanden `GH_TOKEN` nicht — `gh auth status` meldete
> "not logged in", obwohl der Gateway-Prozess das Token hatte.
> Stand: 2026-08-26, OpenClaw 2026.7.1 → behoben mit Base-Image 2026.8.1-beta.3.

## Symptom

- `.env` enthält `GH_TOKEN=<token>`; docker-compose lädt es per `env_file`
  in den Container-Prozess (Gateway-Prozess-PID 1 hat das Token).
- `openclaw.json` referenziert `"GH_TOKEN": "${GH_TOKEN}"` im `env.vars`-Block —
  die Substitution klappt, der Gateway hat das Token.
- Trotzdem: `exec`-Tool-Kommandos und gespawnte Sub-Agents haben KEIN `GH_TOKEN`
  in der Shell-Umgebung → `gh auth status` → "You are not logged into any GitHub
  hosts." → interaktiver Device-Flow (`gh auth login --web`) nötig, der abläuft.

## Root Cause (im OpenClaw-Code)

Das `exec`-Tool baut die Child-Umgebung NICHT aus dem vollen Prozess-Env:

```
src/agents/bash-tools.exec.ts → sanitizeHostExecEnvWithDiagnostics({
  baseEnv: process.env, overrides: requestedEnv, blockPathOverrides: true })
```

Die Host-Env-Security-Policy (`src/infra/host-env-security-policy.json`) blockt
`GH_TOKEN`:

| Policy-Liste                          | GH_TOKEN enthalten? | Effekt                                                        |
| ------------------------------------- | ------------------- | ------------------------------------------------------------- |
| `blockedEverywhereKeys`               | nein                | –                                                             |
| `blockedOverrideOnlyKeys`             | **ja**              | per-call `exec.env` / Plugin-Env → Security Violation (throw) |
| `allowedInheritedOverrideOnlyKeys`    | nein                | → `blockedInheritedKeys` enthält GH_TOKEN                     |
| (abgeleitet) `blockedInheritedKeys`   | **ja**              | erbt aus `process.env` → wird aus exec-Env **entfernt**       |

Ergebnis: Auf 2026.7.1 gibt es **keinen** Konfig-Pfad (Config-`env`-Block,
`tools.exec`, Plugin-Hook `resolve_exec_env`, per-call `exec.env`), um `GH_TOKEN`
in die exec-Child-Umgebung zu bringen — weder vererbt noch als Override.
Der Plugin-Hook scheitert sogar hart (Security Violation), weil Overrides gefiltert werden.

## Fix (Upstream, ab 2026.8.1-beta.3)

Upstream hat auf `main` eine explizite Ausnahme ergänzt
(`src/agents/bash-tools.exec-request-preparation.ts`):

```ts
if (params.host === "gateway" && params.managedLocalIdentity === false) {
  // Native GitHub identity is the explicit exception to the generic host-secret filter.
  for (const name of ["GH_TOKEN", "GITHUB_TOKEN"] as const) {
    const value = process.env[name];
    if (typeof value === "string") {
      env[name] = value;
    }
  }
}
```

- Bedingung: `host === "gateway"` (kein Sandbox) UND **keine** konfigurierte
  GitHub-Tool-Identity (`tools.github` in openclaw.json). Bei konfigurierter
  Identity würden die Tokens stattdessen gescrubbt und ein managed
  `GH_CONFIG_DIR`-Profil verwendet.
- Unsere Deployment-Config hat kein `tools.github` → `managedLocalIdentity === false`
  → `GH_TOKEN` aus dem Gateway-Prozess-Env fließt in **alle** `exec`-Kommandos,
  inklusive der von Sub-Agents (gleicher Prozess, gleicher exec-Pfad).
- Enthalten in `openclaw/openclaw:2026.8.1-beta.3` (erste Image-Version mit dem Fix;
  stable 2026.8.1 stand am 2026-08-26 noch aus).

## Umsetzung in diesem Repo

1. **`Dockerfile`**: Base-Image gepinnt auf `openclaw/openclaw:2026.8.1-beta.3-slim`
   (mit Kommentar). Zurück auf `:slim`, sobald stable 2026.8.1 den Fix enthält.
2. Kein Config-Feld nötig — der bestehende `env.vars`-Block in `config/openclaw.json`
   (`"GH_TOKEN": "${GH_TOKEN}"`) bleibt korrekt; er versorgt den Gateway-Prozess,
   der Fix re-injiziert das Token dann in exec-Children.
3. Kein Token wird committed — `.env` bleibt nur auf `.149`
   (`/opt/apps/openclaw/config/.env`).

## Verifikation

### Vor dem Fix (2026.7.1) — Bug reproduziert

```sh
env | grep GH_TOKEN            # leer (exec-Tool-Env)
cat /proc/1/environ | tr '\0' '\n' | grep ^GH_TOKEN   # vorhanden (Gateway-Prozess)
gh auth status                 # "You are not logged into any GitHub hosts."
```

### Nach dem Deploy (2026.8.1-beta.3)

```sh
gh auth status                 # "Logged in to github.com account momokli ... (GH_TOKEN)"
gh api user -q .login          # momokli
env | grep -c '^GH_TOKEN='     # 1 (ohne Token-Wert auszugeben!)
```

Zusätzlich per Sub-Agent-Spawn getestet (sessions_spawn → Sub-Agent → exec):
auch dort ist `GH_TOKEN` gesetzt (gleicher exec-Pfad im Gateway-Prozess).

### Isolierter Live-Test ohne Produktions-Deploy

```sh
ssh lan
cd /opt/apps/openclaw
./scripts/test-branch.sh feature/gh-token-env   # baut Branch-Image lokal, Test-Container :18790
docker exec -u node openclaw-test openclaw --version   # 2026.8.1-beta.3
```

## Rollback

- Git: `git revert` des Dockerfile-Commits → CI baut mit altem `:slim`-Base → Deploy.
- Oder lokal: `ssh lan && cd /opt/apps/openclaw && sudo systemctl start openclaw-build.service`
  nach Revert auf `main`.

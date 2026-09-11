# planet Node: Exec-Approvals-Allowlist (Build-Toolchain)

> Kontext: Issue [#65](https://github.com/momokli/openclaw-deploy/issues/65).
> Voraussetzung: Issue [#64](https://github.com/momokli/openclaw-deploy/issues/64)
> (Build-Toolchain `gh`/cargo-PATH/`GH_TOKEN` auf `planet`, `docs/node-build-toolchain.md`).
> Verwandt: [`gh-token-exec-env.md`](gh-token-exec-env.md),
> [`dev-loops-planet.md`](dev-loops-planet.md),
> [`equip-agents.md`](equip-agents.md) (Block B `B11`).
> Stand: 2026-09-11, live auf `planet` verifiziert.

## Zweck

`exec host=node` führt Build-/Coding-Aufgaben auf dem Node-Host `planet` aus.
Die **host-lokale Exec-Approvals-Datei des Nodes ist die durchsetzbare
Wahrheit**; sie liegt in der State-DB des Nodes
(`~/.openclaw/state/openclaw.sqlite#exec_approvals_config`) und wird über
`openclaw approvals … --node <id|name|ip>` bearbeitet.

Aktuell ist die Policy `security=full` / `ask=off` — nichts wird gegated, alles
läuft. Wird die Policy später auf `allowlist` verschärft, verweigert der Node
**jeden** nicht-allowlisteten Befehl ("not in the allowlist"). Damit das die
Build-Agents nicht lahmlegt, wird die **minimale** Build-Toolchain vorab
allowlistet — bewusst **kein** YOLO (`security=full`/`askFallback=full`).

## Was wird freigegeben (minimal)

Pro Build-Agent genau die Executables, die die Pipeline auf `planet` aufruft:

| Befehl   | Pfad auf planet               |
| -------- | ----------------------------- |
| `git`    | `/usr/bin/git`                |
| `gh`     | `/usr/bin/gh`                 |
| `cargo`  | `/home/momo/.cargo/bin/cargo` |
| `rustc`  | `/home/momo/.cargo/bin/rustc` |
| `rustup` | `/home/momo/.cargo/bin/rustup`|
| `node`   | `/opt/node/bin/node`          |
| `npm`    | `/opt/node/bin/npm`           |

Nicht freigegeben: Shells (`sh`/`bash`), generische Interpreter (`python`,
`node -e`, …) und sonstige Basis-Tools. **Wichtig:** Subprozesse, die diese
Tools selbst starten (z. B. `cc`/`ld`/`make` aus einem cargo-Build-Script),
laufen **nicht** durch die Allowlist — gegated wird nur das Top-Level-Kommando,
das ein Agent per `exec` aufruft. Basis-Tools brauchen daher nur dann einen
Eintrag, wenn ein Agent sie *direkt* aufruft.

Build-Agents (Scope der Einträge): `coding-orchestrator` (Recon/Build) und die
Pipeline-Rollen `feature-dev-planner`, `feature-dev-setup`,
`feature-dev-developer`, `feature-dev-verifier`, `feature-dev-tester`,
`feature-dev-reviewer`.

## Provisioning

Idempotentes Skript: [`scripts/setup-node-exec-allowlist.sh`](../scripts/setup-node-exec-allowlist.sh)

```sh
# auf dem Gateway-Host (dort findet `openclaw --node planet` den Node):
scripts/setup-node-exec-allowlist.sh

# Rollback:
scripts/setup-node-exec-allowlist.sh --remove

# Scope anpassen:
NODE=planet AGENTS="feature-dev-developer" scripts/setup-node-exec-allowlist.sh
```

Das Skript ruft für jede (Agent, Pattern)-Kombination
`openclaw approvals allowlist add --node "$NODE" --agent "$AGENT" "$PATTERN"`
auf. Ein bereits vorhandener Eintrag ist ein no-op → beliebig oft ausführbar.
Am Ende wird die Node-Approvals-Datei per `approvals get --node … --json`
ausgelesen und die Zahl der Einträge zusammengefasst.

### Warum ein Skript und kein Config-Block?

Exec-Approvals liegen **nicht** in `openclaw.json`, sondern in der State-DB des
Ausführungs-Hosts. Für Node-Hosts sind sie nur remote über die CLI editierbar
(`openclaw approvals set/add --node …`); es gibt keinen Config-Datei-Pfad, den
dieses Repo versionieren könnte. Das Skript ist deshalb die reproduzierbare
Quelle.

## Verifikation

```sh
# 1. Einträge vorhanden?
openclaw approvals get --node planet --json   # agents.<id>.allowlist[]

# 2. End-to-End: Build läuft auf planet ohne Allowlist-Fehler
#    (exec host=node im Agenten)
```

Referenz-Commit aus der Live-Verifikation (2026-09-11):

```sh
# exec host=node:
git clone --depth 1 https://github.com/momokli/momos-music-manager /home/momo/builds/verify-65
cd /home/momo/builds/verify-65 && cargo test
# → 746 passed; 2 failed (nur `metaflac` fehlt — kein Allowlist-Fehler)
```

Erwartet: `cargo test` läuft; **kein** "not in the allowlist".

## Chained Commands (`&&`) / `cd … && …`

Unter der aktuellen `full`/`off`-Policy laufen auch verkettete Kommandos
(`a && b`, `a; b`, `cd dir && cargo test`) über `exec host=node` durch — live
geprüft. Der Allowlist-Match greift jedoch **pro Kommando-Segment**: ein
verketteter Aufruf zählt nur dann als erlaubt, wenn **jedes** Segment (auch
`cd`) einer Allowlist-Regel entspricht. `cd` ist ein Shell-Builtin und hat
keinen eigenen Pfad-Eintrag — verkettete `cd … && …`-Kommandos sind unter einer
`allowlist`-Policy also **nicht** garantiert.

Empfehlung für allowlist-taugliche Aufrufe: statt Shell-Verkettung das
`workdir`-Feld des `exec`-Tools nutzen

```
# statt:  cd /home/momo/builds/verify-65 && cargo test
# besser: exec host=node, workdir=/home/momo/builds/verify-65, command="cargo test"
```

Dann ist das einzige Kommando-Segment `cargo` → durch die Allowlist gedeckt.

## Abgrenzung: `nodes invoke` ist nicht der Build-Pfad

`openclaw nodes invoke --node planet --command "hostname"` liefert
`node command not allowed: "hostname" is not in the allowlist for platform
"linux"`. Das ist die **Gateway-Kommando-Policy** (`gateway.nodes.commands.allow`
+ Plattform-Defaults), die node-**Command-IDs** wie `system.which` filtert — sie
hat nichts mit Shell-Kommandos zu tun. `system.run` ist über `invoke` ohnehin
gesperrt; Shell-Ausführung läuft ausschließlich über das `exec`-Tool mit
`host=node`. Die Datei, die es dafür freizugeben gilt, ist also die
Exec-Approvals-Datei des Nodes — nicht `gateway.nodes.commands.allow`.

## Rollback

```sh
scripts/setup-node-exec-allowlist.sh --remove
```

Einzelne Einträge:

```sh
openclaw approvals allowlist remove --node planet --agent <agent> <pattern>
```

---
name: minecraft-admin
description: "Mellon-Minecraft (Paper + EssentialsX + LuckPerms) verwalten: Spawn/Warps, Permissions, RCON-Debugging."
metadata:
  {
    "openclaw":
      {
        "requires": { "bins": ["ssh"] },
      },
  }
---

# Minecraft Admin (Mellon)

Use für Admin-Aufgaben auf Momos Mellon-Server (Paper, Docker, itzg/minecraft-server).

## Zugriff

```bash
ssh planet             # Hetzner "planet" via Tailscale (100.77.143.105)
```

> Mesh-first: Admin-SSH zu planet NUR über Tailscale (`ssh planet`). Die Public-IP
> `65.21.27.234` ist nur für Service-Endpoints (MC-Ports/Web), nicht für SSH —
> Incident 2026-09-01 (ufw-LIMIT auf 22/tcp). Siehe `docs/mesh-first-access.md`.

| Env  | Server-Container      | Proxy                   |
| ---- | --------------------- | ----------------------- |
| prod | `mellon-minecraft`    | — (single server)       |
| test | `mellon-test-world1`  | `mellon-test-velocity`  |

Daten liegen im Container unter `/data` (Plugins: `/data/plugins/`). RCON via `rcon-cli`
(im itzg-Image vorhanden):

```bash
docker exec mellon-minecraft rcon-cli "list"
```

## Wichtigste Gotchas (erst lesen)

1. **LuckPerms antwortet NICHT über RCON.** `rcon-cli "lp ..."` liefert (fast) immer LEER —
   LuckPerms schreibt auf Console/Chat, nicht auf RCON-stdout. Leere Ausgabe ist KEIN Fehler
   und KEIN Grund, den Befehl in Varianten zu wiederholen.
2. **Permissions verifizieren** nur über:
   - H2-DB: `docker exec <container> sh -c "strings /data/plugins/LuckPerms/luckperms-h2-v2.mv.db | grep -ioE 'essentials\.[a-z.]+' | sort -u"`
   - Log: `docker logs <container> --since "2026-08-28T19:00:00Z" 2>&1 | grep -iE "luckperms|permission"`
3. **`/spawn` braucht das separate `EssentialsXSpawn`-Jar** (liegt neben EssentialsX in
   `/data/plugins/`). `spawn`/`setspawn` sind NICHT im Haupt-EssentialsX-Jar.

## Seasons = Warps im selben World

`/spawn` zeigt auf die aktuelle Season (season2); ältere Seasons sind Warps
(`season0` = OG-Spawn bei 0,0).

- Spawn: `/data/plugins/Essentials/spawn.yml`
- Warps: `/data/plugins/Essentials/warps/<name>.yml`

`spawn.yml` (season2):

```yaml
spawn:
  world: <world-uuid>
  world-name: world
  x: 11390.0
  y: 154.0
  z: 1292.0
  yaw: 0.0
  pitch: 0.0
new-player-spawn: spawn
new-player-spawn-on-join: true
```

Warp `season0`:

```yaml
name: season0
lastowner: <owner-uuid>
world: <world-uuid>
world-name: world
x: 1.26
y: 115.0
z: -6.57
yaw: 154.35
pitch: 0.0
```

## Permissions (LuckPerms)

Für ALLE (Default-Gruppe) freigeben:

```bash
docker exec <container> rcon-cli "lp group default permission set essentials.spawn true"
docker exec <container> rcon-cli "lp group default permission set essentials.warp true"
docker exec <container> rcon-cli "lp group default permission set essentials.warp.season0 true"
docker exec <container> rcon-cli "lp group default permission set essentials.warp.season1 true"
docker exec <container> rcon-cli "lp group default permission set essentials.warp.season2 true"
```

OP setzen (wirkt sofort):

```bash
docker exec <container> rcon-cli "op <player>"
```

## Stop-Regel

`rcon-cli` liefert leer → NICHT denselben Befehl variieren. Stattdessen: (1) Log checken,
(2) H2-DB checken, (3) falls unklar → Momo fragen.

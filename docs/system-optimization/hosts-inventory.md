# Host-Inventory (live gemessen 2026-09-11)

Stand: 2026-09-11 · Source-of-Truth: dieses Repo · Messung via SSH (`lan-local` / `planet`).

## `.149` (`lan`, 192.168.178.149)

| Merkmal | Wert |
|---|---|
| CPU | 2× Intel Xeon **E5-2650 v2** @ 2.60 GHz, **16 vCPUs** (8C×2 Sockets, **kein HT**), NUMA 0-15 |
| RAM | 105 GiB total, ~96 GiB available (92 GiB buff/cache) |
| Load (normal) | ~2–4 (Spikes → 55–60, siehe incidents) |
| Disk | 1× `sda` 1.6T, `/` auf `sda1` (**69 %**, 483 G frei), **kein** separates Daten-Volume |
| Netz-Mounts | `/mnt/backups`, `/mnt/media` → Hetzner StorageBox 20 T (**82 %**, 3.8 T frei) |

### Storage-Breakdown `/` (1.1 T belegt)

| Pfad | Größe | Was |
|---|---|---|
| `/home/momo` | 453 G | User-Daten (Media/Downloads/etc.) |
| `/srv` | 197 G | `big-stash` 175 G + Game-Server (factorio, mc, cs16 …) |
| `/var/lib/docker` | ~410 G | Images 95.8 G + Container-Writable **167.2 G** + Volumes 138.5 G + Build-Cache 8.4 G |
| Rest (`/usr`, `/opt`, `/tmp`, …) | ~40 G | — |

### Docker

```
Images        247  (61 active)   95.77 GB   (64.24 GB reclaimable)
Containers     79  (26 running) 167.2 GB    (1.33 GB reclaimable)   ← auffällig hoch
Local Volumes  41  (20 active)  138.5 GB
Build Cache   369                8.44 GB    (8.44 GB reclaimable)
```

> **Hinweis:** 167 G Container-Writable-Layer ist ungewöhnlich — vermutlich schreibt ein
> Container in seine eigene Layer statt in ein Named Volume. Separater Untersuchungspunkt.

### Rollen

OpenClaw-Gateway (+ `obsidian-sync` + `ollama`), Stash (`big-stash`, `adult-stash`),
Factorio, Minecraft/CS16-Server, Paperless, Vaultwarden, HA-Stack (Grafana/Prometheus) …

---

## `planet` (Hetzner, 100.77.143.105)

| Merkmal | Wert |
|---|---|
| CPU | 13th Gen Intel **i5-13500**, **20 vCPUs** (14C/20T, HT) |
| RAM | 62 GiB total, ~39 GiB available |
| Load | 1.25 / 1.40 / 1.57 (viel Luft) |
| Identität | **= `projectmellon.de`** (OpenClaw-GH-Runner-Label bestätigt) |

### Disk-Layout

| Device | Größe | Mount | FS | Nutzung |
|---|---|---|---|---|
| `nvme0n1p4` + `nvme1n1p4` (RAID0 `md2`) | 919 G | `/` | ext4 | **89 %** (98 G frei) |
| `nvme2n1p1` | 954 G | `/mnt/hot-cache` | ext4 | **96 %** (42 G frei) |
| `cold:` (rclone fuse) | 60 T | `/mnt/media` | fuse.rclone | 80 % (13 T frei) |
| `md0` (RAID0) | 32 G | swap | — | — |

### Storage-Breakdown `/` (761 G belegt)

| Pfad | Größe | Was |
|---|---|---|
| `/var/lib/docker` | 263 G | Images 100.4 G + Build-Cache 47.9 G + Volumes 45.1 G |
| `/srv` | 239 G | Game-Server: `mc-homestead` 81 G, `e10` 57 G, `mellon-test` 38 G, `aero` 25 G, `funkwhale` 13 G |
| `/opt/apps` | 169 G | `mellon-test` 73 G, `mellon-plex` 38 G, `mellon-minecraft` 27 G, `jellyfin` 18 G |
| `/downloads` | 50 G | — |
| `/opt/backups` | 26 G | — |

### `/mnt/hot-cache` (954 G NVMe)

```
849 G  /mnt/hot-cache/vfs      ← rclone VFS-Cache (Media, "hot tier")
 46 M  /mnt/hot-cache/vfsMeta
```

Setup: `/mnt/media` = `cold:` (60 T) via `rclone mount` mit
`--vfs-cache-mode full`-artigem Cache (`--vfs-cache-max-size`, `--vfs-cache-max-age`,
`--cache-dir`). Die kürzlich abgerufenen Media-Dateien liegen auf dem schnellen NVMe
(`vfs/`), werden bei Bedarf vom `cold:`-Remote nachgeladen/evictiert.

### Rust-/Cargo-Cache (Frage „rust target dirs?“)

```
/home/momo/.cargo   508 M
/home/momo/.rustup  1.5 G
/root/.cargo        236 M
/root/.rustup       1.5 G
→ gesamt ~4 G (vernachlässigbar)
```

### Docker

```
Images        466  (53 active)  100.4 GB   (84.2 GB reclaimable)   ← viele alte openclaw-deploy-Images
Containers     69  (58 running)   2.9 GB
Local Volumes  42  (18 active)   45.1 GB   (20.2 GB reclaimable)
Build Cache  1649                47.9 GB   (47.9 GB reclaimable)
```

### Rollen

GitHub-Actions-Runner (`momokli-openclaw-deploy.projectmellon`, `rbbattle`),
Media-Stack (Plex, Jellyfin, Tautulli, sabnzbd, prowlarr, bazarr, radarr, sonarr),
Game-Server (AzerothCore-WoW ×n, riftbreaker, mc-homestead, factorio), AzuraCast,
Hedgedoc, Funkwhale, deemix, WireGuard, Monitoring (Prometheus/Grafana/Loki).

---

## Gegenüberstellung

| | `.149` | `planet` |
|---|---|---|
| Cores | 16 (alt, kein HT) | 20 (modern, HT) |
| RAM frei | ~96 GiB | ~39 GiB |
| Load | 2–4 (Spikes 55+) | ~1.4 |
| Root frei | 483 G | **98 G (89 % voll)** |
| Extra-Disk | — | NVMe hot-cache 954 G (96 % voll) + `cold:` 60 T |
| Rust-Cache | — | ~4 G (vernachlässigbar) |
| Rolle | Gateway + Stash + Game-Server | Build-Runner + Media + Game-Server |

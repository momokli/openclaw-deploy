# Storage-Analyse (2026-09-11)

Stand: 2026-09-11 · Source-of-Truth: dieses Repo.

Antworten auf die konkreten Fragen: „was braucht viel Storage?“, „rust target dirs? rust
cache? sonstiger Cache?“, „1 TB SATA SSD?“, „hot-cache auf 600 G + 300 G für OpenClaw?“.

---

## Was wirklich viel Storage braucht (Rangfolge)

| # | Was | Größe | Host | Reclaimable? |
|---|---|---|---|---|
| 1 | Media (`cold:` 60 T + rclone-VFS-Cache) | 48 T + 849 G | `planet` | teilweise (VFS-Cache evictierbar) |
| 2 | Docker-Images + Build-Cache | 100 G + 48 G | `planet` | **~132 G** (alte Images + Build-Cache) |
| 3 | Game-Server-Daten (`/srv`, `/opt/apps`) | 239 G + 169 G | `planet` | nein (Live-Daten) |
| 4 | Docker (Images + Container-Writable + Volumes) | 95 G + 167 G + 138 G | `.149` | ~64 G Images + 8 G Build-Cache |
| 5 | `/home/momo` | 453 G | `.149` | nein (User-Daten) |
| 6 | `/srv/big-stash` | 175 G | `.149` | nein (Stash-Daten) |

## Rust — vernachlässigbar

```
planet: /home/momo/.cargo 508 M, .rustup 1.5 G; /root/.cargo 236 M, .rustup 1.5 G → ~4 G
```

**Kein** großer `target/`-Ordner liegt persistent vor. Die Rust-Compiles der
OpenClaw-Images laufen **im Docker-Build** (GH-Runner auf `planet`) → ihre Artefakte
landen im **Docker-Build-Cache + Image-Layer**, nicht in separaten `target/`-Verzeichnissen.
Der `mmm-loop`-`cargo test` (Incident #3) baut in `/tmp/mmm-issue27/target` (flüchtig).

## Reclaimable sofort (ohne Kauf)

### `planet` (Root 89 % voll, 98 G frei)
| Quelle | Größe |
|---|---|
| `docker builder prune` (Build-Cache) | **47.9 G** |
| alte `ghcr.io/momokli/openclaw-deploy`-Images (30+, je 2.5–4.9 G) | **~84 G** |
| **Summe** | **~130 G** |

### `.149` (Root 69 % voll, 483 G frei)
| Quelle | Größe |
|---|---|
| Docker-Images reclaimable | ~64 G |
| Build-Cache | ~8 G |
| Container-Writable-Layer (167 G — Ursache klären) | potenziell viel |

## rclone-VFS-Cache (`/mnt/hot-cache`, 954 G NVMe)

- `/mnt/hot-cache/vfs` = **849 G** = rclone-VFS-Cache für die Media-Library
  (`/mnt/media` = `cold:` 60 T via `rclone mount`).
- Gestaffelt über `--vfs-cache-max-size` / `--vfs-cache-max-age` / `--cache-dir`.

### Kann man ihn kleiner machen?

**Ja.** `--vfs-cache-max-size` von ~850 G auf z. B. 600 G senken → ~250–350 G NVMe frei.
**Nuance:** Es ist **eine einzige 954-G-Partition**. Der Cache ist ein **Soft-Cap** —
unter Druck kann rclone drüber wachsen und mit OpenClaw-Daten um denselben Platz konkurrieren.

Drei saubere Varianten:

- **a)** Cache auf 600 G cappen, OpenClaw-Workdirs auf dieselbe Partition, mit Monitoring.
- **b)** NVMe-Partition verkleinern + **zweite Partition** exklusiv für OpenClaw
  (sauber, aber Resize-Downtime/Risiko).
- **c)** erstmal nur die ~130 G aus dem Docker-Cleanup nutzen und schauen, ob's reicht.

## Braucht es eine 1 TB SATA SSD?

**Nein, aktuell nicht.** Argumente:

1. ~130 G auf `planet`-Root sind sofort reclaimable (Docker-Cleanup).
2. ~250–350 G auf der NVMe sind per rclone-Cache-Cap freizubekommen.
3. Eine **SATA-SSD wäre langsamer** als das vorhandene NVMe — die falsche Richtung.

Erst aufräumen + cappen, dann neu messen. SSD nur kaufen, wenn danach noch echter
Bedarf besteht **und** die NVMe tatsächlich ausgeschöpft ist.

## „Slow data auf /media“ — passt

`cold:` (`/mnt/media`) ist genau der Ort für kalte Daten (Media, Backups, selten
angefasste Artefakte). Heiße Build-/Workdirs gehören auf NVMe, kalte auf `cold:`.

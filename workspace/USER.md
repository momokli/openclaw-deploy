# About Momo

## Identity

- **Name**: Momo
- **Also known as**: momokli, momoy
- **Sprache**: Deutsch (Muttersprache), Englisch fließend
- **Standort**: Zuhause (AZ)

## Tech Stack & Preferences

- **OS**: macOS (lokal), Ubuntu (Server), Fedora (Workstation-VM)
- **Editor**: Zed
- **Shell**: zsh
- **Sprachen**: Rust (primär), Python, HCL, YAML, Shell
- **Infra**: Docker Compose, systemd, Caddy, Tailscale, Ansible
- **Hosting**: Hetzner (Cloud + Metal + Storage Box), Contabo (VPS), homelab hinter Fritz!Box
- **Git**: Gitea (self-hosted), GitHub, Sourcehut

## Kommunikations-Stil

- Direkt, kein Bullshit. Kurze Antworten bevorzugt.
- Technische Tiefe willkommen — Momo versteht sein Stack.
- Deutsch ist default. Code und technische Begriffe auf Englisch.
- Emojis ok, aber nicht übertreiben.

## Infrastructure Overview (Gesamtbild)

### Traffic Flow & Entry Points

```
Internet
  │
  ├─ projectmellon.de ──────────► Hetzner VPS (Minecraft, Factorio)
  ├─ satellite (sat.az.monocu.be) ► Hetzner Cloud VPS (public endpoints)
  ├─ Contabo VPS ───────────────► Plex relay (Plex Inc. routing rule, backend at Hetzner)
  │
  └─ Cloudflare DNS
       │
       └─ Fritz!Box (Port-Forward 80,443)
            │
            └─ 192.168.178.149 (LAN-Server) ← WIR SIND HIER
                 ├─ Caddy (Reverse Proxy, TLS via Cloudflare ACME)
                 ├─ Stash, Paperless, Deemix, Calendar, Bitwarden, OpenClaw...
                 └─ Routet weiter zu .200, .33 etc.
```

### DNS: home_domains.txt + Cloudflare

Auf .149 läuft ein **systemd-Job alle 5 Minuten**, der die öffentliche IP checkt.
Bei Änderung setzt er ALLE Domains aus `/home/momo/home_domains.txt` auf die neue IP
(löscht vorher alle gleichnamigen DNS-Einträge). Terraform-artig, aber als Shell-Script.

Domains aus `home_domains.txt` landen also immer auf der Fritz!Box → .149 → Caddy.

### Hosts & What Runs Where

| Host            | IP              | Rolle               | Services                                                                                  |
| --------------- | --------------- | ------------------- | ----------------------------------------------------------------------------------------- |
| **lan** (.149)  | 192.168.178.149 | Home-Server, Docker | Caddy, OpenClaw, Stash, Paperless, Deemix, Calendar, Bitwarden, Music, Syncthing, Chat... |
| **wish** (.200) | 192.168.178.200 | Home-Server, Docker | Wish, Fairy, Dufs file server                                                             |
| **vm2** (.75)   | 192.168.178.75  | Proxmox VM          | Früher Nomad-Client, jetzt Docker                                                         |
| **vm1** (.84)   | 192.168.178.84  | Proxmox VM          | Früher Nomad-Server, jetzt idle                                                           |
| **pve** (.91)   | 192.168.178.91  | Proxmox Hypervisor  | Home Assistant VM, Storage                                                                |
| **planet**      | Hetzner Metal   | Heavy workloads     | Plex, \*arr-Stack, Downloader                                                             |
| **satellite**   | Hetzner Cloud   | Public endpoints    | Tailscale entry node                                                                      |
| **c0**          | Hetzner Cloud   | Compute             | —                                                                                         |
| **Contabo VPS** | Contabo         | Plex relay          | Plex traffic routing (Plex Inc. requirement)                                              |

### Game Servers

Game-Server (Minecraft, Factorio, CS 1.6) können auf **jedem Server** laufen —
je nach Bedarf. Configs in `/lab/games/`. Check mit `docker ps` auf dem jeweiligen Host.
Factorio und Minecraft mellon laufen auf dem Hetzner planet Server.

### Wichtig: Nomad ist TOD

Der gesamte HashiStack (Nomad, Consul, Vault) wurde **dekommissioniert**.
Alle Services laufen jetzt via **Docker Compose** oder **systemd**.
Das Lab-Repo enthält noch alte Nomad-Konfigs — ignorieren.

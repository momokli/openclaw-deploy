# Mesh-first Zugriffsrichtlinie (Tailscale-first Admin-SSH)

Stand: 2026-09-01. Verbindliche Richtlinie für **Admin-Zugriff (SSH)** auf alle Hosts
dieser Infrastruktur. Eingewoben nach dem SSH-Incident vom 2026-09-01 (siehe unten).

## Die Regel in drei Sätzen

1. **Admin-SSH zu allen Hosts läuft IMMER über Tailscale** — über die `ssh_config`-Aliase
   (`lan`, `planet`, …) bzw. MagicDNS-Hostnamen oder `100.x`-Adressen. Öffentliche
   IP-Adressen werden für SSH **nicht** verwendet.
2. **Public-IPs / öffentliches DNS sind ausschließlich für Service-Endpoints** — Web
   (Caddy), Deploy-Webhook, Minecraft-Ports u. Ä. Diese müssen öffentlich erreichbar
   bleiben und sind kein Admin-Zugriff.
3. **Bei SSH-Symptomen wie „Connection refused" / REJECT nie vorschnell fail2ban die
   Schuld geben** — zuerst `ufw status verbose` (insbesondere `LIMIT`-Regeln auf `22/tcp`)
   UND `fail2ban-client status sshd` prüfen, dann erst eine Ursache benennen.

## Host-Übersicht (Admin-Zugriff = Tailscale)

| Host | Rolle | Admin-SSH (Tailscale) | Public-IP (nur Services) | LAN (nur lokaler Fallback) |
| ---- | ----- | --------------------- | ------------------------ | -------------------------- |
| `.149` (lan) | OpenClaw-Home-Server | `ssh lan` → `100.85.52.13` (`momo@lan`) | — | `192.168.178.149` (`lan-local`) |
| `planet` | Hetzner (u. a. Mellon-Minecraft) | `ssh planet` → `100.77.143.105` (`root@…`) | `65.21.27.234` | — |
| `satellite` | Hetzner, Tailscale-Entry | via Tailscale (Adresse: `tailscale status`) | — | — |
| `c0`, Contabo | weitere Hosts | via Tailscale (Adresse: `tailscale status`) | — | — |

Die Aliase `lan` / `lan-local` / `planet` sind in [`ssh_config`](../ssh_config)
definiert und werden in das Gateway-Image kopiert (`Dockerfile` → `/home/node/.ssh/config`),
stehen also auch dem Operator-Agent im Container zur Verfügung.

## Warum diese Regel existiert — Incident 2026-09-01

- Symptom: SSH auf **planets Public-IP** (`65.21.27.234`) antwortete mit
  **„Connection refused"**.
- Erste (falsche) Vermutung: fail2ban hätte unsere IP gebannt. **Falsch** — die IP war
  nie gebannt.
- Tatsächliche Ursache: **ufw-Regel `LIMIT` auf `22/tcp`**. ufw-LIMIT erlaubt nur
  **>6 neue Verbindungen pro 30 s**; darüber wird mit `REJECT` beantwortet → SSH wirkt
  „tot", obwohl der Dienst läuft.
- Konsequenz: Admin-SSH zu planet läuft seitdem **ausschließlich über Tailscale**
  (`100.77.143.105`). Die Whitelist `ufw allow from 84.171.11.160 port 22` existiert nur
  als Komfort für die Homelab-IP — **darauf verlassen wir uns nicht**, weil die
  Homelab-IP dynamisch ist.

## Do / Don't

| Do ✅ | Don't ❌ |
| ----- | -------- |
| `ssh lan`, `ssh planet` (Aliase → Tailscale) | `ssh root@65.21.27.234` (Public-IP) |
| Tailscale-Adressen (`100.x`) / MagicDNS in Scripts & Configs | Public-/LAN-IPs in Scripts & Configs für Admin-Zwecke |
| Bei Verbindungsproblemen: `ufw status verbose` + `fail2ban-client status sshd` prüfen | Sofort fail2ban verdächtigen |
| Neue Hosts ins Tailscale-Mesh aufnehmen, bevor sie administriert werden | SSH-Port öffentlich öffnen (auch nicht „nur für mich", IPs sind dynamisch) |
| Service-Endpoints (Web/Webhook/MC) öffentlich lassen — das ist gewollt | Public-IPs für Nicht-Service-Zwecke (SSH, Admin-Panels) nutzen |

## Bewusst öffentlich (Service-Endpoints, kein Admin-Zugriff)

Diese Endpoints bleiben absichtlich über Public-IP/DNS erreichbar — sie sind Services,
nicht Admin-Zugriff, und werden von der Richtlinie **nicht** erfasst:

- `https://openclaw.simonklimke.de` — Web-UI (Caddy → Docker auf `.149`)
- `https://deploy.openclaw.simonklimke.de/deploy` — Deploy-Webhook (Bearer-Token;
  öffentlich erreichbar, damit GitHub Actions ihn erreichen kann)
- Minecraft-Server-Ports auf planet (`65.21.27.234`)

## SSH-Diagnose-Kurzcheck (bei „Connection refused" / REJECT)

```sh
# 1) ufw zuerst — LIMIT auf 22/tcp ist der häufigste Übeltäter:
ssh planet 'sudo ufw status verbose | grep -E "22|Status"'

# 2) fail2ban erst danach:
ssh planet 'sudo fail2ban-client status sshd'

# 3) Dienst läuft? (auf planet z. B. sshd):
ssh planet 'systemctl is-active ssh'
```

Reihenfolge ist wichtig: ufw-LIMIT erzeugt „Connection refused"-artige Symptome, ohne
dass fail2ban involviert ist. Nach 2026-09-01 gilt: **erst ufw, dann fail2ban, dann
Rest.**

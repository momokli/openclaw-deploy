# Deployment Review — SOTA-Abgleich (2026-08-19)

Methode: Kagi Search (`docs/kagi.md`, korrekte v1-Nutzung) + `docs.openclaw.ai` + 3 Sub-Agents +
Live-Verifikation auf `.149` (laufende Version `2026.7.1`).

## Live-Verifikation

- `openclaw config validate` → **„Config valid"**
- `caddy_default` Subnet = `172.23.0.0/16`, Gateway `172.23.0.1`, Caddy-Container-IP `172.23.0.3`

## Korrektur (False Positives aus Docs-Abgleich)

Die Sub-Agents haben gegen die **aktuelle** docs.openclaw.ai geprüft und dabei zwei
Schema-Mismatches vermutet (`agents.list` → `agents.entries`, `agents.defaults.memorySearch` →
`memory.search`). **Nicht bestätigt:** `openclaw config validate` akzeptiert die vorhandene
Struktur. docs.openclaw.ai dokumentiert vermutlich eine **neuere** Schema-Version als die laufende
`2026.7.1`. → Vor einer Migration erst `openclaw config schema` gegen die installierte Version
prüfen, nicht blind umbauen.

## Bestätigte Findings (priorisiert)

### P0

1. **`gateway.trustedProxies` falsch (KONFIRMIERT).** Config hat `["172.17.0.1"]` (Default-Bridge),
   aber Caddy erreicht den Gateway über das externe Netz `caddy_default` = `172.23.0.0/16`
   (Caddy-IP `172.23.0.3`). → Proxy-Header von Caddy gelten als „untrusted".
   **Fix:** `trustedProxies: ["172.23.0.0/16"]`.
2. **Image-Pinning.** `FROM openclaw/openclaw:slim` (floating) + Deploy `:latest`.
   **Fix:** immutablen Tag/Digest pinnen; `:sha` statt `:latest` deployen.
3. **SSH-Key im Agent-Filesystem.** `${HOME}/.ssh/id_ed25519` wird in den Container gemountet,
   kein Sandbox/Tool-Policy → Agent kann den Operator-Key lesen/exfiltrieren.
   **Fix:** Mount entfernen oder auf Deploy-Key mit Least-Privilege reduzieren; Sandbox +
   `tools`-Policy aktivieren.
4. **Telegram-Gruppen-Auth fehlt.** `groups: {"*"}` + kein `allowFrom`/`groupAllowFrom` → jede
   Gruppe, die den Bot hinzufügt, kann ihn per @-Mention auslösen.
   **Fix:** explizite numerische Gruppen-IDs + `allowFrom` (Owner).
5. **Webhook cleartext + `0.0.0.0`.** Receiver bindet `0.0.0.0:18791`, Caddy proxyt auf
   `192.168.178.149:18791` (Klartext-LAN). **Fix:** `127.0.0.1` binden, Caddy → `127.0.0.1:18791`.

### P1

6. **`env.vars` dupliziert alle Provider-Secrets** (DEEPSEEK/GROQ/DEEPGRAM/GH/GEMINI) → liegen im
   Agent-Shell. **Fix:** nur `KAGI_API` (+ ggf. `GH_TOKEN`) behalten.
7. **`OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=true`** ist client-seitig, nicht Gateway. → entfernen.
8. **SSH `StrictHostKeyChecking accept-new`** (TOFU) für git/infra-Hosts. → `known_hosts` pinnen.
9. **Kein Model-Fallback** (`primary` only, AGENTS.md behauptet „V4 Flash fallback").
   → `model.fallbacks: ["deepseek/deepseek-v4-flash"]`.
10. **Ansible stale:** provisioniert `coding`/`diary` (nicht in Config) + printet Gateway-Token
    (kein `no_log`).
11. **Webhook-Secret-Modell:** `webhook-token` owner root (Service läuft als `momo`), `DEPLOY_TOKEN`
    fehlt in `.env.example`, sudoers-NOPASSWD fehlt, `GHCR_TOKEN` → `${{ github.token }}` ersetzen.

### P2

12. Healthcheck nur `/healthz` → `/startupz` (startup) / `/readyz` (deep readiness) ergänzen.
13. Deploy nicht fail-closed: `build-and-deploy.sh` persistiert Hash-Files auch bei ungesundem
    Container → erst nach bestandenem Health-Check persistieren, sonst `exit 1`.
14. `workspace/AGENTS.md` stale („memory_search NICHT verfügbar" widerspricht Config).
15. Action-Versionen auf SHA pinnen + Provenance/SBOM (`docker/build-push-action` + `actions/attest`).

## Korrektur (Kosten, 2026-08-21)

Die in früheren Notizen verwendeten DeepSeek-Preise waren **~3× zu niedrig** (Preiserhöhung ab 16./17. Aug). Aktuell offiziell:

| Modell              | Input (cache miss) | Input (cache hit) | Output     |
| ------------------- | ------------------ | ----------------- | ---------- |
| `deepseek-v4-flash` | $0.22/0.44         | $0.007/0.014      | $0.66/1.32 |
| `deepseek-v4-pro`   | $0.66/1.32         | $0.022/0.044      | $1.98/3.96 |

(off-peak/peak, USD pro 1M Tokens). Pro = 3× Flash; Cache-Hit ≈ 30× günstiger.
Umgesetzt: `feature-dev-*` → Flash, `compaction.model` → Flash, `messages.responseUsage: "tokens"`.

## Nächste Schritte

- P0 in kleinen, reviewbaren Commits als PR vorlegen (nicht alles in einem).
- `trustedProxies` ✅ (erledigt). Restliche P0/P1: Image-Pinning, SSH-Key-Least-Privilege, Telegram-Gruppen-Auth, Webhook-Containerisierung, `models.providers.cost` (erst gegen 2026.7.1 validieren).

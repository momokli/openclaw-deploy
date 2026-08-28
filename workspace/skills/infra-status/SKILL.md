---
name: infra-status
description: "Infra-Status (Hetzner/Contabo/Cloudflare/INWX) via scripts/infra-status.sh abfragen: Tokens nur aus config/.env, nie committen."
metadata:
  {
    "openclaw":
      {
        "requires": { "bins": ["curl"] },
      },
  }
---

# Infra-Status (Hetzner / Contabo / Cloudflare / INWX)

Use für den Schnell-Check aller Cloud-APIs (Server, StorageBoxes, Contabo-Instances,
Cloudflare-Zonen, INWX-Domains) über ein einzelnes, idempotentes Script.

## Zugriff / Aufruf

```bash
cd /opt/apps/openclaw   # auf .149, bzw. Repo-Root
./scripts/infra-status.sh
```

Lokal zum Testen die Secrets erst in die Shell laden:

```bash
set -a; source config/.env; set +a
./scripts/infra-status.sh
```

## Wichtigste Gotchas (erst lesen)

1. **Tokens kommen AUSSCHLIESSLICH aus der Umgebung** (`config/.env` auf `.149`,
   gitignored). Nichts in das Script schreiben und **keine Secrets committen** — das
   Script selbst liest keine Datei, nur Env-Vars.
2. **Hetzner-Token ist PROJEKT-gebunden.** Ein Token sieht nur sein eigenes Projekt:
   - `HETZNER_API_TOKEN_MITTELERDE` → Server (Projekt „mittelerde",
     `https://api.hetzner.cloud/v1/servers`)
   - `HETZNER_API_TOKEN_STORAGEBOXES` → StorageBoxes (Projekt **11031986**,
     Cloud-API `https://api.hetzner.com/v1/storage_boxes`, **nicht** die alte Robot-API)
3. **Contabo = OAuth2 `grant_type=password`** (nicht `client_credentials` — das scheitert
   mit `unauthorized_client`). Felder: `client_id` + `client_secret` + `username`
   (= CCP-Email) + `password` (= separates API-Passwort aus `my.contabo.com/api/details`,
   NICHT das CCP-Login-Passwort).
4. **INWX = HTTP Basic Auth** mit User + Passwort (`-u "$INWX_API_USER:$INWX_API_PASSWORD"`),
   **kein** Token. API-Passwort ist das separate INWX-API-Passwort, nicht das
   Account-Passwort. Erfolgscode ist `1000`.
5. **Cloudflare = Bearer-Token** (`Authorization: Bearer $CLOUDFLARE_API_TOKEN`).
6. **Das Script skippt fehlende/leere Tokens mit Warnung und Exit-Code 0** — es ist
   gefahrlos idempotent, eine fehlende Sektion ist kein Fehler. Secrets werden nie
   ausgegeben.

## Stop-Regel

Wenn eine Sektion leer ist oder eine Warnung (`WARN: ...`) erscheint: **nicht** die
Commando-Zeilen variieren oder Tokens erfinden. Zuerst prüfen, ob das Token in
`config/.env` auf `.149` gesetzt ist; sonst Momo fragen. Secrets niemals selbst in
Dateien eintragen.

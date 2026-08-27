# Infra-Zugriff — Hetzner / Contabo / Cloudflare

Stand: 2026-08-27. Zugriff auf die drei Cloud-APIs, u.a. für den Dekommissionierungs-Plan
des Hetzner-Stacks. Die Tokens werden **ausschließlich** über Umgebungsvariablen genutzt
(`config/.env` auf `.149`, gitignored) und **nie** committet.

Schnell-Check aller drei APIs:

```sh
./scripts/infra-status.sh
```

## Voraussetzungen

Die Secrets liegen auf `.149` in `/opt/apps/openclaw/config/.env` (gitignored, wird via
docker-compose `env_file` + `entrypoint.sh` in den Container injiziert). Zum Testen lokal
in die Shell laden:

```sh
set -a; source config/.env; set +a
```

| Variable                    | Zweck                                    |
| --------------------------- | ---------------------------------------- |
| `HETZNER_API_TOKEN`         | Hetzner Cloud API v1 (Bearer)            |
| `CONTABO_CLIENT_ID`         | Contabo Cloud API v2 (OAuth2-Client)     |
| `CONTABO_CLIENT_SECRET`     | Contabo Cloud API v2 (OAuth2-Secret)     |
| `CLOUDFLARE_API_TOKEN`      | Cloudflare API v4 (Bearer)               |

## Hetzner Cloud

API-Basis: `https://api.hetzner.cloud/v1` — Auth: `Authorization: Bearer $HETZNER_API_TOKEN`.

```sh
curl -H "Authorization: Bearer $HETZNER_API_TOKEN" https://api.hetzner.cloud/v1/servers
```

Weitere relevante Endpunkte:

```sh
# Volumes (angehängte Festplatten)
curl -H "Authorization: Bearer $HETZNER_API_TOKEN" https://api.hetzner.cloud/v1/volumes
# Private Networks
curl -H "Authorization: Bearer $HETZNER_API_TOKEN" https://api.hetzner.cloud/v1/networks
# Rechnungen (für Kosten)
curl -H "Authorization: Bearer $HETZNER_API_TOKEN" https://api.hetzner.cloud/v1/invoices
```

**Alternative (hcloud-CLI):** Falls die `hcloud`-CLI installiert ist, geht es einfacher —
sie liest das Token aus `HCLOUD_TOKEN` bzw. `--token`:

```sh
hcloud server list
hcloud volume list
hcloud invoice list
```

## Contabo (Cloud API v2)

Contabo nutzt OAuth2 (`client_credentials`). Zuerst einen Access-Token holen —
Platzhalter durch die Werte aus `config/.env` ersetzen:

```sh
curl -d "client_id=...&client_secret=...&grant_type=client_credentials" \
  https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token
```

Die Antwort enthält ein Feld `access_token`. Damit dann die Instances abfragen:

```sh
TOKEN=$(curl -s -d "client_id=$CONTABO_CLIENT_ID&client_secret=$CONTABO_CLIENT_SECRET&grant_type=client_credentials" \
  https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')

curl -H "Authorization: Bearer $TOKEN" https://api.contabo.com/v1/compute/instances
```

Hinweis: Der Access-Token läuft nach kurzer Zeit ab (`expires_in`, meist 3600 s) — bei
Bedarf einfach neu holen.

## Cloudflare

API-Basis: `https://api.cloudflare.com/client/v4` — Auth: `Authorization: Bearer $CLOUDFLARE_API_TOKEN`.

```sh
curl -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" https://api.cloudflare.com/client/v4/zones
```

DNS-Records einer Zone (Zone-ID vorher aus der Zonen-Liste holen):

```sh
curl -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/<ZONE_ID>/dns_records"
```

## Best Practices

- **Tokens nur via Env nutzen, nie committen.** Die echten Werte gehören ausschließlich
  in `config/.env` auf `.149` — dort ist die Datei gitignored und wird von docker-compose
  (`env_file`) + `entrypoint.sh` injiziert.
- Keine Tokens in Shell-History, Logs oder Screenshots ausgeben.
- Bei API-Fehlern zuerst prüfen, ob der Token noch gültig bzw. die IP erlaubt ist
  (Hetzner/Cloudflare unterstützen IP-Allowlists).
- Für automatisierte Checks `scripts/infra-status.sh` nutzen (skippt fehlende Tokens
  mit Warnung, Exit-Code 0).

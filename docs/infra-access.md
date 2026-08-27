# Infra-Zugriff — Hetzner (Cloud + Robot) / Contabo / Cloudflare / INWX

Stand: 2026-08-27. Zugriff auf die Cloud-APIs von Hetzner (Cloud-API + Robot-API),
Contabo, Cloudflare sowie den Domain-Registrar INWX, u.a. für den
Dekommissionierungs-Plan des Hetzner-Stacks. Die Tokens/Zugangsdaten werden
**ausschließlich** über Umgebungsvariablen genutzt (`config/.env` auf `.149`,
gitignored) und **nie** committet.

Schnell-Check aller APIs:

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

| Variable                          | Zweck                                                      |
| --------------------------------- | ---------------------------------------------------------- |
| `HETZNER_API_TOKEN_MITTELERDE`    | Hetzner Cloud API v1, Projekt **mittelerde** (Server)      |
| `HETZNER_API_TOKEN_STORAGEBOXES`  | Hetzner Cloud API v1, Projekt **StorageBoxes** (derzeit leer) |
| `HETZNER_ROBOT_USER`              | Hetzner **Robot**-Webservice-User (StorageBoxes, Basic Auth) |
| `HETZNER_ROBOT_PASSWORD`          | Hetzner **Robot**-Webservice-Passwort (StorageBoxes)       |
| `CONTABO_CLIENT_ID`               | Contabo Cloud API v2 (OAuth2-Client)                       |
| `CONTABO_CLIENT_SECRET`           | Contabo Cloud API v2 (OAuth2-Secret)                       |
| `CLOUDFLARE_API_TOKEN`            | Cloudflare API v4 (Bearer)                                 |
| `INWX_API_USER`                   | INWX DomRobot – Benutzername (Login)                       |
| `INWX_API_PASSWORD`               | INWX DomRobot – API-Passwort                               |

## Hetzner Cloud

API-Basis: `https://api.hetzner.cloud/v1` — Auth: `Authorization: Bearer $HETZNER_API_TOKEN_...`.

**Wichtig — ein Token pro Projekt:** Die Hetzner-API ist **projektbezogen**: ein
API-Token sieht ausschließlich die Ressourcen (Server, Volumes, Netzwerke, Rechnungen)
des Projekts, in dem er erzeugt wurde. Die **Server** laufen im Projekt **mittelerde**
(`HETZNER_API_TOKEN_MITTELERDE`); das Projekt **StorageBoxes**
(`HETZNER_API_TOKEN_STORAGEBOXES`) ist in der Cloud-API derzeit **leer** (0 Server,
0 Volumes, 0 Netzwerke).

```sh
# Projekt mittelerde: Server
curl -H "Authorization: Bearer $HETZNER_API_TOKEN_MITTELERDE" https://api.hetzner.cloud/v1/servers
```

**Hinweis:** Die Hetzner Cloud API antwortet mit **hübsch formatiertem (mehrzeiligem)
JSON** — beim manuellen Parsen besser `jq`/`python3` nutzen statt Einzeilen-Regexen.
`scripts/infra-status.sh` gibt pro Server Name, Status, **Typ** (`server_type.name`)
und Standort aus:

```sh
./scripts/infra-status.sh
# => sync  running  cx11  hel1
```

Weitere relevante Endpunkte (jeweils mit dem Token des passenden Projekts):

```sh
# Private Networks (Projekt mittelerde)
curl -H "Authorization: Bearer $HETZNER_API_TOKEN_MITTELERDE" https://api.hetzner.cloud/v1/networks
# Rechnungen / Kosten (Projekt mittelerde)
curl -H "Authorization: Bearer $HETZNER_API_TOKEN_MITTELERDE" https://api.hetzner.cloud/v1/invoices
```

**Alternative (hcloud-CLI):** Falls die `hcloud`-CLI installiert ist, geht es einfacher —
sie liest das Token aus `HCLOUD_TOKEN` bzw. `--token`:

```sh
export HCLOUD_TOKEN="$HETZNER_API_TOKEN_MITTELERDE"
hcloud server list
hcloud volume list
hcloud invoice list
```

## Hetzner StorageBoxes (Robot API)

**StorageBoxes laufen NICHT über die Hetzner Cloud API.** Es gibt dort keinen
`/storage_boxes`-Endpunkt (HTTP 404) — Storage-Boxen werden über die **Robot API**
verwaltet: `https://robot-ws.your-server.de`, authentifiziert mit **HTTP Basic Auth**
(Webservice-User + Passwort, **nicht** der Cloud-API-Token). Den Webservice-User legt
man im Robot-Panel an: „Einstellungen“ → „Webservice & App-Einstellungen“.

```sh
# Alle StorageBoxes (Basic Auth: Robot-Webservice-User + Passwort)
curl -u "$HETZNER_ROBOT_USER:$HETZNER_ROBOT_PASSWORD" \
  https://robot-ws.your-server.de/storagebox

# Einzelne StorageBox
curl -u "$HETZNER_ROBOT_USER:$HETZNER_ROBOT_PASSWORD" \
  https://robot-ws.your-server.de/storagebox/123456
```

Die Antwort ist ein Array von `{"storagebox": {…}}`-Objekten (id, login, name,
product, location, paid_until, …). Fehler kommen als `{"error": {"status", "code",
"message"}}`; falsche Zugangsdaten → HTTP 401 (Achtung: nach 3 Fehlversuchen wird die
IP für 10 Minuten blockiert).

`scripts/infra-status.sh` zeigt die StorageBoxes nur, wenn `HETZNER_ROBOT_USER` +
`HETZNER_ROBOT_PASSWORD` gesetzt sind — sonst erscheint ein Hinweis, dass
StorageBoxes nicht über die Cloud-API abrufbar sind.

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

**Wenn die Token-Abfrage fehlschlägt:** Auth-URL und Feldnamen sind Keycloak-Standard
(`client_id`, `client_secret`, `grant_type=client_credentials`). Die Antwort enthält
dann einen Fehlertext, z. B.

```json
{"error":"unauthorized_client","error_description":"Client not enabled to retrieve service account"}
```

Das bedeutet: Client-Id/-Secret sind ungültig oder der OAuth2-Client ist im
Contabo-Kundenportal nicht für den Service-Account-Zugriff aktiviert.
`scripts/infra-status.sh` gibt diesen Fehlertext aus (ohne Secrets zu leaken).

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

## INWX (Domain-Registrar, DomRobot)

INWX ist der Domain-Registrar. Die **DomRobot**-API authentifiziert mit **Benutzer +
Passwort** (kein klassisches API-Token) — HTTP Basic Auth mit dem INWX-Login
(`INWX_API_USER`) und dem API-Passwort (`INWX_API_PASSWORD`). Zwei Endpunkte:

- **REST:** `https://api.inwx.com/rest/` (empfohlen, einfach mit curl)
- **XML-RPC:** `https://api.inwx.com/xmlrpc/` (klassisches DomRobot-Protokoll)

Die REST-Endpunkte entsprechen den DomRobot-Methodennamen (`domain.list`,
`nameserver.info`, …). Die Antwort ist standardmäßig XML — mit dem Header
`Accept: application/json` kommt JSON.

Domains-Liste abrufen:

```sh
curl -s -u "$INWX_API_USER:$INWX_API_PASSWORD" \
  -H "Accept: application/json" \
  "https://api.inwx.com/rest/domain.list"
```

Nameserver eines Domains prüfen:

```sh
curl -s -u "$INWX_API_USER:$INWX_API_PASSWORD" \
  -H "Accept: application/json" \
  "https://api.inwx.com/rest/nameserver.info?domain=example.de"
```

XML-RPC-Alternative (gleiche Methode, XML-Payload):

```sh
curl -s -u "$INWX_API_USER:$INWX_API_PASSWORD" \
  https://api.inwx.com/xmlrpc/ \
  -d '<?xml version="1.0"?><methodCall><methodName>domain.list</methodName><params></params></methodCall>'
```

Hinweise:

- Erfolgreiche Antworten liefern den Code `1000`; Fehler einen eigenen Fehlercode
  (z. B. `2001` = Login fehlgeschlagen) plus `msg`-Beschreibung.
- Das API-Passwort ist **nicht** das Account-Passwort — es wird im INWX-Panel
  separat für den API-Zugriff gesetzt/verwaltet.

## Best Practices

- **Tokens nur via Env nutzen, nie committen.** Die echten Werte gehören ausschließlich
  in `config/.env` auf `.149` — dort ist die Datei gitignored und wird von docker-compose
  (`env_file`) + `entrypoint.sh` injiziert.
- Keine Tokens/Passwörter in Shell-History, Logs oder Screenshots ausgeben.
- Bei API-Fehlern zuerst prüfen, ob der Token noch gültig bzw. die IP erlaubt ist
  (Hetzner/Cloudflare unterstützen IP-Allowlists; INWX: Login/API-Passwort prüfen).
- Hetzner StorageBoxes gehören zur **Robot API** (Basic Auth) — der Cloud-API-Token
  kann sie nicht abrufen (`/storage_boxes` → HTTP 404).
- Für automatisierte Checks `scripts/infra-status.sh` nutzen (skippt fehlende Tokens
  mit Warnung, Exit-Code 0).

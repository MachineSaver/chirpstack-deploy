# ChirpStack v4 — Repeatable Docker Compose Deployment

A self-contained, production-ready deployment of [ChirpStack v4](https://www.chirpstack.io/) — the open-source LoRaWAN Network Server. Run `./setup.sh` and answer the prompts. That's it.

**Supports:**
- VPS with a domain name (HTTPS via Let's Encrypt)
- Local network / home lab (plain HTTP, no domain needed)
- US915 (Americas) and EU868 (Europe) frequency region modules
- Semtech UDP and Basics Station gateway protocols
- Optional Grafana monitoring stack with PostgreSQL gateway state and InfluxDB traffic charts

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Data Flow: Sensor to Integration](#data-flow-sensor-to-integration)
3. [Deployment Modes](#deployment-modes)
4. [Port Map](#port-map)
5. [Prerequisites](#prerequisites)
6. [Quick Start](#quick-start)
7. [What setup.sh Does](#what-setupsh-does)
8. [Adding Your First Gateway](#adding-your-first-gateway)
9. [Adding Your First Device](#adding-your-first-device)
10. [Integrations](#integrations)
11. [Monitoring (Grafana + InfluxDB)](#monitoring-grafana--influxdb)
12. [Configuration Reference](#configuration-reference)
13. [Switching Regions](#switching-regions)
14. [SSL Certificate Renewal](#ssl-certificate-renewal)
15. [Backup and Restore](#backup-and-restore)
16. [Troubleshooting](#troubleshooting)
17. [File Reference](#file-reference)

---

## Architecture Overview

All services run as Docker containers on a shared internal network. Nothing except what is explicitly listed is exposed to the outside world.

```mermaid
graph TB
    subgraph EXTERNAL["External World"]
        GW_UDP["LoRa Gateway\n(Semtech UDP)"]
        GW_BS["LoRa Gateway\n(Basics Station)"]
        BROWSER["Web Browser\n/ API Client"]
        EXT_MQTT["External MQTT\nConsumer\n(optional)"]
    end

    subgraph HOST["Your Server / VPS"]
        subgraph NGINX["Nginx (ports 80 / 443 / 3001)"]
            PROXY["Reverse Proxy\n+ SSL Termination"]
        end

        subgraph DOCKER["Docker Network: chirpstack-net"]
            CS["ChirpStack Server\n:8080 UI + API"]
            GB_UDP["Gateway Bridge\nUDP  :1700"]
            GB_BS["Gateway Bridge\nBasics Station"]
            MQ["Mosquitto\nMQTT Broker  :1883"]
            PG["PostgreSQL\n:5432"]
            RD["Redis\n:6379"]

            subgraph MONITORING["Monitoring (optional)"]
                INF["InfluxDB"]
                GRF["Grafana\n:3000"]
            end
        end
    end

    GW_UDP -->|"UDP :1700"| GB_UDP
    GW_BS -->|"WSS :3001"| PROXY --> GB_BS
    BROWSER -->|"HTTP/S :80/443"| PROXY --> CS
    EXT_MQTT <-.->|"TCP :1883\noptional host exposure"| MQ

    GB_UDP -->|MQTT| MQ
    GB_BS  -->|MQTT| MQ
    MQ     -->|MQTT| CS

    CS --> PG
    CS --> RD
    CS -->|traffic metrics| INF
    PG -->|gateway state| GRF
    INF -->|traffic charts| GRF
    GRF --> PROXY
```

### Service roles

| Service | Image | Role |
|---|---|---|
| **chirpstack** | `chirpstack/chirpstack:4.17.0` | LoRaWAN Network + Application Server. Manages gateways, devices, tenants. Serves web UI and REST/gRPC APIs. |
| **gateway-bridge-udp** | `chirpstack/chirpstack-gateway-bridge:4.1.1` | Receives Semtech UDP packets from gateways and republishes them as Protobuf over MQTT. |
| **gateway-bridge-bs** | `chirpstack/chirpstack-gateway-bridge:4.1.1` | Same as above but speaks the Basics Station LNS WebSocket protocol. |
| **mosquitto** | `eclipse-mosquitto:2.0.22` | Internal MQTT v5 broker. All gateway-bridge to ChirpStack communication flows through it. Host access is optional. |
| **postgres** | `postgres:15.17-alpine` | Primary database. Stores all persistent state: devices, gateways, tenants, frame logs. |
| **redis** | `redis:7.4.8-alpine` | Session cache, downlink queue, deduplication, distributed locks. |
| **chirpstack-rest-api** | `ghcr.io/chirpstack/chirpstack-rest-api:4.2.0` | REST proxy for ChirpStack's gRPC API. Used by the provisioning script and proxied on `/api/`. |
| **nginx** | `nginx:1.29.8-alpine` | Reverse proxy. Terminates SSL, routes web UI, REST API, Grafana, and Basics Station WebSocket. |
| **influxdb** | `influxdb:2.8.0` | *(optional)* Time-series metrics database for gateway packet and device uplink traffic. |
| **grafana** | `grafana/grafana:13.0.1` | *(optional)* Visualization dashboards, pre-wired to PostgreSQL for gateway state and InfluxDB for traffic charts. |

---

## Data Flow: Sensor to Integration

This diagram traces a single uplink message from a sensor all the way to your integration endpoint.

```mermaid
sequenceDiagram
    participant Sensor as LoRa Sensor
    participant GW as LoRa Gateway
    participant Bridge as Gateway Bridge
    participant MQTT as Mosquitto (MQTT)
    participant CS as ChirpStack Server
    participant DB as PostgreSQL / Redis
    participant Int as Integration<br/>(MQTT / Webhook / InfluxDB)

    Sensor  ->> GW     : LoRa RF uplink (encrypted)
    GW      ->> Bridge : UDP packet / WebSocket frame
    Bridge  ->> MQTT   : Publish to<br/>{region}/gateway/{id}/event/up
    MQTT    ->> CS     : Deliver event
    CS      ->> DB     : Deduplicate, decrypt,<br/>validate MIC
    CS      ->> DB     : Store frame log
    CS      ->> Int    : Forward decoded payload<br/>(MQTT topic / HTTP POST / InfluxDB write)
    CS      ->> MQTT   : Publish downlink ack (if any)
    MQTT    ->> Bridge : Deliver downlink command
    Bridge  ->> GW     : Schedule TX window
    GW      ->> Sensor : LoRa RF downlink (RX1/RX2)
```

### MQTT topic structure

ChirpStack publishes application events to Mosquitto using this topic scheme:

```
application/{application_id}/device/{dev_eui}/event/{event_type}
```

| Event type | Trigger |
|---|---|
| `up` | Device uplink received and decoded |
| `join` | OTAA join accepted |
| `ack` | Confirmed downlink acknowledged |
| `txack` | Gateway transmitted a downlink |
| `log` | Error or warning from the device |
| `status` | Battery and margin status (DevStatusReq) |
| `location` | Geolocation result |

---

## Deployment Modes

```mermaid
flowchart LR
    subgraph VPS["VPS Mode (internet-facing)"]
        direction TB
        V1["Domain: cs.example.com"] --> V2["Let's Encrypt SSL"]
        V2 --> V3["HTTPS :443\nWebSocket wss://"]
        V3 --> V4["HTTP → HTTPS redirect"]
    end

    subgraph LOCAL["Local Mode (home / office)"]
        direction TB
        L1["No domain needed"] --> L2["Plain HTTP :80"]
        L2 --> L3["Access via LAN IP\nhttp://192.168.x.x"]
    end

    SETUP["./setup.sh"] --> VPS
    SETUP --> LOCAL
```

Both modes use **identical Docker services** — only the Nginx configuration and SSL certificate handling differ. Everything else (ChirpStack, databases, MQTT, gateway bridges) is the same.

---

## Port Map

```
┌─────────────────────────────────────────────────────────────────┐
│                          Host / Firewall                        │
│                                                                 │
│  :80  (TCP)  ── HTTP (web UI redirect or direct in local mode)  │
│  :443 (TCP)  ── HTTPS (VPS mode only)                           │
│  :1700 (UDP) ── LoRa Semtech UDP packet forwarder               │
│  :1883 (TCP) ── MQTT (optional external integrations)           │
│  :3001 (TCP) ── Basics Station WebSocket (ws:// or wss://)      │
│                                                                 │
│  ── NOT exposed externally ──────────────────────────────────── │
│  :5432 (TCP) ── PostgreSQL  (internal only)                     │
│  :6379 (TCP) ── Redis       (internal only)                     │
│  :8080 (TCP) ── ChirpStack UI + REST/gRPC API  (behind Nginx)   │
│  :3000 (TCP) ── Grafana  (behind Nginx at /grafana/)            │
│  :8086 (TCP) ── InfluxDB  (internal only)                       │
└─────────────────────────────────────────────────────────────────┘
```

> **Firewall rule summary** (UFW example):
> ```bash
> ufw allow 80/tcp
> ufw allow 443/tcp
> ufw allow 1700/udp
> ufw allow 3001/tcp
> ```
>
> Open `1883/tcp` only if you enabled optional MQTT host access during setup.

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Docker Engine | 24+ | [Install guide](https://docs.docker.com/engine/install/) |
| Docker Compose plugin | v2 | Comes with Docker Desktop; on Linux: `apt install docker-compose-plugin` |
| `openssl` | any | Pre-installed on macOS and most Linux distros |
| `envsubst` | any | Usually provided by `gettext-base` on Linux |
| A VPS or Linux machine | — | 1 GB RAM minimum; 2 GB recommended with monitoring |

The `setup.sh` script will check for Docker and exit with instructions if it is not found.

---

## Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/MachineSaver/chirpstack-deploy.git
cd chirpstack-deploy

# 2. Run the setup script
./setup.sh
```

The script will ask a short set of questions and handle everything else automatically.

---

## What `setup.sh` Does

```mermaid
flowchart TD
    A([Start setup.sh]) --> B[Check Docker\n+ openssl installed]
    B --> C{Deployment\ntype?}
    C -->|VPS| D[Prompt: domain name\n+ Let's Encrypt email]
    C -->|Local| E[Skip domain config]
    D --> F
    E --> F[Choose LoRa region\nfrom config/regions]
    F --> G[Enter admin email]
    G --> V{Expose MQTT\non host?}
    V -->|Yes| W[Include docker-compose.mqtt.yml\nwhen starting stack]
    V -->|No| X[Keep MQTT internal-only]
    W --> H{Enable Grafana\n+ InfluxDB?}
    X --> H
    H -->|Yes| I[Set ENABLE_MONITORING=true]
    H -->|No| J[Skip monitoring]
    I --> K
    J --> K[Generate all secrets\nvia openssl rand]
    K --> L[Write .env file]
    L --> M[Run generate-config.sh\nRender all templates]
    M --> N[Create Mosquitto\npassword file]
    N --> O{SSL enabled?}
    O -->|Yes| P[Start Nginx in HTTP mode\nRun Certbot ACME challenge\nSwitch to HTTPS config\nAdd renewal cron job]
    O -->|No| Q[Skip SSL]
    P --> R
    Q --> R[docker compose up -d\nwith monitoring if enabled]
    R --> S[Wait for ChirpStack\nhealth endpoint]
    S --> U[Set admin email + password\nvia chirpstack set-password CLI]
    U --> V[Create and persist a\nChirpStack API key]
    V --> W[Provision AirVibe device\nprofiles automatically]
    W --> T([Print summary:\nURL, credentials,\ngateway endpoints])
```

**The questions `setup.sh` asks:**

| # | Question | Options |
|---|---|---|
| 1 | Deployment type | VPS with domain / Local network |
| 2 | Domain name | *(VPS only)* e.g. `chirpstack.example.com` |
| 3 | Let's Encrypt email | *(VPS only)* for cert expiry notices |
| 4 | LoRa region | Discovered from `config/regions/` (`US915` or `EU868` by default) |
| 5 | Admin email address | your login for the web UI |
| 6 | Expose MQTT on the host? | Optional direct access for external MQTT clients |
| 7 | Enable monitoring? | Grafana + InfluxDB |

All passwords and secrets are **auto-generated** — you don't choose them. They are printed in the summary at the end and stored in `.env`.

`setup.sh` also generates a persistent `CHIRPSTACK_API_KEY` and stores it in `.env` so `scripts/provision-devices.sh` can rerun without creating a new credential each time.

If `.env` already exists, `setup.sh` exits without changing it unless you type `OVERWRITE`. When overwriting, the previous `.env` is backed up first.

---

## Adding Your First Gateway

After setup completes, open the ChirpStack web UI (URL is printed in the summary).

### Step 1 — Create a Gateway in ChirpStack

1. Log in with the admin credentials printed by `setup.sh`
2. Go to **Gateways → Add gateway**
3. Fill in:
   - **Name:** anything descriptive
   - **Gateway EUI:** the 8-byte EUI64 of your gateway (find it in your gateway's admin panel — format: `AA:BB:CC:DD:EE:FF:00:11`)
4. Click **Submit**

### Step 2 — Configure your gateway hardware

Point your gateway at the ChirpStack Gateway Bridge endpoint:

**Semtech UDP packet forwarder** (most common on budget/older gateways):
```
Server address: YOUR_SERVER_IP_OR_DOMAIN
Port (up):      1700
Port (down):    1700
```

**Basics Station / LNS** (Kerlink, RAK Wireless, Dragino newer models):
```
Authentication: LNS   (not CUPS)
LNS URI:        ws://YOUR_SERVER_IP:3001    (local mode)
                wss://YOUR_DOMAIN:3001       (VPS mode)
Server CA cert: (paste Let's Encrypt ISRG Root X1 PEM — VPS mode only)
Gateway cert:   (leave blank — no mutual TLS required)
Gateway key:    (leave blank)
```

> **Note:** The Basics Station bridge sends a `ROUTER_CONFIG` to the gateway on connect. This contains the channel plan from your selected region module, generated automatically from `LORA_REGION`. Setup also renders ChirpStack's per-region gateway MQTT topics, including `REGION/gateway/{{gateway_id}}/command/{{command}}` for join-accept and downlink commands. If your gateway hardware uses a different sub-band or non-standard channel plan, edit the matching `config/regions/<region-id>/basics-station-concentrators.toml` and `chirpstack.toml`, then re-run `bash scripts/generate-config.sh`.

### Step 3 — Verify connection

In the ChirpStack UI, navigate to your gateway. After the gateway connects, you should see:
- **Last seen:** a recent timestamp
- **Live LoRaWAN Frames** tab showing incoming packets

---

## Adding Your First Device

### Step 1 — Add AirVibe activation credentials

For AirVibe sensors, use the provisioning script instead of manually copying LoRaWAN keys through the UI. Add your activation portal credentials to `.env`:

```bash
AIRVIBE_API_LOGIN=your_activation_login
AIRVIBE_API_PASSWORD=your_activation_password
```

The script also uses the persistent `CHIRPSTACK_API_KEY` generated by `setup.sh`.

### Step 2 — Register an AirVibe sensor

Provision one sensor by DevEUI and access code:

```bash
scripts/provision-airvibe-sensors.sh \
  --dev-eui 8C1F642113000017 \
  --access-code 74475383
```

Or provision by serial number:

```bash
scripts/provision-airvibe-sensors.sh --serial 3000017
```

For batch onboarding, use a tab-separated file with this header:

```text
dev_eui	access_code	serial	name
8C1F642113000017	74475383		AirVibe Pump 1
		3000018	AirVibe Pump 2
```

Then run:

```bash
scripts/provision-airvibe-sensors.sh --file sensors.tsv
```

By default, the script creates or reuses the `AirVibe Sensors` application, uses the `AirVibe <REGION>` device profile, creates new devices, and leaves existing OTAA keys unchanged. Use `--dry-run` to preview writes and `--update-keys` only when you intentionally want to replace existing keys.

### Device Profiles

This repository pre-provisions the two AirVibe profiles during `setup.sh` for the selected region:

- `AirVibe <REGION>`
- `AirVibe <REGION> FUOTA`

If you re-run provisioning manually, the script is idempotent and will skip profiles that already exist.

### Step 3 — Power on the sensor

The sensor will send a Join Request. In the ChirpStack UI under your device → **Live LoRaWAN Frames** you should see:
1. `JoinRequest` from the device
2. `JoinAccept` sent back
3. Uplink frames appearing

---

## Integrations

### Internal MQTT (always on)

All device events are published to the internal Mosquitto broker automatically. Stack services can always reach it on the Docker network.

Direct host access is disabled by default. If you enabled MQTT host access during setup, connect external clients using the credentials printed at the end of `setup.sh`.

```
Broker:    YOUR_SERVER:1883
Username:  chirpstack
Password:  (printed in setup summary, also in .env)
Topic:     application/+/device/+/event/+
```

To enable host access after setup, set `EXPOSE_MQTT=true` in `.env` and include the optional Compose file when starting the stack:

```bash
docker compose -f docker-compose.yml -f docker-compose.mqtt.yml up -d
```

### HTTP Webhooks

Configured per-application in the web UI — no config file changes needed.

1. Open your application in the UI
2. Go to the **Integrations** tab
3. Add **HTTP integration**
4. Enter your endpoint URL
5. ChirpStack will POST JSON payloads on every device event

### External MQTT Forwarding

To forward device data to an external MQTT broker, add the broker URI to `.env` and re-generate configs:

```bash
# Edit .env
EXTERNAL_MQTT_SERVER=mqtt://user:pass@broker.example.com:1883

# Re-generate and restart
bash scripts/generate-config.sh
docker compose restart chirpstack
```

### InfluxDB (via monitoring stack)

When monitoring is enabled, ChirpStack writes gateway packet and device uplink traffic metrics directly to InfluxDB. Gateway online and last-seen state comes from ChirpStack's PostgreSQL `gateway` table, using the same `last_seen_at` and `stats_interval_secs` logic as ChirpStack itself.

---

## Monitoring (Grafana + InfluxDB)

If you chose to enable monitoring during setup, Grafana is available at:

```
http(s)://YOUR_DOMAIN/grafana/
```

Login with:
- **Username:** `admin`
- **Password:** same as your ChirpStack admin password (printed in setup summary)

A pre-built **ChirpStack Overview** dashboard is auto-provisioned showing:
- Gateway online/offline/never-seen counts from PostgreSQL
- Gateway last-seen table from PostgreSQL
- Gateway RX packets over time
- Device uplinks over time

```mermaid
flowchart LR
    CS["ChirpStack\nServer"] -->|"State"| PG["PostgreSQL"]
    CS -->|"InfluxDB\nLine Protocol"| IDB["InfluxDB"]
    PG -->|"SQL queries"| GRF["Grafana"]
    IDB -->|"Flux queries"| GRF
    GRF -->|"/grafana/ (via Nginx)"| USER["Browser"]
```

To add your own dashboards, place JSON files in:
```
config/grafana/provisioning/dashboard-files/
```
They will be auto-loaded within 30 seconds.

---

## Configuration Reference

All configuration lives in `.env`. After changing any value, run:

```bash
bash scripts/generate-config.sh
docker compose up -d --force-recreate chirpstack
```

| Variable | Default | Description |
|---|---|---|
| `DEPLOY_MODE` | `local` | `vps` enables SSL; `local` uses plain HTTP |
| `DOMAIN` | *(blank)* | Domain name for VPS mode |
| `SSL_ENABLED` | `false` | Set automatically by setup.sh |
| `LORA_REGION` | `US915` | Region selector. `US915` and `EU868` are included; values map to `config/regions/<region-id>/`. |
| `POSTGRES_PASSWORD` | *(generated)* | PostgreSQL password |
| `REDIS_PASSWORD` | *(generated)* | Redis password |
| `MOSQUITTO_PASSWORD` | *(generated)* | Internal MQTT password |
| `CHIRPSTACK_SECRET` | *(generated)* | JWT signing secret |
| `CHIRPSTACK_ADMIN_EMAIL` | *(your input)* | Initial admin login |
| `CHIRPSTACK_ADMIN_PASSWORD` | *(generated)* | Initial admin password |
| `CHIRPSTACK_API_KEY` | *(generated)* | Persistent API key used by provisioning scripts |
| `AIRVIBE_API_LOGIN` | *(blank)* | AirVibe activation API login for sensor auto-provisioning |
| `AIRVIBE_API_PASSWORD` | *(blank)* | AirVibe activation API password for sensor auto-provisioning |
| `EXTERNAL_MQTT_SERVER` | *(blank)* | External broker URI (optional) |
| `EXPOSE_MQTT` | `false` | Publish Mosquitto on host port `MQTT_PORT` |
| `ENABLE_MONITORING` | `false` | Enables Grafana + InfluxDB |
| `GRAFANA_ROOT_URL` | `http://localhost/grafana/` | Public Grafana URL used for redirects |
| `INFLUXDB_TOKEN` | *(generated)* | InfluxDB API token |
| `HTTP_PORT` | `80` | Override if port 80 is in use |
| `HTTPS_PORT` | `443` | Override if port 443 is in use |
| `MQTT_PORT` | `1883` | Optional host MQTT port when `EXPOSE_MQTT=true` |
| `GATEWAY_UDP_PORT` | `1700` | Semtech UDP gateway port |
| `GATEWAY_BS_PORT` | `3001` | Basics Station WebSocket port |

---

## Switching Regions

To change from US915 to EU868 (or vice versa):

```bash
# Edit .env — change LORA_REGION=EU868
nano .env

# Re-generate and restart
bash scripts/generate-config.sh
docker compose restart chirpstack
```

> **Note:** Changing region will affect all existing gateways and devices. Reconfigure your gateway hardware to use the new region frequency plan.

Region modules are in `config/regions/<region-id>/`. Each module contains:

- `metadata.env` - setup menu labels and Basics Station frequency bounds
- `chirpstack.toml` - the ChirpStack `[[regions]]` block
- `basics-station-concentrators.toml` - the Basics Station channel plan sent in `ROUTER_CONFIG`

To customize a channel plan, edit the files inside the matching module and run `bash scripts/validate.sh`. Validation discovers every module automatically.

---

## SSL Certificate Renewal

Certificates from Let's Encrypt expire after 90 days. The `setup.sh` script automatically adds a daily cron job:

```
0 3 * * * /path/to/chirpstack-deploy/scripts/renew-ssl.sh
```

To renew manually:

```bash
bash scripts/renew-ssl.sh
```

To verify the cron job is set:

```bash
crontab -l | grep renew-ssl
```

---

## Backup and Restore

Create a backup before upgrades, host migration, or risky configuration changes:

```bash
bash scripts/backup.sh
```

By default, backups are written to `backups/chirpstack-backup-YYYYMMDDTHHMMSSZ.tar.gz`. To write somewhere else:

```bash
bash scripts/backup.sh /secure/backup/path
```

Each archive includes `.env`, generated runtime config, a PostgreSQL logical dump, and snapshots of Redis, Mosquitto, Certbot, and optional monitoring volumes.

Restore is destructive to the current deployment state and requires an explicit confirmation prompt:

```bash
bash scripts/restore.sh backups/chirpstack-backup-YYYYMMDDTHHMMSSZ.tar.gz
```

Restore stops the stack, replaces `.env` and `generated/`, recreates the PostgreSQL volume from the dump, restores archived Docker volumes, regenerates config, and starts the stack with the restored settings.

Recommended upgrade flow:

```bash
bash scripts/backup.sh
docker compose pull
docker compose up -d
```

If the upgrade fails, restore the backup archive created before pulling new images.

---

## Troubleshooting

### ChirpStack won't start

```bash
docker compose logs chirpstack
```

Common causes:
- PostgreSQL not yet ready — wait 30 seconds and try again
- `chirpstack.toml` missing or malformed — re-run `bash scripts/generate-config.sh`

### Gateway shows "never seen" in the UI

**For Semtech UDP gateways:**
1. Confirm firewall allows UDP 1700: `ufw allow 1700/udp`
2. Verify the gateway points at the correct server IP and port 1700
3. Check bridge logs: `docker compose logs gateway-bridge-udp`

**For Basics Station gateways:**
1. Set Authentication to **LNS** (not CUPS — ChirpStack does not implement CUPS)
2. The LNS URI must use `wss://` (not `https://`) and include the port: `wss://YOUR_DOMAIN:3001`
3. If using a VPS with Let's Encrypt, paste the **ISRG Root X1** CA certificate into the Server CA cert field
4. Confirm firewall allows TCP 3001: `ufw allow 3001/tcp`
5. Check bridge logs — a healthy connection looks like this:
   ```
   backend/basicstation: gateway connected gateway_id=...
   backend/basicstation: gateway version received ...
   backend/basicstation: router-config message sent to gateway
   integration/mqtt: publishing event event=stats ...
   ```
   If `gateway disconnected` appears immediately after `router-config message sent`, the gateway rejected the channel plan — verify `LORA_REGION` in `.env` matches your gateway's hardware region.
6. If logs show no connections at all, check the URI — it should be `wss://DOMAIN:3001`, not `https://`.

**In both cases:**
- Verify the gateway EUI in ChirpStack matches the hardware exactly (no colons, lowercase)
- Check `docker compose logs chirpstack` for MQTT errors — if ChirpStack shows repeated MQTT connection failures, re-run `bash scripts/generate-config.sh` and restart: `docker compose restart chirpstack`

### Devices not joining (OTAA)

1. Confirm the **AppKey** in ChirpStack matches the device exactly
2. Check the **Device Profile** LoRaWAN version matches the device firmware
3. Check **Live LoRaWAN Frames** on the gateway — if frames appear there but not on the device page, the DevEUI may be wrong
4. If ChirpStack publishes joins but the gateway bridge logs `unexpected command received` on a topic ending in `/command/`, re-run `bash scripts/generate-config.sh` and restart ChirpStack. The rendered region config must use `command/{{command}}`, not an empty command suffix.

### MQTT connection refused

```bash
docker compose logs mosquitto
```

- Confirm `EXPOSE_MQTT=true` in `.env`
- Confirm the stack was started with `-f docker-compose.mqtt.yml`
- Confirm username/password from `.env` (field `MOSQUITTO_USER` / `MOSQUITTO_PASSWORD`)
- Test with: `mosquitto_sub -h YOUR_HOST -p 1883 -u chirpstack -P YOUR_PASSWORD -t '#'`

### Grafana shows "No data"

- InfluxDB takes ~30 seconds to initialise on first run
- Confirm ChirpStack is sending metrics: check `docker compose logs chirpstack` for InfluxDB write errors
- Verify the datasource is green: Grafana → Connections → Data sources → InfluxDB → Test

### Full stack reset (WARNING: deletes all data)

```bash
docker compose down -v   # removes volumes — all device/gateway data lost
./setup.sh               # start fresh
```

---

## File Reference

```
chirpstack-deploy/
├── setup.sh                              ← Run this to deploy
├── docker-compose.yml                    ← Core services
├── docker-compose.mqtt.yml               ← MQTT host port exposure (optional)
├── docker-compose.monitoring.yml         ← Grafana + InfluxDB (optional)
├── .env                                  ← Your secrets (git-ignored, generated by setup.sh)
├── .env.example                          ← Template with documentation
├── .gitignore
│
├── config/                               ← Source templates and static config (tracked in git)
│   ├── chirpstack/
│   │   └── chirpstack.toml.tmpl          ← ChirpStack config template
│   │
│   ├── regions/
│   │   ├── us915/
│   │   │   ├── metadata.env              ← Setup labels + Basics Station bounds
│   │   │   ├── chirpstack.toml           ← US915 region parameters
│   │   │   └── basics-station-concentrators.toml
│   │   └── eu868/
│   │       ├── metadata.env              ← Setup labels + Basics Station bounds
│   │       ├── chirpstack.toml           ← EU868 region parameters
│   │       └── basics-station-concentrators.toml
│   │
│   ├── gateway-bridge/
│   │   ├── udp.toml                      ← Semtech UDP bridge config (static)
│   │   └── bs.toml.tmpl                  ← Basics Station bridge config template
│   │
│   ├── mosquitto/
│   │   └── mosquitto.conf                ← MQTT broker config (static)
│   │
│   ├── nginx/
│   │   ├── http.conf.tmpl                ← Nginx template for HTTP mode
│   │   └── https.conf.tmpl               ← Nginx template for HTTPS mode
│   │
│   └── grafana/
│       └── provisioning/
│           ├── datasources/
│           │   ├── influxdb.yml.tmpl     ← Template for Grafana InfluxDB datasource
│           │   └── postgres.yml.tmpl     ← Template for Grafana PostgreSQL datasource
│           ├── dashboards/
│           │   └── dashboards.yml        ← Tells Grafana where to find dashboards
│           └── dashboard-files/
│               └── chirpstack-overview.json ← Pre-built LoRaWAN dashboard
│
├── generated/                            ← Runtime output (git-ignored, created by setup.sh)
│   ├── chirpstack/
│   │   ├── chirpstack.toml               ← Rendered ChirpStack config
│   │   └── region.toml                   ← Active region config with MQTT backend injected
│   ├── gateway-bridge/
│   │   └── bs.toml                       ← Rendered Basics Station bridge config
│   ├── mosquitto/
│   │   └── passwd                        ← Mosquitto password file
│   ├── nginx/
│   │   └── nginx.conf                    ← Rendered Nginx config (HTTP or HTTPS)
│   └── grafana/
│       └── provisioning/
│           └── datasources/
│               ├── influxdb.yml          ← Rendered Grafana InfluxDB datasource config
│               └── postgres.yml          ← Rendered Grafana PostgreSQL datasource config
│
└── scripts/
    ├── backup.sh                         ← Creates deployment backup archives
    ├── generate-config.sh                ← Renders templates using .env values
    ├── postgres-init.sql                 ← Enables pg_trgm on first DB start
    ├── renew-ssl.sh                      ← Certbot renewal + Nginx reload
    └── restore.sh                        ← Restores backup archives
```

---

## Common `docker compose` Commands

```bash
# View all running services
docker compose ps

# Follow logs for all services
docker compose logs -f

# Follow logs for one service
docker compose logs -f chirpstack

# Restart a single service
docker compose restart chirpstack

# Stop everything (keeps data)
docker compose down

# Stop and remove all data volumes (destructive)
docker compose down -v

# Pull latest images
docker compose pull

# Apply image updates
docker compose up -d
```

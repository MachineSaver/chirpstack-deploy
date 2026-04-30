# ChirpStack v4 — Repeatable Docker Compose Deployment

A self-contained, production-ready deployment of [ChirpStack v4](https://www.chirpstack.io/) — the open-source LoRaWAN Network Server. Run `./setup.sh` and answer six questions. That's it.

**Supports:**
- VPS with a domain name (HTTPS via Let's Encrypt)
- Local network / home lab (plain HTTP, no domain needed)
- US915 (Americas) and EU868 (Europe) frequency regions
- Semtech UDP and Basics Station gateway protocols
- Optional Grafana + InfluxDB monitoring stack

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
15. [Troubleshooting](#troubleshooting)
16. [File Reference](#file-reference)

---

## Architecture Overview

All services run as Docker containers on a shared internal network. Nothing except what is explicitly listed is exposed to the outside world.

```mermaid
graph TB
    subgraph EXTERNAL["External World"]
        GW_UDP["LoRa Gateway\n(Semtech UDP)"]
        GW_BS["LoRa Gateway\n(Basics Station)"]
        BROWSER["Web Browser\n/ API Client"]
        EXT_MQTT["External MQTT\nConsumer"]
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
    EXT_MQTT <-->|"TCP :1883"| MQ

    GB_UDP -->|MQTT| MQ
    GB_BS  -->|MQTT| MQ
    MQ     -->|MQTT| CS

    CS --> PG
    CS --> RD
    CS -->|metrics| INF
    INF --> GRF
    GRF --> PROXY
```

### Service roles

| Service | Image | Role |
|---|---|---|
| **chirpstack** | `chirpstack/chirpstack:4` | LoRaWAN Network + Application Server. Manages gateways, devices, tenants. Serves web UI and REST/gRPC APIs. |
| **gateway-bridge-udp** | `chirpstack/chirpstack-gateway-bridge:4` | Receives Semtech UDP packets from gateways and republishes them as Protobuf over MQTT. |
| **gateway-bridge-bs** | `chirpstack/chirpstack-gateway-bridge:4` | Same as above but speaks the Basics Station LNS WebSocket protocol. |
| **mosquitto** | `eclipse-mosquitto:2` | Internal MQTT v5 broker. All gateway-bridge → ChirpStack communication flows through it. |
| **postgres** | `postgres:15` | Primary database. Stores all persistent state: devices, gateways, tenants, frame logs. |
| **redis** | `redis:7` | Session cache, downlink queue, deduplication, distributed locks. |
| **nginx** | `nginx:1.25` | Reverse proxy. Terminates SSL, routes web UI, REST API, Grafana, and Basics Station WebSocket. |
| **influxdb** | `influxdb:2` | *(optional)* Time-series metrics database for device/gateway statistics. |
| **grafana** | `grafana/grafana` | *(optional)* Visualization dashboards, pre-wired to InfluxDB. |

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
    Bridge  ->> MQTT   : Publish to<br/>us915/gateway/{id}/event/up
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
│  :1883 (TCP) ── MQTT (gateways, external integrations)          │
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
> ufw allow 1883/tcp
> ufw allow 3001/tcp
> ```

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Docker Engine | 24+ | [Install guide](https://docs.docker.com/engine/install/) |
| Docker Compose plugin | v2 | Comes with Docker Desktop; on Linux: `apt install docker-compose-plugin` |
| `openssl` | any | Pre-installed on macOS and most Linux distros |
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

The script will ask you six questions and handle everything else automatically.

---

## What `setup.sh` Does

```mermaid
flowchart TD
    A([Start setup.sh]) --> B[Check Docker\n+ openssl installed]
    B --> C{Deployment\ntype?}
    C -->|VPS| D[Prompt: domain name\n+ Let's Encrypt email]
    C -->|Local| E[Skip domain config]
    D --> F
    E --> F[Choose LoRa region\nUS915 or EU868]
    F --> G[Enter admin email]
    G --> H{Enable Grafana\n+ InfluxDB?}
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
    U --> T([Print summary:\nURL, credentials,\ngateway endpoints])
```

**The six questions `setup.sh` asks:**

| # | Question | Options |
|---|---|---|
| 1 | Deployment type | VPS with domain / Local network |
| 2 | Domain name | *(VPS only)* e.g. `chirpstack.example.com` |
| 3 | Let's Encrypt email | *(VPS only)* for cert expiry notices |
| 4 | LoRa region | US915 (Americas) / EU868 (Europe) |
| 5 | Admin email address | your login for the web UI |
| 6 | Enable monitoring? | Grafana + InfluxDB |

All passwords and secrets are **auto-generated** — you don't choose them. They are printed in the summary at the end and stored in `.env`.

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

> **Note:** The Basics Station bridge sends a `ROUTER_CONFIG` to the gateway on connect. This contains the channel plan for your region (US915 sub-band 2 or EU868 standard plan), generated automatically from your `LORA_REGION` setting. If your gateway hardware uses a different sub-band or non-standard channel plan, edit `config/gateway-bridge/bs.toml.tmpl` and re-run `bash scripts/generate-config.sh`.

### Step 3 — Verify connection

In the ChirpStack UI, navigate to your gateway. After the gateway connects, you should see:
- **Last seen:** a recent timestamp
- **Live LoRaWAN Frames** tab showing incoming packets

---

## Adding Your First Device

### Step 1 — Create a Device Profile

A Device Profile defines the LoRaWAN version and regional parameters for a class of device.

1. Go to **Device Profiles → Add device profile**
2. Key settings:
   - **Name:** e.g. `OTAA-1.0.4-ClassA`
   - **LoRaWAN MAC version:** match your sensor spec (usually 1.0.4 or 1.1.0)
   - **Regional parameters revision:** match your sensor (RP002-1.0.3 is common)
   - **ADR algorithm:** Default (recommended)
3. On the **Join (OTAA / ABP)** tab, set **Supports OTAA** to enabled

### Step 2 — Create an Application

Applications group devices together and define integration endpoints.

1. Go to **Applications → Add application**
2. Give it a name (e.g. `My Sensors`)

### Step 3 — Register a Device

1. Inside your application, go to **Devices → Add device**
2. Fill in:
   - **Name:** descriptive label
   - **Device EUI:** the 8-byte EUI from your sensor's label or config
   - **Device Profile:** select the one you created
3. On the **OTAA keys** tab, enter the **Application Key** (AppKey) from your sensor

### Step 4 — Power on the sensor

The sensor will send a Join Request. In the ChirpStack UI under your device → **Live LoRaWAN Frames** you should see:
1. `JoinRequest` from the device
2. `JoinAccept` sent back
3. Uplink frames appearing

---

## Integrations

### Internal MQTT (always on)

All device events are published to the internal Mosquitto broker automatically. Connect any MQTT client using the credentials printed at the end of `setup.sh`.

```
Broker:    YOUR_SERVER:1883
Username:  chirpstack
Password:  (printed in setup summary, also in .env)
Topic:     application/+/device/+/event/+
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

When monitoring is enabled, ChirpStack writes gateway and device metrics directly to InfluxDB. No additional configuration is needed — it is wired up automatically during setup.

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
- Gateways online
- Gateway RX packets over time
- Device uplinks over time

```mermaid
flowchart LR
    CS["ChirpStack\nServer"] -->|"InfluxDB\nLine Protocol"| IDB["InfluxDB"]
    IDB -->|"Flux queries"| GRF["Grafana"]
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
| `LORA_REGION` | `US915` | `US915` or `EU868` |
| `POSTGRES_PASSWORD` | *(generated)* | PostgreSQL password |
| `REDIS_PASSWORD` | *(generated)* | Redis password |
| `MOSQUITTO_PASSWORD` | *(generated)* | Internal MQTT password |
| `CHIRPSTACK_SECRET` | *(generated)* | JWT signing secret |
| `CHIRPSTACK_ADMIN_EMAIL` | *(your input)* | Initial admin login |
| `CHIRPSTACK_ADMIN_PASSWORD` | *(generated)* | Initial admin password |
| `EXTERNAL_MQTT_SERVER` | *(blank)* | External broker URI (optional) |
| `ENABLE_MONITORING` | `false` | Enables Grafana + InfluxDB |
| `INFLUXDB_TOKEN` | *(generated)* | InfluxDB API token |
| `HTTP_PORT` | `80` | Override if port 80 is in use |
| `HTTPS_PORT` | `443` | Override if port 443 is in use |
| `MQTT_PORT` | `1883` | External MQTT port |
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

Region config files are in `config/chirpstack/regions/`. They can be edited to customise channel plans (e.g., US915 sub-band selection).

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

### MQTT connection refused

```bash
docker compose logs mosquitto
```

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
├── docker-compose.monitoring.yml         ← Grafana + InfluxDB (optional)
├── .env                                  ← Your secrets (git-ignored, generated by setup.sh)
├── .env.example                          ← Template with documentation
├── .gitignore
│
├── config/
│   ├── chirpstack/
│   │   ├── chirpstack.toml.tmpl          ← ChirpStack config template
│   │   ├── chirpstack.toml               ← Generated — do not edit manually
│   │   ├── region.toml                   ← Generated — active region config
│   │   └── regions/
│   │       ├── us915.toml                ← US915 region parameters
│   │       └── eu868.toml                ← EU868 region parameters
│   │
│   ├── gateway-bridge/
│   │   ├── udp.toml                      ← Semtech UDP bridge config
│   │   ├── bs.toml.tmpl                  ← Basics Station bridge config template
│   │   └── bs.toml                       ← Generated — do not edit manually
│   │
│   ├── mosquitto/
│   │   ├── mosquitto.conf                ← MQTT broker config
│   │   └── passwd                        ← Generated by setup.sh (git-ignored)
│   │
│   ├── nginx/
│   │   ├── http.conf.tmpl                ← Nginx template for HTTP mode
│   │   ├── https.conf.tmpl               ← Nginx template for HTTPS mode
│   │   └── nginx.conf                    ← Generated — do not edit manually
│   │
│   └── grafana/
│       └── provisioning/
│           ├── datasources/
│           │   ├── influxdb.yml.tmpl     ← Template for Grafana InfluxDB datasource
│           │   └── influxdb.yml          ← Generated — do not edit manually
│           ├── dashboards/
│           │   └── dashboards.yml        ← Tells Grafana where to find dashboards
│           └── dashboard-files/
│               └── chirpstack-overview.json ← Pre-built LoRaWAN dashboard
│
└── scripts/
    ├── generate-config.sh                ← Renders templates using .env values
    ├── postgres-init.sql                 ← Enables pg_trgm on first DB start
    └── renew-ssl.sh                      ← Certbot renewal + Nginx reload
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

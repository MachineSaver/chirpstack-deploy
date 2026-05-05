# Cloudgate Fleet Statistics Research

This note captures research on information that can be collected automatically
from Cloudgate Mini and Cloudgate Secure gateways running LoRa Basics Station.
It is intended to guide future Grafana, InfluxDB, and collector work while
keeping gateway provisioning, telemetry collection, storage, and dashboard
concerns separated.

## Goals

- Monitor a fleet of Cloudgate gateways without turning provisioning scripts
  into recurring telemetry jobs.
- Collect gateway-device truth alongside ChirpStack network-server truth.
- Preserve enough inventory information to diagnose firmware, image, modem,
  SIM, VPN, Basic Station, and GPS differences across deployed gateways.
- Keep sensitive material out of dashboards, logs, and generated metrics.

## Sources Reviewed

- Live Cloudgate reachable over VPN at `10.11.0.243`, using read-only SSH
  probes as the `admin` user.
- The existing repository Cloudgate provisioning workflow in
  `scripts/provision-cloudgate-gateway.sh`.
- Public Cloudgate Mini and Cloudgate Secure product information.
- Public Cloudgate user-interface and gateway documentation describing system
  information, mobile network status, SIM, data counters, VPN, remote access,
  logging, provisioning, timed reset, and connection persistence features.
- The Things Stack Cloudgate Basics Station setup documentation, which confirms
  LoRa card requirements, Basics Station firmware expectations, LTE/Ethernet
  setup, GPS/diversity antenna notes, and gateway EUI derivation from the MAC
  address plus `fffe`.

## Live Gateway Findings

The live gateway is an older OpenWrt-based Cloudgate:

- Kernel: Linux `2.6.35.3`.
- Distribution: OpenWrt Backfire `10.03`.
- Available read-only tools include `uci`, `logread`, `ip`, `ifconfig`, `free`,
  `df`, `uptime`, `top`, and `opkg`.
- Newer OpenWrt or modem-management tools such as `ubus`, `mmcli`, `qmicli`,
  `gpsd`, `gpspipe`, `gsmctl`, and `iwinfo` were not present.
- `mcmd` and `mcmdplus` exist, but direct use by the `admin` SSH user is
  restricted. Full modem radio details may require root, an authenticated web
  API session, or a local gateway-side helper.

Confirmed live identity and configuration fields:

| Field | Example | Source |
|---|---|---|
| Serial number | `KW4AN69762` | `m2m_printenv -n serial_nbr` |
| Hardware revision | `4.4.0.0` | `m2m_printenv -n hw_rev` |
| MAC address | `00:0C:E3:75:ED:12` | `m2m_printenv -n mac_addr` |
| Gateway EUI | `000CE3FFFE75ED12` | `cg_conf_basicstation.general.routerid` and `/etc/station/routerid` |
| Configuration version | `58` | `/etc/cfg_version` and `system.version.conf_version` |
| OpenWrt version | `10.03` | `/etc/openwrt_version` and `/etc/openwrt_release` |
| Basics Station LNS URI | `wss://chirpstack.machinesaver.com:3001` | `cg_conf_basicstation.general.uri` and `/etc/station/tc.uri` |
| Basics Station region code | `915` | `cg_conf_basicstation.general.region` |
| Basics Station binary version | `Station: 2.0.6 2025-10-10 17:07:33` | `strings /rom/mnt/cust/usr/sbin/station` |

Confirmed live runtime fields:

| Category | Fields | Source |
|---|---|---|
| Uptime/load | uptime, 1/5/15 minute load average | `uptime`, `/proc/loadavg` |
| Memory | total, free, buffers, cached, swap | `free`, `/proc/meminfo` |
| Filesystems | mount size, used, available, percent used | `df -h` |
| Interfaces | state, addresses, MTU, RX/TX counters, errors, drops | `ip addr`, `/proc/net/dev` |
| Cellular session | `wwan0` IP, default route, gateway, bytes, packets | `ip addr`, `route -n`, `/proc/net/dev` |
| VPN | `tun0` IP, OpenVPN process, tunnel counters | `ip addr`, `ps`, `/proc/net/dev` |
| Basic Station | process state, station config, LNS URI, router ID | `ps`, UCI, `/etc/station/*` |
| LoRa RF activity | per-uplink frequency, DR/SF/BW, RSSI, SNR | `/log/messages` station lines |
| Time/concentrator health | time sync quality, MCU/SX130X drift | `/log/messages` station lines |

Observed live interfaces included `eth0`, `eth3`, `wwan0`, and `tun0`. The
active cellular interface was `wwan0`; the VPN interface was `tun0`.

## Cloudgate Web UI API Surface

The live gateway's local web UI serves an Angular application. Its JavaScript
references several HTTP API endpoints that are promising for structured
collector work:

| Endpoint | Likely value |
|---|---|
| `/api/system_info` | firmware, image, serial, uptime, hardware, version fields |
| `/api/modem` | modem model, connection state, cellular details |
| `/api/sim` | SIM PIN/state, SIM information, potentially ICCID/operator |
| `/api/internetConnection` | current WAN connection and route state |
| `/api/events` and `/api/events?full=1` | event/log stream for fleet diagnostics |
| `/api/diagnostics?device=usb0` | interface-specific diagnostics |
| `/api/provisioning` | provisioning mode and server information |
| `/api/connpersist` | connection persistence/watchdog configuration |
| `/api/timedreset` | scheduled reset/watchdog configuration |
| `/api/connectionrecovery` | recovery behavior |
| `/api/logging` | logging configuration |
| `/api/configexport` | configuration export support |
| `/api/vpn` | VPN tunnel configuration and status |

Unauthenticated local requests over SSH to these endpoints returned no useful
payload, so a collector should implement the same login/session flow used by
the UI instead of scraping HTML. The UI posts JSON credentials to `/api/login`
and then uses the authenticated session for subsequent API calls.

## Public Documentation Findings

Cloudgate documentation and product pages indicate these dashboard-relevant
areas are available in the platform:

- Home and system information, including serial number, firmware version, image
  version, configuration version, and interface summaries.
- LTE/3G mobile network status, including connection state, operator, SIM
  details, signal quality, APN-related configuration, and diagnostics.
- Data counters for WAN/LAN interfaces.
- VPN and remote-access status.
- Connection persistence, timed reset, recovery, and watchdog controls.
- Logging and event access.
- Local and remote provisioning, including firmware, configuration, and
  application packages.
- Cloudgate Mini product capabilities including LTE, Ethernet, serial
  interfaces, CAN, GPIO, optional WiFi, optional LoRaWAN, secure VPN remote
  access, SIM connection, and passive/active GPS support.
- Cloudgate Secure product capabilities including LTE Cat 4, multiregion LoRa,
  Ethernet/cellular connectivity, hardware-backed security, and compatibility
  with packet forwarder workflows including Basics Station.

## Useful Fleet Metrics

Recommended metrics and dimensions for Grafana:

| Metric group | Fields | Collection priority |
|---|---|---:|
| Inventory | serial, gateway EUI, MAC, hardware revision, model, firmware version, image version, config version, Basic Station version | High |
| ChirpStack state | registered gateway name, tenant, last seen, stats interval, online/offline/never seen | High |
| Basic Station state | process up, LNS URI, router ID, region, auth mode, trust file present, reconnect count, recent error count | High |
| Cellular session | connected, WAN interface, SIM IP, default gateway, APN, operator, SIM provider, ICCID, IMEI, IMSI if policy allows | High |
| Cellular RF | RSRP, RSRQ, RSSI, SINR, registration state, roaming state, access technology | High |
| VPN | tunnel up, tunnel IP, bytes, packets, reconnect count, last log status | High |
| System resources | uptime, load, memory used/free, overlay/data filesystem used, process count | High |
| Interface counters | RX/TX bytes, packets, errors, drops per interface | High |
| GPS | GPS enabled, fix state, latitude, longitude, altitude, accuracy, satellites, last fix age | Medium |
| LoRa RF | packet RSSI/SNR distribution, uplink counts, time sync quality, concentrator drift | Medium |
| Watchdogs/recovery | connection persistence enabled, timed reset enabled, recovery settings, reboot count | Medium |
| Events/logs | recent critical events, Basic Station disconnects, modem drops, VPN failures | Medium |
| Security posture | SSH reachable, web UI reachable, remote access enabled, certificate/trust state | Medium |

Treat IMSI, ICCID, certificates, private keys, API tokens, and passwords as
sensitive. These should be redacted by default and only stored if there is a
clear operational policy for handling them.

## Collection Methods

### SSH Pull Collector

This is the fastest practical path because it works with the live gateway today.
It can collect system resources, network state, VPN state, Basic Station
configuration, Basic Station process state, and log-derived LoRa RF statistics.

Useful commands:

```sh
m2m_printenv -n serial_nbr
m2m_printenv -n hw_rev
m2m_printenv -n mac_addr
cat /etc/cfg_version
cat /etc/openwrt_release
uci show cg_conf_basicstation
cat /etc/station/routerid
cat /etc/station/tc.uri
uptime
free
df -h
cat /proc/loadavg
cat /proc/meminfo
cat /proc/net/dev
ip addr show
route -n
ps
grep -iE 'station|basic|lns|router|websocket|gps|wwan|lte|sim|rsrp|rsrq|rssi|openvpn|tun0' /log/messages
```

Advantages:

- Works against the current firmware generation.
- Requires no gateway-side install.
- Easy to prototype in `scripts/`.

Limitations:

- SSH fan-out needs careful timeout and concurrency handling.
- Password SSH should be replaced by key-based SSH for production.
- Full cellular RF and GPS details may require root or authenticated web API
  access.

### Authenticated Web API Collector

The Cloudgate web UI appears to use structured local HTTP APIs. This is likely
the best path for clean firmware, image, modem, SIM, GPS, and event fields once
login/session handling is implemented.

Advantages:

- Better structured data than parsing shell output.
- Likely exposes modem and SIM information that is restricted from the
  unprivileged SSH shell.
- Maps closely to fields operators already see in the Cloudgate web UI.

Limitations:

- Requires secure credential/session handling.
- API schema may vary across firmware and image versions.
- The web UI may be bound or firewalled differently in production.

### Gateway-Side Agent

A lightweight agent installed on each Cloudgate could publish normalized JSON to
Mosquitto over VPN or cellular backhaul. The server side can ingest the MQTT
messages into InfluxDB.

Advantages:

- Avoids central SSH fan-out.
- Can run locally with the required privileges.
- Better when gateways are behind NAT or intermittently reachable inbound.
- Good fit for GPS and modem signal metrics.

Limitations:

- Requires packaging, installation, upgrade, and rollback discipline.
- Must coexist with Cloudgate Universe or local provisioning behavior.
- More moving parts than a pull collector.

### Cloudgate Universe

Cloudgate Universe can help with firmware, image, application, and configuration
fleet management. It is useful for inventory and drift reporting if an API or
export path is available.

Advantages:

- Aligns with vendor-supported fleet management.
- Good for firmware/image/configuration compliance.

Limitations:

- Operational telemetry may not be as direct or near real-time as local
  collection.
- Repository automation should not depend on a proprietary external service
  unless credentials, API access, and export behavior are clearly documented.

### ChirpStack Data

ChirpStack remains the authoritative source for LoRaWAN network-server state:
registered gateway identity, `last_seen_at`, stats interval, and LoRaWAN packet
flow. It should be used alongside Cloudgate telemetry, not replaced by it.

## Storage Model

Use InfluxDB for changing time-series telemetry:

- `cloudgate_system`
- `cloudgate_network_interface`
- `cloudgate_cellular`
- `cloudgate_vpn`
- `cloudgate_basicstation`
- `cloudgate_lora_rf`
- `cloudgate_gps`
- `cloudgate_events`

Use ChirpStack/PostgreSQL or ChirpStack gateway metadata for slower-changing
inventory:

- serial number
- hardware revision
- model
- firmware version
- image version
- Basic Station version
- installed region/profile

Do not write runtime polling logic into Grafana dashboard JSON. Dashboards
should only query InfluxDB and PostgreSQL.

## Recommended Repository Separation

Keep the concern boundaries explicit:

```text
scripts/
  collect-cloudgate-telemetry.sh
  probe-cloudgate-api.sh

config/cloudgate/
  gateways.yml.tmpl
  telemetry-fields.yml

docker-compose.cloudgate-telemetry.yml

config/grafana/provisioning/dashboard-files/
  cloudgate-fleet.json

docs/
  cloudgate-statistics.md
```

The existing provisioning script should remain focused on registration and
Basic Station configuration. It may record static metadata discovered during
provisioning, but it should not become the recurring monitoring job.

## Proposed Implementation Path

1. Build a read-only SSH collector prototype that emits normalized JSON for the
   fields already confirmed on the live gateway.
2. Store that JSON as InfluxDB line protocol or use a small ingestion container
   that writes to InfluxDB v2.
3. Add a basic Grafana Cloudgate fleet dashboard for inventory, connectivity,
   system resources, VPN state, Basic Station state, and interface counters.
4. Add authenticated web API probing for `/api/system_info`, `/api/modem`,
   `/api/sim`, `/api/internetConnection`, and `/api/events`.
5. Decide whether cellular RF/GPS collection should use the web API or a
   gateway-side helper.
6. Add ChirpStack gateway metadata updates only for static inventory fields.
7. Harden credentials with key-based SSH or per-gateway collector credentials.

## Open Questions

- Which Cloudgate firmware/image versions are deployed across the expected
  fleet, and do they expose the same web API schema?
- Can Cloudgate Universe export firmware/image/configuration inventory through
  an API suitable for automation?
- Should ICCID, IMSI, and IMEI be collected, redacted, hashed, or omitted?
- Is GPS active on all LoRaWAN-capable units, and what command/API exposes fix
  state on the deployed image?
- Should telemetry be pull-based over VPN/SSH, push-based over MQTT, or a hybrid
  depending on gateway reachability?
- What interval is acceptable for polling cellular and resource metrics without
  adding avoidable load to older gateways?

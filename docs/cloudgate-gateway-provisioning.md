# Cloudgate Gateway Provisioning

This process provisions a Cloudgate gateway for the ChirpStack Basics Station
LNS endpoint used by this deployment. It registers the gateway in ChirpStack,
configures the Cloudgate Basic Station client, and runs staged verification.

The process never performs a factory reset. If a reset is required between
regional tests, stop, have the operator perform the reset manually under
supervision, wait until VPN/SSH access is restored, then rerun the script.

## Requirements

- VPN or LAN SSH access to the Cloudgate gateway.
- `sshpass`, `ssh`, `curl`, and `jq` on the machine running the script.
- A ChirpStack API key exported as `CHIRPSTACK_API_KEY`.
- A live ChirpStack Gateway Bridge already configured for the same region.

Supported Cloudgate region mappings:

| Repo region | Cloudgate region code |
|---|---:|
| `us915` | `915` |
| `eu868` | `868` |

The script discovers supported repo regions from `config/regions/*/metadata.env`,
but only regions with known Cloudgate region codes are accepted.

## Usage

```bash
export CHIRPSTACK_API_KEY='...'

scripts/provision-cloudgate-gateway.sh \
  --ip-address 10.11.0.243 \
  --username admin \
  --password 'gateway-password' \
  --region us915
```

Optional arguments:

| Argument | Default | Notes |
|---|---|---|
| `--api-base` | `https://chirpstack.machinesaver.com/api` | ChirpStack REST API base. |
| `--lns-uri` | `wss://chirpstack.machinesaver.com:3001` | Basics Station LNS URI. |
| `--tenant-id` | first tenant from `GET /api/tenants?limit=1` | Use when multiple tenants exist. |
| `--name` | Cloudgate serial number | Falls back to `Cloudgate <gateway_eui>` if the serial cannot be discovered. Existing custom names are preserved on update. |
| `--auth-mode server-tls` | `server-tls` | The only supported v1 mode. |
| `--dry-run` | off | Validates inputs and prints planned API/SSH writes. |

`--auth-mode mutual-tls` is reserved for a future version. Mutual TLS will need
gateway client certificate/key provisioning plus server CA installation and is
not implemented here.

## What The Script Changes

ChirpStack:

- Uses `Grpc-Metadata-Authorization: Bearer $CHIRPSTACK_API_KEY`.
- Resolves the tenant with `GET /api/tenants?limit=1` unless `--tenant-id` is
  supplied.
- Looks up the gateway with `GET /api/gateways/{gatewayId}`.
- Creates a missing gateway with gateway EUI, tenant id, name, description, and
  `statsInterval: 30`.
- Updates an existing gateway without deleting, recreating, or clearing
  user-managed tenant, location, tags, or metadata. Only script-owned fields are
  touched: description, an empty/default EUI-derived name, an empty stats
  interval, and it attempts to remove a stale `region_common_name` metadata
  value when it conflicts with the selected region. ChirpStack or gateway stats
  may retain or repopulate that metadata, so use `region_config_id` and gateway
  logs as the source of truth for region verification.

Cloudgate Basic Station UCI:

- `cg_conf_basicstation.general.uri`
- `cg_conf_basicstation.general.auth=tc`
- `cg_conf_basicstation.general.region`
- `cg_conf_basicstation.general.routerid`
- `cg_conf_basicstation.general.prefix=::0`

After setting those fields, the script runs:

```sh
uci commit cg_conf_basicstation
/etc/init.d/bstation restart
```

It does not change unrelated Cloudgate network, VPN, LTE, Ethernet, user, or
factory-reset settings.

For `wss://` LNS URIs, the script checks for existing gateway trust material at
common Cloudgate paths. If none is found, it stops with a manual action instead
of guessing how to install or overwrite trust files.

## Gateway EUI Discovery

The gateway EUI is normalized to lowercase hex without colons before it is used
as the ChirpStack gateway id.

Discovery order:

1. `uci get cg_conf_basicstation.general.routerid`
2. `/etc/station/routerid`
3. `m2m_printenv -n mac_addr`, converted to EUI64 as `<first 3 bytes>fffe<last 3 bytes>`

## Gateway Name Discovery

The default ChirpStack gateway name is the Cloudgate serial number discovered
from:

```sh
m2m_printenv -n serial_nbr
```

If that value is unavailable, the script falls back to `Cloudgate <gateway_eui>`.
An explicit `--name` always wins. On update, an existing custom name is
preserved, but the old default `Cloudgate <gateway_eui>` is upgraded to the
serial number when the serial is available.

## Region Notes

The script configures only the gateway. It does not switch the live ChirpStack
server or Gateway Bridge region.

Before running, confirm the live ChirpStack Gateway Bridge already matches the
selected region. A region mismatch can show up as:

- Basic Station connects and then disconnects after router config.
- No `lastSeenAt` update for the gateway in ChirpStack.
- Level 1 local gateway configuration succeeds while Level 3 ChirpStack
  verification never observes stats.

## Verification Levels

Level 1 confirms configuration was applied on the gateway:

- `/etc/station/tc.uri` matches the expected LNS URI.
- `/etc/station/routerid` matches the discovered EUI.
- `uci get cg_conf_basicstation.general.region` matches the Cloudgate region
  code.

Level 2 checks process and logs:

- Confirms a Basic Station process is present when available.
- Prints recent `/log/messages` lines containing Basic Station, LNS, websocket,
  or router activity.

Level 3 polls ChirpStack:

- Calls `GET /api/gateways/{gatewayId}` for `lastSeenAt` or gateway state.
- Treats missing `lastSeenAt` as a warning, not proof that local configuration
  failed. Region mismatch or delayed stats can cause this.

## Dry Run

Use dry run before changing a gateway:

```bash
export CHIRPSTACK_API_KEY='...'

scripts/provision-cloudgate-gateway.sh \
  --ip-address 10.11.0.243 \
  --username admin \
  --password 'gateway-password' \
  --region us915 \
  --dry-run
```

Dry run still performs read-only SSH discovery and read-only ChirpStack API
lookups. It prints the create/update payload and every SSH write that would be
run, but it does not create or update the ChirpStack gateway and does not write
Cloudgate UCI settings.

## Supervised Regional Test Flow

1. Run the script for the first region, for example `--region us915`.
2. Confirm Level 1 and Level 2 verification. Use Level 3 only when the live
   ChirpStack stack is running the same region.
3. Stop. Do not automate a reset.
4. Ask the operator to factory reset the Cloudgate manually under supervision.
5. Wait until VPN/SSH access to the gateway is restored.
6. Rerun the script for the next region, for example `--region eu868`.
7. Record whether Level 1 and Level 2 pass. Level 3 requires the live server to
   match the selected region.

## Live US915 Example

```bash
export CHIRPSTACK_API_KEY='...'

scripts/provision-cloudgate-gateway.sh \
  --ip-address 10.11.0.243 \
  --username admin \
  --password 'gateway-password' \
  --region us915
```

Expected known gateway id for the current supervised US915 test hardware:

```text
000ce3fffe75ed12
```

Expected Cloudgate configuration:

```text
tc.uri=wss://chirpstack.machinesaver.com:3001
auth=tc
region=915
```

## Future Hardening

- Key-based SSH instead of password SSH through `sshpass`.
- Mutual TLS support with explicit gateway client certificate/key and server CA
  management.
- Separate live server region switching workflow, kept outside gateway
  provisioning.

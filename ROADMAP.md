# Roadmap

Planned improvements for maintainability, modularity, and production readiness.

## Near Term

### Add a validation script

Create a single command such as `scripts/validate.sh` or `make validate` that checks the deployment before release.

Suggested checks:

- Shell linting for `setup.sh` and scripts.
- YAML validation for Compose and Grafana files.
- Render config from `.env.example` or a test fixture.
- Run `docker compose config` for the base stack.
- Run `docker compose -f docker-compose.yml -f docker-compose.monitoring.yml config` for the monitoring stack.

### Make generated config output cleaner

Separate source templates from generated runtime files more explicitly. This would reduce confusion around files such as rendered ChirpStack config, Nginx config, region config, and Grafana datasource config.

Possible approaches:

- Generate all runtime config into a dedicated ignored directory.
- Keep templates tracked and mount only generated files from a known output path.
- Add comments to generated files identifying their source template and regeneration command.

## Medium Term

### Add GitHub issue templates

If this repository is hosted on GitHub, add `.github/ISSUE_TEMPLATE/bug_report.md` and `.github/ISSUE_TEMPLATE/feature_request.md`.

Expected benefit: cleaner bug reports, clearer reproduction details, and easier prioritization.

### Add a lightweight CI workflow

Add a GitHub Actions workflow that runs the validation script on pull requests.

Expected benefit: catch deployment, template, and syntax regressions before merge.

### Harden operational security defaults

Review exposed ports and credential handling for internet-facing deployments.

Areas to consider:

- Whether MQTT should be publicly exposed by default.
- Whether Basics Station and MQTT need optional TLS/client-auth modes.
- Whether generated credentials should be printed only once or stored in a separate local credentials note.
- Whether file permissions for generated secrets should be stricter.

### Add gateway-specific certificate support

Support optional per-gateway mutual TLS for Basics Station deployments in unpredictable or untrusted network environments.

Current gateway provisioning can start with server TLS validation only, using `wss://` and a trusted server CA. For production fleets deployed globally, add a hardened mode where each gateway receives its own client certificate and private key, and the Gateway Bridge verifies that certificate before accepting Basic Station traffic.

Expected capabilities:

- Generate or import a unique client certificate/key pair per gateway.
- Install the gateway certificate, key, and server trust material during provisioning.
- Record enough certificate metadata to rotate or revoke individual gateways without affecting the whole fleet.
- Keep non-mutual-TLS provisioning available for lab and controlled-network deployments.

Expected benefit: reduce the risk that a party on an uncontrolled network can impersonate a gateway by reusing or guessing a gateway EUI.

### Add upgrade documentation

Document how to update container images, back up volumes, restore data, rotate credentials, and change regions safely. Image versions are now pinned to full semver across all Compose files and scripts, so a controlled upgrade path is the next gap.

### Add Cloudgate fleet telemetry

Turn the Cloudgate statistics research in `docs/cloudgate-statistics.md` into a
separate collector and Grafana dashboard. Keep gateway provisioning focused on
registration and Basics Station configuration, store recurring Cloudgate
runtime data in InfluxDB, and use ChirpStack/PostgreSQL only for gateway
identity and slower-changing inventory metadata.

Expected capabilities:

- Collect Cloudgate inventory, firmware/image/config versions, cellular state,
  signal quality, GPS state, VPN state, Basic Station health, resource usage,
  interface counters, and useful log-derived RF statistics.
- Support a read-only SSH collector first, then add authenticated Cloudgate web
  API collection for structured modem, SIM, system, and event data.
- Add a dedicated `cloudgate-fleet.json` Grafana dashboard without embedding
  collection logic in dashboard JSON.

## Later

### Add smoke tests

Create a minimal post-deployment smoke test that verifies expected services, health endpoints, Nginx routing, and optional monitoring routes.

## Recently Completed

### Pin all image versions

All images across `docker-compose.yml`, `docker-compose.monitoring.yml`, and operational scripts (`renew-ssl.sh`, `backup.sh`, `restore.sh`) are now pinned to full semver tags. No image uses a broad tag such as `:4`, `:latest`, or a major-version-only pin.

### Fix gateway monitoring dashboards

Grafana gateway online and last-seen panels now query ChirpStack's authoritative PostgreSQL `gateway` state using `last_seen_at` and `stats_interval_secs`. InfluxDB remains the source for gateway packet and device uplink time-series charts, and `scripts/validate.sh --live-gateway-status` provides an optional live smoke check for connected gateways.

### Add backup and restore tooling

`scripts/backup.sh` now creates a timestamped archive with `.env`, generated runtime config, a PostgreSQL logical dump, and Docker volume snapshots for Redis, Mosquitto, Certbot, and optional monitoring state. `scripts/restore.sh` restores that archive after explicit confirmation and restarts the stack.

### Make public MQTT exposure explicit

Mosquitto now stays internal by default. Host port `1883` is exposed only through the optional `docker-compose.mqtt.yml` override and `EXPOSE_MQTT` setup choice.

### Make setup safe to rerun

`setup.sh` now detects an existing `.env`, exits without changes by default, and backs up the current file before an intentional overwrite.

### Harden admin and SSL setup paths

Admin setup now avoids guessed container names and verifies the admin email update. SSL renewal now uses deterministic Compose volume names instead of broad Docker volume matching.

### Make region support module-based

US915 and EU868 now live under `config/regions/<region-id>/` with tracked metadata, ChirpStack TOML, and Basics Station concentrator TOML. Setup builds its menu from those modules, config generation renders from the selected module, and validation renders every discovered module automatically.

### Add AirVibe device profile auto-provisioning

`scripts/provision-devices.sh` calls the ChirpStack REST API after `setup.sh` completes to create two device profiles per selected region: `AirVibe <REGION>` (Class C, normal operation) and `AirVibe <REGION> FUOTA` (Class A, for firmware update sessions). The script is idempotent, uses a ChirpStack API key generated via the CLI, and calls the `chirpstack-rest-api` container directly via its Docker bridge IP to avoid hairpin NAT issues on VPS deployments. The AirVibe TS013 payload codec (v2.1.2) is embedded in each profile automatically.

### Fix gateway command topic rendering

`scripts/generate-config.sh` now renders ChirpStack gateway MQTT downlink commands with `{{command}}`, matching ChirpStack v4's per-region backend template. This keeps setup-generated configs publishing join-accept and downlink frames to `REGION/gateway/GATEWAY_ID/command/down`, which the Basic Station gateway bridge forwards to the gateway.

### Fix Nginx REST API routing

The Nginx config previously routed `/api/` to a `chirpstack-rest-api:8090` upstream but the `chirpstack-rest-api` service was missing from `docker-compose.yml`. Added the `ghcr.io/chirpstack/chirpstack-rest-api:4.2.0` service and confirmed the two-upstream layout (`chirpstack_ui` → `chirpstack:8080` for the web UI, `chirpstack_api` → `chirpstack-rest-api:8090` for the REST API) is correct for ChirpStack v4, which serves gRPC on port 8080 and requires a separate HTTP gateway for REST clients.

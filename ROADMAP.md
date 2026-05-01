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

### Improve release repeatability

Pin production image versions more tightly instead of broad tags such as `chirpstack/chirpstack:4` and `grafana/grafana:latest`.

Expected benefit: safer upgrades, easier rollback, and more predictable deployments.

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

## Later

### Add smoke tests

Create a minimal post-deployment smoke test that verifies expected services, health endpoints, Nginx routing, and optional monitoring routes.

### Add upgrade documentation

Document how to update container images, back up volumes, restore data, rotate credentials, and change regions safely.

## Recently Completed

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

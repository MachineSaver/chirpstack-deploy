# Issues

Known bugs, behavior mismatches, and operational risks to investigate or fix.

## Open

### Region support is not fully modular

- **Area:** `scripts/generate-config.sh`, `config/chirpstack/regions`
- **Severity:** Medium
- **Status:** Open

Region configs are partly file-based, but Basics Station channel-plan metadata is embedded in shell branches. Adding a new region still requires editing unrelated setup and generation logic.

Proposed fix: make region metadata data-driven, derive setup choices from available region definitions, and validate every region module.

### CI should validate the full release contract

- **Area:** `.github/workflows/validate.yml`, `scripts/validate.sh`
- **Severity:** Medium
- **Status:** Open

The validation workflow exists, but the project should continue tightening it around exact release behavior: all Compose variants, all rendered templates, no unresolved template variables, and deterministic tool installation.

Proposed fix: expand validation as new Compose variants and generated files are added.

## Closed

### Backup, restore, and upgrade workflow is missing

- **Area:** Operations
- **Severity:** Medium
- **Status:** Fixed

The stack has persistent Postgres, Redis, Mosquitto, InfluxDB, Grafana, and Certbot volumes, but there was no scripted backup/restore workflow or upgrade procedure.

Fix: added `scripts/backup.sh` and `scripts/restore.sh`. Backups include `.env`, generated runtime config, a PostgreSQL logical dump, and snapshots of Redis, Mosquitto, Certbot, and optional monitoring volumes. Restore requires explicit confirmation, recreates the PostgreSQL volume from the dump, restores the other archived volumes, regenerates runtime config, and starts the stack.

### VPS first-run may start Nginx with missing certificate files

- **Area:** `setup.sh`, `config/nginx`
- **Severity:** High
- **Status:** Fixed

VPS mode rendered the HTTPS Nginx config before the initial Let's Encrypt certificate existed, then attempted to start Nginx for the ACME HTTP challenge. That could fail because the configured certificate paths were not present yet.

Fix: setup now renders a temporary HTTP-only Nginx config for the ACME challenge, obtains the certificate, then re-runs `scripts/generate-config.sh` to restore the normal HTTPS config before reloading Nginx.

### MQTT is exposed on the host by default

- **Area:** `docker-compose.yml`, `docker-compose.mqtt.yml`, `setup.sh`, `README.md`
- **Severity:** High
- **Status:** Fixed

The Mosquitto broker was published on host port `1883` by default. That was convenient for integrations, but too broad for VPS installs because internal ChirpStack, gateway-bridge, and Mosquitto traffic does not require host exposure.

Fix: removed the default host port from the base Compose stack, added `docker-compose.mqtt.yml` for optional host access, added an `EXPOSE_MQTT` setup prompt, and updated validation and docs for both stack variants.

### Re-running setup can overwrite a live deployment

- **Area:** `setup.sh`, `.gitignore`, `README.md`
- **Severity:** High
- **Status:** Fixed

`setup.sh` wrote a fresh `.env`, regenerated secrets, and started services without first protecting an existing deployment.

Fix: setup now detects an existing `.env`, exits without changes unless the operator types `OVERWRITE`, and backs up the previous file to an ignored `.env.*.bak` path before writing a replacement.

### Admin account setup is fragile

- **Area:** `setup.sh`
- **Severity:** High
- **Status:** Fixed

The admin setup path depended on a guessed container name for `docker cp` and built the admin email SQL command from loosely validated input.

Fix: setup now uses `docker compose exec` service addressing to write the temporary password file, restricts email input to conventional address characters, uses configured Postgres user/database values, and verifies the email update returns the expected admin email.

### SSL renewal volume discovery may match the wrong Compose project

- **Area:** `docker-compose.yml`, `docker-compose.monitoring.yml`, `docker-compose.mqtt.yml`, `scripts/renew-ssl.sh`
- **Severity:** Medium
- **Status:** Fixed

The renewal script discovered Certbot volumes with a broad `docker volume ls | grep certbot_*` lookup. On hosts with multiple Compose projects, that could select the wrong volume.

Fix: the Compose project name is now pinned to `chirpstack`, and renewal uses deterministic `chirpstack_certbot_certs` and `chirpstack_certbot_www` volume names after validating that both exist.

### Admin account setup may not create a usable user

- **Area:** `setup.sh`
- **Severity:** High
- **Status:** Fixed

The original code contained a no-op command (SQL piped to `true`), undefined shell variables (`${POSTGRES_USER}`, `${POSTGRES_DB}`), and `|| true` guards on every step so failures were invisible. The `success` message printed unconditionally.

Fix: consolidated to two commands — `chirpstack set-password` to set the password on the seeded `admin` account, then a `psql` UPDATE to change the email. Both use proper `if !` error checks; failures surface a warning with fallback instructions instead of silently printing success.

### EU868 region selection may still subscribe to US915 gateway topics

- **Area:** `config/chirpstack/chirpstack.toml.tmpl`
- **Severity:** High
- **Status:** Fixed (commit 225780b)

`generate-config.sh` now derives `LORA_REGION_ID` from the selected region and injects it into `event_topic`, `state_topic`, and `command_topic` in the rendered `region.toml`.

### Grafana datasource provisioning may create duplicate or invalid datasource files

- **Area:** `scripts/generate-config.sh`, `config/grafana/provisioning/datasources/influxdb.yml`, `docker-compose.monitoring.yml`
- **Severity:** Medium
- **Status:** Not reproducible — already resolved

`docker-compose.monitoring.yml` mounts only `./generated/grafana/provisioning/datasources` into Grafana. The `config/grafana/provisioning/datasources/` directory contains only `influxdb.yml.tmpl` and is never mounted into any container, so no duplicate or unrendered file reaches Grafana.

### Docker Compose validation has not been automated

- **Area:** Project workflow
- **Severity:** Medium
- **Status:** Fixed

`scripts/validate.sh` runs shellcheck, renders all four template combinations (US915/EU868 × local/vps, with and without monitoring), YAML-lints Compose and Grafana output files, and validates `docker compose config` for both stack variants. `.github/workflows/validate.yml` runs it automatically on every push and pull request to `main`.

## Verification Notes

Docker was not available in the review environment, so Compose rendering and container startup were reviewed statically rather than executed.

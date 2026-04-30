# Issues

Known bugs, behavior mismatches, and operational risks to investigate or fix.

## Closed

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

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
- **Status:** Open

When monitoring is enabled, `generate-config.sh` renders `influxdb.generated.yml`, while the tracked `influxdb.yml` with `${INFLUXDB_*}` placeholders remains in the mounted provisioning directory. Grafana mounts the entire provisioning directory, so both files may be processed.

Expected outcome: make datasource provisioning deterministic. Either render the mounted datasource file in place, mount only generated provisioning output, or rely on Grafana environment expansion and remove the generated duplicate.

### Docker Compose validation has not been automated

- **Area:** Project workflow
- **Severity:** Medium
- **Status:** Open

There is no committed validation command or CI workflow that renders templates and validates the merged Compose files. This increases the chance of shipping broken deployment changes.

Expected outcome: add a repeatable validation path that runs shell linting, template rendering with sample values, and `docker compose config` for base and monitoring configurations.

## Verification Notes

Docker was not available in the review environment, so Compose rendering and container startup were reviewed statically rather than executed.

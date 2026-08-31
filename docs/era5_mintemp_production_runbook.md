# ERA5 minimum-temperature production runbook

This runbook covers the Atlas production backfill for `era5_mintemp`. It is intentionally staged: complete and audit an earlier endpoint before advancing to the next one.

## Prerequisites and Atlas setup

- Use the repository checkout at `/project/disease_ecology/cds-datagrab` (or set `REPO_DIR` explicitly).
- Load the Atlas modules used by `hpc/run_era5_mintemp.slurm`: R 4.5, GDAL, PROJ, GEOS, and UDUNITS.
- Configure a CDS token in the Atlas environment expected by `ecmwfr`; never put credentials in YAML, manifests, or logs.
- Confirm the template and boundary are unchanged. The required template SHA256 is `4BE01F0ECAFF35216A72EB8F27E791311AF90D35B5A4FFF1E46A74EDB6DC633B`.

The production root is `/project/disease_ecology/cds-datagrab-output`. It is separate from the repository and from smoke output. The production submit wrapper validates `.cds-datagrab-root` before calling the shared submission machinery.

## Configurations and dry plans

Use `config/era5_mintemp_production.yml` for production and `config/era5_mintemp_weekly_smoke.yml` for the seven-day July 6–12 smoke test. The original `config/era5_mintemp_smoke.yml` remains the three-day July 1–3 smoke test.

Every production invocation must provide an explicit `OBSERVED_END`; the wrapper passes it to the established `--observed-end` option. Dry plans do not contact CDS:

```bash
OBSERVED_END=2022-12-31 MODE=plan DRY_RUN=true bash hpc/submit_era5_mintemp_production.sh
OBSERVED_END=2023-12-31 MODE=plan DRY_RUN=true bash hpc/submit_era5_mintemp_production.sh
OBSERVED_END=2024-12-31 MODE=plan DRY_RUN=true bash hpc/submit_era5_mintemp_production.sh
OBSERVED_END=2025-12-31 MODE=plan DRY_RUN=true bash hpc/submit_era5_mintemp_production.sh
OBSERVED_END=2026-07-26 MODE=plan DRY_RUN=true bash hpc/submit_era5_mintemp_production.sh
```

The planning summary records the effective range, monthly request count, complete and incomplete ISO weeks, request area, template checksum, and estimated raw-file count. For the validated full endpoint it should report 1,668 dates, 55 monthly requests, and 238 complete ISO weeks. For the 2022 endpoint it should report 365 dates and 12 monthly requests. January 1–2, 2022 is an incomplete ISO week; the first complete weekly raster is 2022-W01.

## Cumulative backfill sequence

After a dry plan has been reviewed, submit each endpoint in order:

```bash
OBSERVED_END=2022-12-31 MODE=full DRY_RUN=false bash hpc/submit_era5_mintemp_production.sh
OBSERVED_END=2023-12-31 MODE=full DRY_RUN=false bash hpc/submit_era5_mintemp_production.sh
OBSERVED_END=2024-12-31 MODE=full DRY_RUN=false bash hpc/submit_era5_mintemp_production.sh
OBSERVED_END=2025-12-31 MODE=full DRY_RUN=false bash hpc/submit_era5_mintemp_production.sh
OBSERVED_END=2026-07-26 MODE=full DRY_RUN=false bash hpc/submit_era5_mintemp_production.sh
```

The wrapper submits `hpc/run_era5_mintemp.slurm`; it does not duplicate request, download, processing, or aggregation logic. A later stage may be submitted only after the preceding run has `pipeline_status: success` in its `run_manifest.json` and its final validation is successful.

## Monitoring, restart, and audit procedure

For each run, record the run directory under `runs/production/era5_mintemp/`, the pipeline log under `logs/pipeline/production/era5_mintemp/`, and the SLURM stdout/stderr under `logs/slurm/production/`. Review:

- `run_manifest.json`: stage statuses, failed stage, active request hash, source map, daily and weekly counts, and final validation.
- `production_planning_summary.txt` and `.json`: endpoint counts and boundary-week decisions.
- `planned_dates.csv`, request manifests, and inventory snapshots: request and reuse provenance.
- daily and weekly inventories: valid, invalid, written, reused, and quarantined products.

If a job stops, inspect the manifest and log before restarting. The pipeline reuses validated daily and weekly products, selects active raw inputs by request provenance, and plans only missing or invalid dates. Do not delete smoke or production data to force a restart. Use `overwrite=true` only for an explicitly audited repair.

Monitor raw storage, extracted storage, daily/weekly output storage, CDS quota, SLURM wall time, memory, and the number of monthly requests before each endpoint. Pause and investigate any failed validation, unexpected request area, invalid root marker, duplicate observed date, or nonzero invalid-product count.

## Incomplete weeks and updates

Weekly aggregation requires seven valid observed daily rasters. Boundary weeks are recorded as incomplete and are not written as observed weekly rasters. The 2022 initial boundary is therefore expected; do not fill it with an estimate. Re-run the affected endpoint after a validated correction, then audit the affected ISO-week list and weekly output count.

Changes to the template, GPKG, CDS payload, spatial area, temporal defaults, or validation rules require a new review and checksum audit before production continuation. Keep the smoke configurations and their outputs intact when updating production code.

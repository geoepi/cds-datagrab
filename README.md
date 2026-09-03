<p align="center">
  <img src="images/datagrab_hex.png" width="350" alt="hex sticker">
</p>
  
  
# cds-datagrab

`cds-datagrab` is a reproducible R-package workflow for retrieving environmental data from the Copernicus Climate Data Store (CDS), aligning source data to the protected study-area template, writing daily GeoTIFFs, and aggregating complete ISO weeks. Generated data live outside the Git checkout and are organized so that raw requests, extracted source files, derived rasters, inventories, manifests, and Slurm logs remain auditable and resumable.

## Storage layout

Atlas defaults are `/project/disease_ecology/cds-datagrab-output` for production and `/project/disease_ecology/cds-datagrab-smoke-output` for smoke. Use an external root for any other deployment.

```text
<root>/
├── data/<profile>/<product_id>/
│   ├── daily/
│   ├── weekly/
│   └── ...
├── data/<profile>/_sources/era5land_daily_mean_utc06/
│   ├── raw/
│   ├── extracted/
│   └── requests/
├── runs/<profile>/<product_id-or-source-run>/<run_id>/
└── logs/slurm/<profile>/
```

The eight ERA5-Land product directories contain derived daily and weekly products. Their raw monthly archives are stored once under the shared `era5land_daily_mean_utc06` source family; request-scoped `member_inventory.csv`, `source_map.csv`, and manifests connect each extracted source member to its product/date outputs.

## Product catalog

The ERA5-Land products are additive. They do not replace the four established standalone products.

| Product ID | Source dataset / variable | Output units | Daily statistic / temporal meaning | Weekly rule | Lineage |
|---|---|---|---|---|---|
| `era5_mintemp` | `derived-era5-single-levels-daily-statistics` / `2m_temperature` | °C | CDS daily minimum from 6-hourly data | minimum of 7 observed days | standalone |
| `era5_soilmoist` | `derived-era5-single-levels-daily-statistics` / `volumetric_soil_water_layer_1` | m³ m⁻³ | CDS daily mean, layer 1 | mean of 7 observed days | standalone |
| `era5_lai_low` | `reanalysis-era5-single-levels` / `leaf_area_index_low_vegetation` (`lai_lv`) | m² m⁻² | 00:00 UTC monthly-climatology observation | mean of 7 observed days | standalone |
| `agera5_relhum_min` | `sis-agrometeorological-indicators` / `2m_relative_humidity_derived` | % | precomputed 24-hour local-time minimum | mean of 7 observed days | standalone |
| `era5land_tmean` | `derived-era5-land-daily-statistics` / `2m_temperature` | °C | arithmetic mean over the UTC−6 calendar day | mean of 7 daily means | `era5land_daily_mean_utc06` |
| `era5land_soiltemp_l1_mean` | same / `soil_temperature_level_1` | °C | UTC−6 daily mean, 0–7 cm | mean | `era5land_daily_mean_utc06` |
| `era5land_soiltemp_l2_mean` | same / `soil_temperature_level_2` | °C | UTC−6 daily mean, 7–28 cm | mean | `era5land_daily_mean_utc06` |
| `era5land_soilwater_l1_mean` | same / `volumetric_soil_water_layer_1` | m³ m⁻³ | UTC−6 daily mean, 0–7 cm | mean | `era5land_daily_mean_utc06` |
| `era5land_soilwater_l2_mean` | same / `volumetric_soil_water_layer_2` | m³ m⁻³ | UTC−6 daily mean, 7–28 cm | mean | `era5land_daily_mean_utc06` |
| `era5land_surface_pressure_mean` | same / `surface_pressure` | kPa | UTC−6 daily mean | mean | `era5land_daily_mean_utc06` |
| `era5land_lai_high_mean` | same / `leaf_area_index_high_vegetation` | m² m⁻² | UTC−6 daily label from monthly climatology | mean | `era5land_daily_mean_utc06` |
| `era5land_lai_low_mean` | same / `leaf_area_index_low_vegetation` | m² m⁻² | UTC−6 daily label from monthly climatology | mean | `era5land_daily_mean_utc06` |

The ERA5-Land request always contains all eight variables, with `daily_statistic = daily_mean`, `time_zone = utc-06:00`, and `frequency = 1_hourly`. High- and low-vegetation LAI represent monthly variation without interannual variability, so consecutive daily labels may contain identical layers.

## Updating all production products

The portfolio operator command advances all 12 products under one common daily endpoint:

```bash
bash hpc/submit_all_products.sh --through latest-common --mode plan
bash hpc/submit_all_products.sh --through latest-common --mode update
bash hpc/submit_all_products.sh --through 2026-07-10 --mode update
```

`--through latest-common` uses the minimum locally configured `temporal.observed_end` across the five source workflows; it does not scrape CDS to infer availability and fails conservatively when a source endpoint is not locally known. `--through YYYY-MM-DD` is an explicit operator-requested target: it must be a valid date within every workflow's configured hard temporal horizon, but it may exceed `temporal.observed_end`. In that case the plan reports source availability as `unverified explicit target`; the source workflows determine whether CDS actually supplies the requested endpoint. Plan mode contacts no CDS, submits no Slurm jobs, and does not modify production outputs. It reports source availability, projected product counts, the common endpoint, and the exact child commands.

One operator command is not one CDS request: it submits four standalone source workflows and the shared ERA5-Land source family concurrently. After all five source jobs, five aggregation jobs run with an `afterok` dependency; final portfolio validation runs only after all aggregation jobs succeed. Valid daily/weekly artifacts are reused by existing child logic, and ordinary portfolio updates do not use `--overwrite`.

Each update writes `runs/production/_portfolio/<run_id>/portfolio_manifest.json`, including source and aggregation job IDs, dependencies, common dates, per-product counts, validation status, and failure stage/message. A failed source or aggregation stage is safe to retry with a new portfolio run using the same external root; no valid TIFFs are deleted. If Slurm cancels a dependent validator, the manifest remains `validation_submitted` until the validator starts or the optional reconciliation utility records `cancelled`/`failed`.

When launched by CHIME, the approved execution ID is propagated as the
optional `CHIME_EXECUTION_ID` environment variable through the registered
wrappers and Slurm submissions. New portfolio manifests copy it to the
top-level `chime_execution_id` field. This is opaque provenance for
cross-system correlation only: it does not affect the cds-datagrab run ID,
processing, product selection, expected counts, validation, or portfolio
status. Standalone runs leave the field `null`.

## Production status

The production portfolio has been successfully exercised on Atlas. Validation run `20260831T181051Z_portfolio` completed successfully through **2026-07-26** for all **12 products**: four standalone products and eight ERA5-Land products. All products passed sidecar, geometry, and weekly validation, with **238 complete ISO weeks**. The ERA5-Land daily inventory contains 1,668 daily TIFFs per product (13,344 total) for the validated period; the portfolio validation also covers the four standalone products and their synchronized weekly outputs.

The configured hard horizon remains **2022-01-01 through 2026-12-31**. Dates after 2026-07-26 are configured future dates, not evidence that data are available or validated. `temporal.observed_end` records the latest operator-confirmed endpoint and is currently 2026-07-26.

## Atlas installation and preflight

```bash
module purge
module load r/4.5 udunits gdal proj geos git
export REPO_DIR=/project/disease_ecology/cds-datagrab
export CDS_DATAGRAB_R_LIB=/project/disease_ecology/cds-datagrab-r-library/4.5
export HOME_R_LIB=/home/john.humphreys/R/x86_64-pc-linux-gnu-library/4.5
export R_LIBS_USER="${CDS_DATAGRAB_R_LIB}:${HOME_R_LIB}"
unset R_LIBS_SITE
bash hpc/install_cdsdatagrab_atlas.sh "$REPO_DIR"
Rscript "$REPO_DIR/hpc/preflight_cdsdatagrab.R"
```

The source checkout commit and `.cds-datagrab-installed-commit` must match before execution; reinstall with the command above when they differ. Planning and preflight do not contact CDS. Keep `ecmwfr_PAT` in a secure environment and never print or commit its value.

## Common execution modes

The family shell wrapper requires exactly one execution option. It plans locally with no CDS contact or Slurm submission, and submits the other modes to their corresponding Atlas Slurm runner:

```bash
export CONFIG=config/era5land_daily_mean_utc06_production.yml
export CDS_DATAGRAB_ROOT=/project/disease_ecology/cds-datagrab-output

bash hpc/submit_era5land_daily_mean.sh --config "$CONFIG" --output-root "$CDS_DATAGRAB_ROOT" --dry-run
bash hpc/submit_era5land_daily_mean.sh --config "$CONFIG" --output-root "$CDS_DATAGRAB_ROOT" --stage-requests
bash hpc/submit_era5land_daily_mean.sh --config "$CONFIG" --output-root "$CDS_DATAGRAB_ROOT" --retrieve-requests
bash hpc/submit_era5land_daily_mean.sh --config "$CONFIG" --output-root "$CDS_DATAGRAB_ROOT" --process
bash hpc/submit_era5land_daily_mean.sh --config "$CONFIG" --output-root "$CDS_DATAGRAB_ROOT" --execute
```

The direct R CLI is useful when a separate weekly pass is required or when selecting a subset of product IDs for local processing. The following is a smoke/validation example; do not start the pending production weekly pass without an explicit production decision:

```bash
Rscript scripts/run_era5land_daily_mean.R --help
Rscript scripts/run_era5land_daily_mean.R --config config/era5land_daily_mean_utc06_weekly_smoke.yml --output-root /project/disease_ecology/cds-datagrab-smoke-output --mode aggregate --dry-run false --start-date 2026-02-02 --end-date 2026-02-08
```

It supports `plan`, `download`, `stage-requests`, `retrieve-requests`, `process`, `aggregate`, `execute`, and `full`, plus `--start-date`, `--end-date`, `--products`, `--overwrite`, and `--rebuild-all-weeks`. The annual dispatcher supports `plan` and `execute`; use `--product era5land_daily_mean_utc06` for the complete family.

## Resume and recovery

Keep the same external root and do not delete valid TIFFs during recovery. A complete monthly request can fast-forward without reopening source archives; within an incomplete request, complete products can fast-forward while only missing or invalid product dates are processed. Valid daily TIFFs and request-specific sidecars are reused unless `--overwrite` is explicitly supplied.

When the 55 monthly source archives are already valid locally, do not repeat stage or retrieve merely because local processing needs to resume. Inspect the request registry and run manifest, rerun `--process`, and use the 72-hour historical process/full wrapper when running the established Atlas configuration. See [the operator runbook](docs/operator_runbook.md) and [the request lifecycle](docs/era5land_request_lifecycle.md).

For a submitted portfolio whose dependency chain may have been cancelled, inspect its state without changing it:

```bash
Rscript scripts/reconcile_portfolio_manifest.R --manifest "$CDS_DATAGRAB_ROOT/runs/production/_portfolio/<run_id>/portfolio_manifest.json"
```

Add `--apply` only after reviewing the reported Slurm states. This records terminal cancellation/failure state; it is optional and is not required for successful production execution.

## Diagnostics and recovery tools

| Tool | Purpose and safety |
|---|---|
| `scripts/debug_era5land_slice.R` | Preferred first diagnostic for one cached product/date before a broad family rerun. It contacts no CDS, but writes one selected daily output, sidecar, and diagnostic run under the external root. Invocation: `Rscript scripts/debug_era5land_slice.R --config config/era5land_daily_mean_utc06_production.yml --product era5land_tmean --date 2026-07-26 --output-root /project/disease_ecology/cds-datagrab-output`. |
| `scripts/repair_era5land_daily_sidecar_provenance.R` | Defaults to a dry-run audit. `--apply` atomically updates whitelisted sidecar provenance fields only; TIFFs are not rewritten. `--start-date` and `--end-date` scope the operation. Ambiguous mappings fail rather than being guessed; repeated application is idempotent. Apply mode retains `diagnostics/era5land_daily_sidecar_provenance_repair.csv`. |
| `scripts/backfill_daily_sidecars.R` | Maintenance utility for adding missing metadata sidecars to already validated daily TIFFs. Defaults to dry-run; `--apply` writes sidecars only, with `--start-date`/`--end-date` scoping. It does not repair raster values and is not part of routine portfolio updates. |
| `scripts/reconcile_portfolio_manifest.R` | Optional Slurm-state audit for submitted portfolio manifests. Without `--apply` it is read-only; `--apply` records terminal `failed`/`cancelled` state without contacting CDS or submitting work. |
| `scripts/audit_output_layout.R` | Read-only inventory/path audit. The default product set is the four standalone products, so pass `--product era5land_tmean` (and repeat for other family products) when auditing ERA5-Land. Invocation: `Rscript scripts/audit_output_layout.R --output-root /project/disease_ecology/cds-datagrab-output --profile production --product era5land_tmean`. |
| `hpc/preflight_cdsdatagrab.R` | Read-only Atlas environment/package/commit check. It requires `CDS_DATAGRAB_R_LIB` and optionally uses `REPO_DIR`; it does not submit work or contact CDS. |
| `hpc/plan_era5land_daily_mean.R` | Read-only family plan used by the wrapper. It reports effective dates, product count, complete weeks, weekly target, request hashes, and monthly request count. |

For persisted fields and diagnostic semantics, see [the output schema](docs/output_schema.md) and [the production validation summary](docs/production_validation_summary.md).

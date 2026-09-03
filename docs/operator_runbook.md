# Operator runbook

Run one product family and one calendar window at a time. Keep the external root shared across products and years. Plan first, inspect the plan and manifests, then execute. The protected master template is never edited.

## ERA5-Land coverage and support mask

ERA5-Land processing retains unmasked bilinear and nearest-neighbour projections and repairs only bounded, projection-created 8-neighbour components. The current limits are at most four cells per component, local target radius two cells, up to eight inverse-distance donors, and a source fallback buffer of at most 35 km. Donors are original finite projected values, never repaired cells; unsupported source-nodata gaps and larger/incomplete components fail.

The support mask is `spatial_domain/derived/era5land_support_mask.tif`, derived from the protected `spatial_domain/study_area_raster.tif` and `spatial_domain/derived/era5land_unsupported_cells.csv`. Exactly cells 28012, 35085, and 35964 are structural ERA5-Land exclusions. They may remain `NA` in daily and weekly outputs; every supported template cell must be finite. New exclusions, finite values outside the master template, and missing values in supported cells fail validation.

Coverage diagnostics include master/support counts, structural exclusions, pre-repair missing cells, repaired cells, unexpected post-repair missing cells, outside-support finite cells, component records, and source/projection classifications. The component CSVs and failure manifests retain donor distances, reasons, and original exception details.

## Common Atlas setup

```bash
export REPO_DIR=/project/disease_ecology/cds-datagrab
export CDS_DATAGRAB_R_LIB=/project/disease_ecology/cds-datagrab-r-library/4.5
export HOME_R_LIB=/home/john.humphreys/R/x86_64-pc-linux-gnu-library/4.5
export R_LIBS_USER="${CDS_DATAGRAB_R_LIB}:${HOME_R_LIB}"
unset R_LIBS_SITE ALLOW_MULTIYEAR
module purge
module load r/4.5 udunits gdal proj geos git
bash hpc/install_cdsdatagrab_atlas.sh "$REPO_DIR"
Rscript "$REPO_DIR/hpc/preflight_cdsdatagrab.R"
```

Use `/project/disease_ecology/cds-datagrab-output` for production and `/project/disease_ecology/cds-datagrab-smoke-output` for smoke. The source and installed commits must match. Check CDS credential presence without printing `ecmwfr_PAT`.

## Product matrix

| Selector | Products processed | Config | Wrapper | Annual planning |
|---|---|---|---|---|
| `era5_mintemp` | one standalone product | `config/era5_mintemp_production.yml` | `hpc/submit_era5_mintemp.sh` | 365/366 dates, 12 requests |
| `era5_soilmoist` | one standalone product | `config/era5_soilmoist_production.yml` | `hpc/submit_era5_soilmoist.sh` | 365/366 dates, 12 requests |
| `era5_lai_low` | one standalone product | `config/era5_lai_low_production.yml` | `hpc/submit_era5_lai_low.sh` | 365/366 dates, 12 requests |
| `agera5_relhum_min` | one standalone product | `config/agera5_relhum_min_production.yml` | `hpc/submit_agera5_relhum_min.sh` | 365/366 dates, 12 requests |
| `era5land_daily_mean_utc06` | all eight ERA5-Land products | `config/era5land_daily_mean_utc06_production.yml` | `hpc/submit_era5land_daily_mean.sh` | 365/366 dates, 12 source requests |

The ERA5-Land row is one shared eight-product source family, not eight independent CDS request streams. A full 2022–2026 configured horizon contains 55 monthly source requests. The current validated produced/observed endpoint is 2026-07-26; the configured hard horizon still ends 2026-12-31.

## Updating all production products

Use the portfolio wrapper when the four standalone products and the eight ERA5-Land products must advance under one temporal contract:

```bash
# Read-only: no CDS contact, Slurm submission, or production-output changes.
bash hpc/submit_all_products.sh --through latest-common --mode plan

# Normal incremental update.
bash hpc/submit_all_products.sh --through latest-common --mode update

# Explicit common endpoint.
bash hpc/submit_all_products.sh --through 2026-07-10 --mode update
```

The portfolio definition is `config/production_portfolio.yml`. It expands five logical source workflows to exactly 12 products. Endpoint policy is explicit:

- `--through latest-common` is conservative and resolves to the minimum locally configured `temporal.observed_end`. It does not query or scrape CDS, and requires every source endpoint to be known locally.
- `--through YYYY-MM-DD` is an operator-requested target. It must be a valid ISO date within every source workflow's configured hard temporal horizon, but it may extend beyond the currently known `temporal.observed_end`. Such source availability is reported as `unverified explicit target` until the source workflow runs; the source workflow remains authoritative and may fail normally if CDS cannot supply the date.

The planner never edits `temporal.observed_end` or treats an explicit future target as confirmed. The first update plan audits existing daily filenames and uses the earliest missing date needed by the portfolio, while child pipelines retain their normal reuse and provenance behavior.

The five source jobs are submitted concurrently. Each standalone job uses its existing full wrapper interface (`MODE=full DRY_RUN=false`), which plans, acquires missing source data, processes missing daily outputs, and reuses valid outputs. The ERA5-Land job uses its existing `--execute` path. Weekly aggregation is submitted only with `afterok:<all five source job IDs>` and uses the exact same common start/end dates. Four standalone aggregation jobs and one ERA5-Land aggregate-only family job then run concurrently. Portfolio validation depends on all aggregation jobs and checks synchronized daily dates, complete ISO weeks, raster geometry, sidecars/provenance, value ranges, and ERA5-Land support-mask behavior.

The durable parent record is `runs/production/_portfolio/<run_id>/portfolio_manifest.json`. It records requested and resolved dates, source/installed commits, source and aggregation job IDs, dependency strings, per-product expected/present/missing counts, complete-week count, and final status. Submission status is not success: `validation_submitted` means Slurm accepted the validator but it has not been observed running; `validation_running` means the validator has started; `success` requires all source work, all aggregation work, and final validation. If a child fails or a dependent validator is cancelled, inspect the normal run manifests and Slurm logs, then use the optional reconciliation utility with the same external root. Valid TIFFs are reused; ordinary updates do not use `--overwrite`. The validated portfolio baseline is run `20260831T181051Z_portfolio`, through 2026-07-26 with 238 complete ISO weeks and 12 products.

For a CHIME-triggered portfolio, the wrapper receives optional
`CHIME_EXECUTION_ID` and persists it as the top-level
`portfolio_manifest.json -> chime_execution_id` field. It is provenance only
and does not change workflow behavior. Without the environment variable, new
manifests write `chime_execution_id: null`; independently launched runs need
no CHIME dependency.

## Portfolio recovery

1. For a source/package commit mismatch, run `bash hpc/install_cdsdatagrab_atlas.sh "$REPO_DIR"` and then `Rscript "$REPO_DIR/hpc/preflight_cdsdatagrab.R"`; execution is allowed only when the checkout and installed-package commits agree.
2. For a failed dependency chain, inspect each source and aggregation manifest plus its Slurm log. A validator cancelled by `afterok` is not evidence that validation ran.
3. Locate the newest portfolio manifest with `find "$ROOT/runs/production/_portfolio" -name portfolio_manifest.json -printf '%T@ %p\n' | sort -nr | head -n 1`.
4. Distinguish `validation_submitted` (accepted/pending), `validation_running`, `cancelled` (Slurm stopped the job before completion), `failed`, and `success` (validator completed and wrote the manifest). Run `Rscript scripts/reconcile_portfolio_manifest.R --manifest PATH` to inspect recorded job states; add `--apply` to record a terminal cancellation/failure after review.
5. Rerun the portfolio update with the same production root. Valid TIFFs and sidecars are reused, no ordinary update uses `--overwrite`, and status reconciliation is optional rather than a prerequisite for successful execution.

## Planning, staging, retrieval, processing, and aggregation

The ERA5-Land wrapper requires exactly one of these options:

```bash
export CONFIG=config/era5land_daily_mean_utc06_production.yml
export ROOT=/project/disease_ecology/cds-datagrab-output

# Read-only plan: no CDS contact and no Slurm submission.
bash hpc/submit_era5land_daily_mean.sh --config "$CONFIG" --output-root "$ROOT" --dry-run

# Submit missing monthly CDS jobs and persist their registry rows.
bash hpc/submit_era5land_daily_mean.sh --config "$CONFIG" --output-root "$ROOT" --stage-requests

# Submit a retrieval pass for registered jobs that may now be available.
bash hpc/submit_era5land_daily_mean.sh --config "$CONFIG" --output-root "$ROOT" --retrieve-requests

# Process validated local archives only; no CDS contact.
bash hpc/submit_era5land_daily_mean.sh --config "$CONFIG" --output-root "$ROOT" --process

# Submit the wrapper's full acquisition/processing workflow.
bash hpc/submit_era5land_daily_mean.sh --config "$CONFIG" --output-root "$ROOT" --execute
```

The direct R entry point supports the complete current mode set:

```bash
Rscript scripts/run_era5land_daily_mean.R --help
Rscript scripts/run_era5land_daily_mean.R --config config/era5land_daily_mean_utc06_weekly_smoke.yml --output-root /project/disease_ecology/cds-datagrab-smoke-output --mode aggregate --dry-run false --start-date 2026-02-02 --end-date 2026-02-08
```

`aggregate` is the explicit weekly-capable mode. The shell wrapper has no separate aggregate flag; use the R mode after local source acquisition when a distinct weekly pass is required.

The generic annual dispatcher accepts only `plan` and `execute`:

```bash
bash hpc/submit_product_year.sh --product era5land_daily_mean_utc06 --year 2025 --mode plan --output-root "$ROOT"
```

## Monitoring and validation

```bash
squeue -u "$USER"
find "$ROOT/runs/production" -name run_manifest.json -print
find "$ROOT/data/production" -path '*/daily/*.tif' | wc -l
find "$ROOT/data/production" -path '*/weekly/*.tif' | wc -l
Rscript scripts/audit_output_layout.R --output-root "$ROOT" --profile production --product era5land_tmean
```

Inspect the request registry at `data/production/_sources/era5land_daily_mean_utc06/requests/request_registry.csv`, the source run manifest, each product run manifest, `source_diagnostic.json`, inventories, and Slurm logs. Require successful final validation, zero failed product/dates, and a successful pipeline status before treating a run as complete.

## Recovery and reuse

1. Inspect the request registry and the latest run manifest; identify the failed stage and missing product/date outcomes.
2. Confirm the same production root, profile, source commit, and installed commit.
3. If all 55 monthly archives are valid locally, rerun `--process` or the direct R processing/aggregate mode. Do not repeat stage/retrieve merely to resume local processing.
4. Rely on complete-month fast-forward and complete-product `reused_complete` behavior. Existing valid daily TIFFs and request-specific sidecars are reused.
5. Avoid `--overwrite` during ordinary recovery. Never delete valid TIFFs or the shared source archives.

The historical ERA5-Land process/full Slurm wrappers allocate 72 hours. Staging and retrieval are separate operations and can be repeated only when the registry shows missing or still-pending source requests. A complete request is not reopened solely because another product/date needs repair.

## Provenance sidecar repair

```bash
Rscript scripts/repair_era5land_daily_sidecar_provenance.R \
  --config "$CONFIG" --output-root "$ROOT" \
  --start-date 2022-03-01 --end-date 2022-03-31

Rscript scripts/repair_era5land_daily_sidecar_provenance.R \
  --config "$CONFIG" --output-root "$ROOT" \
  --start-date 2022-03-01 --end-date 2022-03-31 --apply
```

The default is an audit/dry-run. Apply mode atomically changes only whitelisted provenance fields in date-scoped sidecars, never rewrites TIFFs, retains `diagnostics/era5land_daily_sidecar_provenance_repair.csv`, and is resumable/idempotent. Ambiguous date-to-request or product-to-member mappings are reported as failures rather than guessed.

For legacy daily TIFFs with missing sidecars, `scripts/backfill_daily_sidecars.R` is a separate maintenance utility. It validates existing rasters, reports planned repairs by default, and writes only metadata sidecars with `--apply`; use explicit `--start-date` and `--end-date` scopes. It repairs metadata rather than raster values and is not part of routine portfolio updates.

## Smoke acceptance

Use the actual wrapper options; do not set an unsupported `MODE=full` shortcut:

```bash
export CONFIG=config/era5land_daily_mean_utc06_smoke.yml
export ROOT=/project/disease_ecology/cds-datagrab-smoke-output
export START_DATE=2026-02-01 END_DATE=2026-02-03
bash hpc/submit_era5land_daily_mean.sh --config "$CONFIG" --output-root "$ROOT" --dry-run
bash hpc/submit_era5land_daily_mean.sh --config "$CONFIG" --output-root "$ROOT" --execute
```

For a complete-week validation, use `config/era5land_daily_mean_utc06_weekly_smoke.yml`, set `START_DATE=2026-02-02` and `END_DATE=2026-02-08`, and use the direct R `--mode aggregate` path after the source archive is locally available. The expected target is seven daily rasters and one weekly mean per product; an identical rerun should reuse valid artifacts and make no new CDS request.

For one product/date before a broad family rerun, use:

```bash
Rscript scripts/debug_era5land_slice.R \
  --config config/era5land_daily_mean_utc06_smoke.yml \
  --product era5land_tmean --date 2026-02-01 --output-root "$ROOT"
```

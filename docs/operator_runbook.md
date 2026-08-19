# Operator runbook

When both bilinear and same-cell nearest are missing, the bounded local donor search checks radius one and then radius two target-grid cells, using full template cell numbers from original finite projected values and at most eight inverse-distance donors. Singleton gaps without target-grid support then use only intersecting finite source-grid footprints or a source-space buffer no wider than 35 km; unsupported cells remain unresolved as `no_source_land_support`. It records target/source support, actual cell/km distances, and explicit failure reasons. Components are repaired atomically: if any cell lacks an accepted donor, no cell in that component is finalized. Before repeating all 24 product-date combinations, run `Rscript scripts/debug_era5land_slice.R --config config/era5land_daily_mean_utc06_smoke.yml --product era5land_tmean --date 2026-02-01 --output-root /project/disease_ecology/cds-datagrab-smoke-output`.

## ERA5-Land coverage repair

ERA5-Land processing retains unmasked bilinear and nearest-neighbour projections, classifies missing template cells before masking, and repairs only projection-created 8-neighbour components of at most four cells, subject to configured count/fraction limits. The explicit support mask is `spatial_domain/derived/era5land_support_mask.tif`, derived from the protected `spatial_domain/study_area_raster.tif` and the audited `spatial_domain/derived/era5land_unsupported_cells.csv`. It excludes exactly cells 28012, 35085, and 35964, whose nearest finite source cells are beyond the bounded 35 km source-support threshold. The master template is never edited, the local radius remains two cells, and the source buffer is never expanded to make those cells pass. Source-nodata and larger supported components remain failures. Daily sidecars and run diagnostics record master-template cells, supported cells, structural exclusions, pre-repair missing supported cells, repaired supported cells, unexpected post-repair missing cells, outside-support finite cells, outside-mask cells, component sizes, and source/projection classifications.

The structural exclusions are not product/date failures: a daily or weekly raster may remain `NA` at those three cells, while every supported template cell must be finite. Any new mask `NA` outside the audited cell list, any finite value outside the master template, or any changed audit provenance is rejected. Weekly means therefore preserve structural `NA`s and still require all seven daily values at every supported cell.

Run one product and one calendar year at a time. Keep the shared production root for all products and years. Plan first, inspect the manifest, then execute.

## Common setup

```bash
export REPO_DIR=/project/disease_ecology/cds-datagrab
export CDS_DATAGRAB_R_LIB=/project/disease_ecology/cds-datagrab-r-library/4.5
export HOME_R_LIB=/home/john.humphreys/R/x86_64-pc-linux-gnu-library/4.5
export R_LIBS_USER="${CDS_DATAGRAB_R_LIB}:${HOME_R_LIB}"
unset R_LIBS_SITE ALLOW_MULTIYEAR
module purge; module load r/4.5 udunits gdal proj geos git
bash hpc/install_cdsdatagrab_atlas.sh "$REPO_DIR"
REPO_DIR="$REPO_DIR" Rscript hpc/preflight_cdsdatagrab.R
```

## Product matrix

| Product | Root | Config | Wrapper | Annual expected dates / requests |
|---|---|---|---|---|
| `era5_mintemp` | `/project/disease_ecology/cds-datagrab-output` | `config/era5_mintemp_production.yml` | `hpc/submit_era5_mintemp.sh` | 365/366, 12 |
| `era5_soilmoist` | `/project/disease_ecology/cds-datagrab-output` | `config/era5_soilmoist_production.yml` | `hpc/submit_era5_soilmoist.sh` | 365/366, 12 |
| `era5_lai_low` | `/project/disease_ecology/cds-datagrab-output` | `config/era5_lai_low_production.yml` | `hpc/submit_era5_lai_low.sh` | 365/366, 12 |
| `agera5_relhum_min` | `/project/disease_ecology/cds-datagrab-output` | `config/agera5_relhum_min_production.yml` | `hpc/submit_agera5_relhum_min.sh` | 365/366, 12 |

The 2024 annual window has 366 days; 2022, 2023, 2025, and 2026 have 365 configured days. The effective observed 2026 endpoint is determined by the configured product availability and is recorded in the manifest.

## Annual plan and execution

Replace `PRODUCT`, `YEAR`, and `ROOT` with one row from the table:

```bash
bash hpc/submit_product_year.sh --product PRODUCT --year YEAR --mode plan --output-root ROOT
bash hpc/submit_product_year.sh --product PRODUCT --year YEAR --mode execute --output-root ROOT
```

The dispatcher sets `PROFILE=production`, `START_DATE=YEAR-01-01`, and `END_DATE=YEAR-12-31`. For an incomplete current year, pass an explicit earlier observed endpoint through the product wrapper with `OBSERVED_END`; never submit unavailable dates.

## Monitoring and validation

```bash
squeue -u "$USER"
tail -f "$ROOT/logs/slurm/production/<product>_%j.out"
find "$ROOT/runs/production/<product>" -name run_manifest.json -print
find "$ROOT/data/production/<product>/daily" -name '*.tif' | wc -l
find "$ROOT/data/production/<product>/weekly" -name '*.tif' | wc -l
```

Inspect the latest `run_manifest.json` and require `pipeline_status: success`, final validation success, and zero daily/weekly failures. Keep successful raw files and outputs when retrying a failed month. A rerun reuses valid artifacts.

ERA5-Land `--process` is restartable. A complete monthly request is validated and
fast-forwarded without reading NetCDF members; within an incomplete request, complete
products are fast-forwarded and only missing/invalid products are processed. Existing
valid daily TIFFs and their request-specific sidecars are reused and are not overwritten
unless `--overwrite` is explicitly supplied. The two historical ERA5-Land process/full
Slurm wrappers allocate 72 hours; staging and retrieval remain separate operations.

For sidecars produced before request-scoped annotation, run
`scripts/repair_era5land_daily_sidecar_provenance.R` first without `--apply` to audit
the proposed repair. Apply mode updates only whitelisted provenance fields atomically,
never writes TIFFs, and records an audit CSV. Do not rerun stage/retrieve solely because
local processing is being restarted.

## Safe rerun

1. Confirm the source and installed commits match.
2. Confirm the same product root and production profile.
3. Review the failed stage and request manifest.
4. Re-run the annual plan.
5. Execute only after confirming missing/invalid inputs.

Do not delete the production root to recover from a partial failure.

## Operational checklist

Load the Atlas modules and libraries shown in `README.md`, run the credential-presence check without printing `ecmwfr_PAT`, and run `hpc/preflight_cdsdatagrab.R` before submission. The preflight compares the source checkout commit with `.cds-datagrab-installed-commit`. Select `/project/disease_ecology/cds-datagrab-output` for production and `/project/disease_ecology/cds-datagrab-smoke-output` for smoke; use `hpc/submit_product_year.sh --mode plan` before the explicit `--mode execute`.

Monitor with `squeue`, inspect `runs/production/<product>/<run_id>/run_manifest.json`, and rerun only missing or invalid work. Transient CDS failures should be retried from a new plan; valid raw, daily, and weekly products are reusable. Audit the shared root read-only with:

```bash
Rscript scripts/audit_output_layout.R --output-root /project/disease_ecology/cds-datagrab-output --profile production
```

Smoke outputs are disposable only after validation records are preserved. The initializer is dry-run by default: `bash hpc/init_output_root.sh --root /absolute/path --profile smoke`, adding `--execute` only after reviewing the printed paths. Never delete configuration, fixtures, source, or the spatial template. A new product must follow [adding_products.md](adding_products.md), including registry, reader/decoder, filename, inventory, smoke, production, dispatcher, and reuse tests.

## ERA5-Land daily-mean smoke acceptance

All wrappers resolve the profile from `project.profile` in the YAML configuration. If `PROFILE` is supplied explicitly, it must match the configuration profile; the configuration filename is not used for profile inference.

The family request is one monthly response containing eight variables. CDS may return a ZIP containing eight separate NetCDF members, one per source variable. The pipeline detects the container by magic bytes, extracts into the shared request cache, maps each member to its registered alias, and does not apply a second UTC−6 shift to `valid_time` labels. Do not manually unzip or rename operational inputs. The first Atlas smoke is a three-day dry plan/execute sequence:

```bash
export REPO_DIR=/project/disease_ecology/cds-datagrab
export CDS_DATAGRAB_ROOT=/project/disease_ecology/cds-datagrab-smoke-output
export PROFILE=smoke CONFIG=config/era5land_daily_mean_utc06_smoke.yml
export START_DATE=2026-02-01 END_DATE=2026-02-03
DRY_RUN=true  bash hpc/submit_era5land_daily_mean.sh
DRY_RUN=false MODE=full bash hpc/submit_era5land_daily_mean.sh
```

Expected validation is one raw February bundle, eight variables, three daily rasters per product (24 total), zero daily failures, and no required complete weekly output. Extend the same root and February bundle through the complete week:

```bash
export CONFIG=config/era5land_daily_mean_utc06_weekly_smoke.yml
export START_DATE=2026-02-02 END_DATE=2026-02-08
DRY_RUN=true  bash hpc/submit_era5land_daily_mean.sh
DRY_RUN=false MODE=full bash hpc/submit_era5land_daily_mean.sh
```

This should reuse or safely extend the raw bundle, produce seven valid daily rasters and one weekly mean per product, and make an identical rerun perform zero CDS requests. The production dispatcher is additive: `bash hpc/submit_product_year.sh --product era5land_daily_mean_utc06 --year 2025 --mode plan` plans 12 shared monthly requests; individual ERA5-Land product identifiers reuse the same source family.

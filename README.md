<p align="center">
  <img src="images/datagrab_hex.png" width="350" alt="hex sticker">
</p>
  
  
# cds-datagrab

`cds-datagrab` is a reproducible R-package workflow for retrieving environmental data from the Copernicus Climate Data Store (CDS), aligning source data to the protected study-area template, writing daily GeoTIFFs, and aggregating complete ISO weeks.

The workflow keeps raw CDS responses, extracted source files, template-aligned daily rasters, weekly rasters, inventories, run manifests, and Slurm logs separate. Raw and derived products are resumable and are never written into the Git checkout.

## Storage layout

Production root: `/project/disease_ecology/cds-datagrab-output`
Smoke root: `/project/disease_ecology/cds-datagrab-smoke-output`

```text
<root>/
├── data/<profile>/<product_id>/
├── runs/<profile>/<product_id>/<run_id>/
└── logs/slurm/<profile>/
```

All products share one root and are separated below `data/<profile>/`. Current product identifiers are `era5_mintemp`, `era5_soilmoist`, `era5_lai_low`, and `agera5_relhum_min`. New variables receive new product directories, not new top-level roots. Production and smoke data are separated by root and profile; annual reruns reuse valid raw, daily, and weekly products. Historical manifests may contain former absolute paths, but old product-specific roots are retired and must not be used in new commands.

## Supported products

| Product | CDS dataset / variable | Source → output units | Daily meaning | Weekly rule | Production configuration / wrapper |
|---|---|---|---|---|---|
| ERA5 minimum temperature | `derived-era5-single-levels-daily-statistics` / `2m_temperature` | K → °C | CDS daily minimum from 6-hourly data | cellwise minimum of 7 observed days | `config/era5_mintemp_production.yml` / `hpc/submit_era5_mintemp.sh` |
| ERA5 soil moisture | `derived-era5-single-levels-daily-statistics` / `volumetric_soil_water_layer_1` | m³ m⁻³ → m³ m⁻³ | CDS daily mean, layer 1 | cellwise mean of 7 observed days | `config/era5_soilmoist_production.yml` / `hpc/submit_era5_soilmoist.sh` |
| ERA5 low-vegetation LAI | `reanalysis-era5-single-levels` / `leaf_area_index_low_vegetation` (`lai_lv`) | m² m⁻² (dimensionless source accepted) → m² m⁻² | 00:00 UTC monthly-climatology observation | cellwise mean of 7 observed days | `config/era5_lai_low_production.yml` / `hpc/submit_era5_lai_low.sh` |
| AgERA5 minimum RH | `sis-agrometeorological-indicators` / `2m_relative_humidity_derived` | % → % | precomputed 24-hour local-time minimum | cellwise mean of 7 observed days | `config/agera5_relhum_min_production.yml` / `hpc/submit_agera5_relhum_min.sh` |

ERA5 direct NetCDF is read with `ncdf4`; AgERA5 ZIP members are safely extracted and read with the same backend when Atlas GDAL cannot open NetCDF. See [the output reference](docs/output_schema.md) for field-level provenance.

## Production period and annual execution

The canonical configured range is **2022-01-01 through 2026-12-31**. Production execution is one calendar year at a time using the same product-specific output root. The configured horizon is not the same as the effective observed-data endpoint: unavailable future dates are recorded as future/unavailable and are not submitted to CDS.

Annual windows may narrow, but never expand, the configured range. A non-dry-run window spanning multiple years is rejected unless `ALLOW_MULTIYEAR=true`; annual execution is the safe default. The first and final boundary ISO weeks are not fabricated: weekly products require seven in-range daily rasters.

## Atlas installation and prerequisites

Tested Atlas setup:

```bash
module purge
module load r/4.5 udunits gdal proj geos git
export CDS_DATAGRAB_R_LIB=/project/disease_ecology/cds-datagrab-r-library/4.5
export HOME_R_LIB=/home/john.humphreys/R/x86_64-pc-linux-gnu-library/4.5
export R_LIBS_USER="${CDS_DATAGRAB_R_LIB}:${HOME_R_LIB}"
unset R_LIBS_SITE
```

Required package dependencies are listed in `DESCRIPTION`; the runtime preflight additionally verifies `terra`, `sf`, `ISOweek`, `ncdf4`, and `ecmwfr` where required. Install the package outside the checkout:

```bash
export REPO_DIR=/project/disease_ecology/cds-datagrab
bash hpc/install_cdsdatagrab_atlas.sh "$REPO_DIR"
REPO_DIR="$REPO_DIR" Rscript hpc/preflight_cdsdatagrab.R
git -C "$REPO_DIR" rev-parse HEAD
cat "$CDS_DATAGRAB_R_LIB/.cds-datagrab-installed-commit"
```

The source and installed commits must match before production execution.

## CDS credentials

An active CDS account and credential are required for execution. Export `ecmwfr_PAT` securely, for example from `~/.Renviron`, and check presence without printing the value:

```bash
Rscript - <<'RS'
token <- Sys.getenv("ecmwfr_PAT", unset = "")
stopifnot(nzchar(token))
cat("CDS credential is available.\n")
RS
```

Never commit, paste, log, or place the credential value in YAML. Planning mode does not contact CDS.

## Plan, execute, validate

For a first LAI production year:

```bash
export CDS_DATAGRAB_ROOT=/project/disease_ecology/cds-datagrab-output
export CONFIG=config/era5_lai_low_production.yml PROFILE=production
export START_DATE=2022-01-01 END_DATE=2022-12-31
unset ALLOW_MULTIYEAR

DRY_RUN=true  bash hpc/submit_era5_lai_low.sh   # planning only
DRY_RUN=false bash hpc/submit_era5_lai_low.sh   # execution
```

Inspect the run manifest, `planned_dates.csv`, request manifests, raw/daily/weekly inventories, and Slurm logs before proceeding to the next year. A genuine success has Slurm `COMPLETED`, exit code `0:0`, zero daily and weekly failures, final validation `success`, and pipeline status `success`.

The generic dispatcher is convenient for annual work and defaults to planning:

```bash
bash hpc/submit_product_year.sh --product era5_lai_low --year 2024 --mode plan \
  --output-root /project/disease_ecology/cds-datagrab-output
```

Use `--mode execute` only after inspecting the plan. See [docs/operator_runbook.md](docs/operator_runbook.md) for all products, annual windows, monitoring, and safe reruns.

## Resume and troubleshooting

Valid matching raw files, daily rasters, and weekly rasters are reused. A failed month can be retried without deleting successful months; a rerun requests only missing or invalid inputs. The same output root must be retained across annual chunks so inventory and ISO-week completion can work.

Common causes and remedies:

- CDS HTTP/2 or transport failure: retain successful months and rerun the failed plan; do not delete the root.
- `.netcdf` versus `.nc`: both are supported case-insensitively; content validation determines the reader.
- Missing GDAL NetCDF support: expected on some Atlas nodes; use the ncdf4 preflight/backend.
- Missing packages: restore the external library and preserve the home library in `R_LIBS_USER`.
- Commit mismatch: rerun `hpc/install_cdsdatagrab_atlas.sh`.
- Smoke logs for production: set `PROFILE=production`; wrappers reject profile/config conflicts.
- Multi-year guard: submit one calendar year or explicitly review `ALLOW_MULTIYEAR=true`.
- Incomplete boundary week or unavailable future dates: expected; do not fabricate or submit out-of-window dates.
- Output-root safety error: use an external shared root, never the repository checkout.

See [docs/output_schema.md](docs/output_schema.md), [docs/operator_runbook.md](docs/operator_runbook.md), and [docs/production_validation_summary.md](docs/production_validation_summary.md).

# CDS availability and production update validation

**Retrieval verification:** 2026-11-11
**Production validation run:** `20261112T013707Z_portfolio`
**Decision:** `UPDATE_READY`
**Production endpoint:** 2026-11-03
**Source/install commit used by the production run:** `9a07372acec9c69d6f34859ff96ace866c25d633`

## Verified CDS endpoints

The established authenticated R `ecmwfr` interface retrieved and validated observations. Credentials were loaded through the configured secure Atlas source; the PAT value was never displayed or recorded.

| Source workflow | Latest verified date | Evidence |
|---|---:|---|
| `era5_mintemp` | 2026-11-03 | Returned observation and configured minimum-temperature variable validated |
| `era5_soilmoist` | 2026-11-03 | Returned observation and configured soil-moisture variable validated |
| `era5_lai_low` | 2026-11-03 | Returned observation and configured variable validated |
| `agera5_relhum_min` | 2026-11-03 | Returned observation and configured relative-humidity variable validated |
| `era5land_daily_mean_utc06` | 2026-11-05 | Shared request returned all eight configured variables; the common portfolio endpoint is 2026-11-03 |

The common endpoint supported by all five source workflows is **2026-11-03 (VERIFIED)**. The existing production request definitions, temporal semantics, spatial templates, transformations, and output naming were retained.

## Production update and validation

The exact update command was `bash hpc/submit_all_products.sh --through 2026-11-03 --mode update`. Portfolio run `20261112T013707Z_portfolio` completed with `status: success` in the authoritative manifest at `runs/production/_portfolio/20261112T013707Z_portfolio/portfolio_manifest.json`.

- 12 products have validated daily coverage from 2022-01-01 through 2026-11-03: 1,768 expected/present per product, with no missing dates.
- 12 products have 252 complete weekly outputs through 2026-W44 (week ending 2026-11-01), with no missing weeks.
- Relative to the validated 2026-10-01 inventory (1,735 daily and 247 weekly outputs per product), the completed update added 33 daily observations and 5 weekly outputs per product (396 daily and 60 weekly outputs total). Four full incremental ISO weeks, W41–W44, were planned; W40 is the additional boundary-week output. Final coverage is 252 complete weeks per product through W44.
- Existing valid artifacts were reused. No overwrite or historical rebuild was used; validated historical TIFFs remained unchanged.
- Five source jobs (`21203198`–`21203202`), five aggregation jobs (`21203203`–`21203207`), and validator `21203208` all completed with exit code 0.

An earlier portfolio attempt, `20261111T235706Z_portfolio`, stopped at the ERA5-Land source because its `full` path processed only the October request. Recovery job `21203060` successfully processed the already cached ERA5-Land archive for the missing November dates without contacting CDS or rewriting existing outputs. The final portfolio rerun reused valid products and passed the complete dependency chain.

CHIME's read-only `cds-datagrab` workflow status reports `current` for run `20261112T013707Z_portfolio`, with all 12 products at the validated endpoint.

## Production update command

The completed update used:

```bash
bash hpc/submit_all_products.sh --through 2026-11-03 --mode update
```

The next update should begin with `--mode plan` and use `--through latest-common`.

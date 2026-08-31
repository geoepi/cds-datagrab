# Production validation summary

This document records the current validated production portfolio conservatively. It does not treat the configured future horizon as observed data, and it does not claim any endpoint after the validated run below.

## Validated portfolio production

The full production portfolio completed successfully on Atlas. The stable portfolio run `20260831T181051Z_portfolio` is the current validation evidence:

| Measure | Validated result |
|---|---:|
| ERA5-Land products | 8 |
| Standalone products | 4 |
| Portfolio products | 12 |
| Complete ISO weeks per product | 238 |
| Products passed sidecar, geometry, and weekly validation | 12 |
| ERA5-Land daily TIFFs per product | 1,668 |
| ERA5-Land daily TIFFs total | 13,344 |
| Validated/produced endpoint | 2026-07-26 |
| Configured horizon | 2022-01-01 through 2026-12-31 |

The five production source-workflow configurations now agree on `temporal.observed_end = 2026-07-26`. This is the latest operator-confirmed available/produced endpoint, not a calendar-derived forecast. The configured hard horizon remains 2026-12-31; dates after 2026-07-26 are not validated.

The eight outputs are additive to the established standalone products `era5_mintemp`, `era5_soilmoist`, `era5_lai_low`, and `agera5_relhum_min`. All ERA5-Land outputs use the shared `era5land_daily_mean_utc06` source family and one monthly `derived-era5-land-daily-statistics` request containing eight variables, with `daily_mean`, `utc-06:00`, and `1_hourly` request settings.

## Portfolio orchestration status

Portfolio orchestration has been exercised successfully on Atlas across the full dependency chain: source workflows → weekly aggregation → portfolio validation. The operator entry point is:

```bash
bash hpc/submit_all_products.sh --through latest-common --mode plan
bash hpc/submit_all_products.sh --through latest-common --mode update
```

It submits five independent source workflows concurrently, then submits dependent weekly aggregation and final synchronization validation jobs. The parent manifest under `runs/production/_portfolio/<run_id>/` records the job IDs, common endpoint, complete ISO-week count, per-product coverage, and final status. The successful run confirmed sidecars, geometry, weekly validation, and synchronized cumulative inventories for all 12 products.

## Restart and recovery validation

Validated behavior includes:

- complete monthly requests fast-forward without reopening source archives;
- complete products within incomplete requests fast-forward independently;
- missing product dates can be processed without rewriting complete products;
- valid daily TIFFs and request-specific sidecars are reused;
- processing is resumable; and
- production provenance sidecars can be audited/repaired without rewriting TIFFs.

A March 2022 soil-water layer 1 recovery test processed 31 missing daily TIFFs for `era5land_soilwater_l1_mean`, while the other seven products were `reused_complete`. A second identical run performed complete-month fast-forward with `written=0`, `reused=248`, and `status=success`.

The historical `era5_mintemp` sidecar repair is completed recovery evidence: 1,668 daily TIFFs were checked and 1,668 missing daily sidecars were written without rewriting raster values. `scripts/backfill_daily_sidecars.R` is a maintenance utility only. It defaults to a dry-run, `--apply` writes metadata sidecars for a scoped date range, and it must not be invoked for routine portfolio updates.

## Provenance repair validation

Historical sidecar provenance repair was applied and validated with:

```text
examined=2585
already_correct=2585
needs_repair=0
ambiguous=0
missing_sidecar=0
failed=0
```

TIFF checksums before and after repair were identical. The repair utility is date/request scoped, defaults to dry-run, updates only whitelisted sidecar fields under `--apply`, writes no TIFFs, fails ambiguous mappings rather than guessing, and retains an audit CSV in the output-root diagnostics directory.

## Coverage and validation safeguards

ERA5-Land coverage repair is bounded and auditable. It uses original finite projected donors, at most four cells per repair component, local target radius two, up to eight inverse-distance donors, and a source fallback no wider than 35 km. Three structural source-absence cells are represented by `spatial_domain/derived/era5land_support_mask.tif` and excluded from daily/weekly completeness checks without modifying the master template. Supported-cell gaps, larger components, invalid-range candidates, and incomplete donor support remain failures.

The source-value validator tolerates only floating-point noise at finite hard bounds using an absolute tolerance of `1e-10`; the scientific volumetric soil-water range remains exactly `[0, 1]`. Values within tolerance are normalized to the boundary, while material violations fail. The reader result retains raw and normalized extrema and source clamp counts; current daily sidecars persist the normalized source extrema as `source_minimum` and `source_maximum`.

NetCDF/read failures preserve the original condition class, message, call, and bounded traceback/call-stack details. If secondary failure bookkeeping fails, that diagnostic error is recorded separately and does not replace the original reader error.

## Related validation references

The protected template checksum remains:

```text
4BE01F0ECAFF35216A72EB8F27E791311AF90D35B5A4FFF1E46A74EDB6DC633B
```

See [the output schema](output_schema.md), [the operator runbook](operator_runbook.md), and [the staged request lifecycle](era5land_request_lifecycle.md) for field-level and operational details. Exact ephemeral Atlas job IDs are intentionally omitted.

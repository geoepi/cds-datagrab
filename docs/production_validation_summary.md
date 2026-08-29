# Production validation summary

This document records the validated ERA5-Land daily-mean production state conservatively. It does not treat the configured future horizon as observed data, and it does not report weekly production as complete.

## Validated daily production

The ERA5-Land daily-mean family completed historical daily production successfully on Atlas. The final validated inventory is:

| Measure | Validated result |
|---|---:|
| ERA5-Land products | 8 |
| Daily TIFFs per product | 1,654 |
| Daily TIFFs total | 13,232 |
| Produced/observed daily period | 2022-01-01 through 2026-07-12 |
| Configured horizon | 2022-01-01 through 2026-12-31 |

The configured horizon is retained in the production YAML, but dates after 2026-07-12 are not claimed as observed or produced. Weekly aggregation has not been started in this production pass. For the currently produced daily period, the expected complete-week validation target is 237 ISO weeks per product and 1,896 weekly TIFFs total.

The eight outputs are additive to the established standalone products `era5_mintemp`, `era5_soilmoist`, `era5_lai_low`, and `agera5_relhum_min`. All ERA5-Land outputs use the shared `era5land_daily_mean_utc06` source family and one monthly `derived-era5-land-daily-statistics` request containing eight variables, with `daily_mean`, `utc-06:00`, and `1_hourly` request settings.

## Portfolio orchestration status

The thin portfolio orchestration layer is implemented but is not represented as Atlas-validated production evidence in this document. A real Atlas portfolio run must complete before the command is described as validated. The operator entry point is:

```bash
bash hpc/submit_all_products.sh --through latest-common --mode plan
bash hpc/submit_all_products.sh --through latest-common --mode update
```

It submits five independent source workflows concurrently, then submits dependent weekly aggregation and final synchronization validation jobs. The parent manifest under `runs/production/_portfolio/<run_id>/` records the job IDs, common endpoint, complete ISO-week count, per-product coverage, and final status. Until that run is completed, the existing ERA5-Land daily-only Atlas evidence above remains distinct from portfolio-level validation.

## Restart and recovery validation

Validated behavior includes:

- complete monthly requests fast-forward without reopening source archives;
- complete products within incomplete requests fast-forward independently;
- missing product dates can be processed without rewriting complete products;
- valid daily TIFFs and request-specific sidecars are reused;
- processing is resumable; and
- production provenance sidecars can be audited/repaired without rewriting TIFFs.

A March 2022 soil-water layer 1 recovery test processed 31 missing daily TIFFs for `era5land_soilwater_l1_mean`, while the other seven products were `reused_complete`. A second identical run performed complete-month fast-forward with `written=0`, `reused=248`, and `status=success`.

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

# Production validation summary

This document records the latest validated production portfolio. Configured future dates are not treated as observed data.

## Validated portfolio production

The latest successful Atlas portfolio run is `20261112T013707Z_portfolio`, requested through **2026-11-03**. Its manifest is `/project/disease_ecology/cds-datagrab-output/runs/production/_portfolio/20261112T013707Z_portfolio/portfolio_manifest.json` and records `status: success`. The run used source and installed-package commit `9a07372acec9c69d6f34859ff96ace866c25d633`.

| Measure | Validated result |
|---|---:|
| ERA5-Land products | 8 |
| Standalone products | 4 |
| Portfolio products | 12 |
| Daily observations per product | 1,768 |
| Total daily observations | 21,216 |
| Latest validated daily observation | 2026-11-03 |
| Complete ISO weeks per product | 252 |
| Latest complete ISO week | 2026-W44 (ends 2026-11-01) |
| Products passed daily, weekly, sidecar, geometry, and portfolio validation | 12 |
| Configured hard horizon | 2022-01-01 through 2026-12-31 |

All five CDS source workflows have retrieval evidence through 2026-11-03. The shared ERA5-Land source was verified through 2026-11-05 with all eight configured variables. Production configuration `temporal.observed_end` is now 2026-11-03 for all five source workflows; dates after that endpoint remain unvalidated.

Relative to the validated 2026-10-01 inventory (1,735 daily and 247 weekly outputs per product), the completed update added 33 daily observations and 5 weekly outputs per product (396 daily and 60 weekly outputs total). Four full incremental ISO weeks, W41–W44, were planned; W40 is the additional boundary-week output. Final coverage is 252 complete weeks per product through W44. Existing valid outputs were reused, no overwrite or historical rebuild was performed, and historical TIFFs remained unchanged.

The portfolio dependency chain completed: five source jobs (`21203198`–`21203202`), five aggregation jobs (`21203203`–`21203207`), and validator `21203208`. All 11 jobs completed with exit code 0; the portfolio validator reported success. The source jobs reused existing verified artifacts where present. CHIME's read-only `cds-datagrab` status adapter reports the portfolio as current through 2026-11-03.

## Portfolio orchestration status

Portfolio orchestration has completed successfully on Atlas across the full dependency chain: source workflows → weekly aggregation → portfolio validation. The operator entry point remains:

```bash
bash hpc/submit_all_products.sh --through latest-common --mode plan
bash hpc/submit_all_products.sh --through latest-common --mode update
```

The parent manifest records the common endpoint, job IDs, dependency strings, per-product expected/present/missing counts, complete-week count, and final status. A submitted job is not success: only successful source and aggregation work followed by successful final validation establishes a completed portfolio.

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

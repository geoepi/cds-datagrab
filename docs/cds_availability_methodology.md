# CDS availability audit methodology

Audit timestamp: 2026-11-11T15:31:58Z
Atlas checkout inspected: /project/disease_ecology/cds-datagrab, branch main, commit b5315a71793d700313a1c257125892079e03d854
Production root inspected: /project/disease_ecology/cds-datagrab-output

## Evidence hierarchy

1. **Configured request definition** — the production portfolio, workflow YAML, variable registry, and request builder define dataset, variable, statistic, frequency, time zone, version, output format, area derivation, and monthly request chunking.
2. **CDS collection metadata** — STAC temporal extent, publication/update timestamp, update frequency, sanity status, DOI, and description establish what CDS advertises. They do not establish a successful retrieval.
3. **Request constraints** — the machine-readable constraints relation is checked by the reusable implementation against configured selections and candidate calendar fields. Date-specific acceptance is recorded only when year, month, and day are explicitly admissible. This audit did not retrieve constraint payloads, so no date is reported as accepted by constraints.
4. **Bounded retrieval evidence** — the implementation can submit one configured date request per source, store it only under an isolated temporary root, inspect the date coordinate and every configured variable, and backtrack up to three days by default. Retries are bounded to three attempts and honor a numeric Retry-After value when supplied. An accepted request without a complete artifact remains unverified.

## What ran for this audit

Public CDS STAC metadata were reviewed for the four unique collections used by five workflows. Two workflows share the ERA5 daily-statistics collection, so that collection is queried once and its metadata is associated with both configured request definitions.

The Atlas credential-presence check found neither ecmwfr_PAT nor ~/.cdsapirc, and the Python cdsapi client was absent; credential values were not read. No CDS retrieval probe or production update ran. The local Windows environment also has no Rscript, so the new discovery command was not executed here. Consequently, all five source families are METADATA_ONLY, all latest verified dates are null, and the portfolio verified common endpoint is unestablished.

## Availability interpretation

- A temporal extent end date is the **latest advertised** date, not a proven available observation.
- Request constraints are reported separately from accepted requests and verified artifacts.
- VERIFIED requires the requested temporal coordinate and all configured variables in an inspected response artifact. The eight-variable ERA5-Land family is verified only as one complete request.
- METADATA_ONLY, UNAVAILABLE, UNKNOWN, and ERROR remain distinct states. Missing credentials do not imply unavailability.
- Finality is recorded only when explicit evidence exists. The ERA5 collection description explains the ERA5T preliminary stream and later finalization, but this catalogue metadata does not label finality per date. The current sources therefore retain NOT_EXPOSED for date-level finality.
- ERA5 low-vegetation LAI and ERA5-Land high/low LAI are monthly climatologies. Daily file labels do not imply new interannual source information.

## Production inventory reconciliation

The latest successful portfolio manifest is 20261015T163459Z_portfolio, modified at 2026-10-15T17:39:07Z. The daily inventory spans 2022-01-01 through 2026-10-01 (1,735 dates per product), with no daily gaps and no missing daily sidecars across 12 products. Weekly inventory spans ISO week 2022-W01 through 2026-W39 (247 weekly files per product); the last complete week ends 2026-09-27. Older 2026-10-14 attempts were cancelled and are superseded by the successful portfolio run.

The audit read manifests, sidecars, filenames, counts, and archive inventories. It did not alter the production root. No available newer source data were proven, so no reprocessing decision is supported by this audit.

Archive counts are candidate caches only. Reuse requires matching the configured request hash, area, dates, variables/statistic, and version metadata; counts or extensions alone are insufficient.

## Reproducibility and use

The read-only command is:

    Rscript --vanilla scripts/discover_cds_availability.R

It queries catalogue metadata and writes JSON, Markdown, and CSV outputs. Add --probe --max-backtrack-days 3 only in an environment with configured CDS credentials. Probe responses and scratch artifacts remain outside production paths. Prior verified evidence can be supplied with --reuse-json PATH; a per-product production inventory can be supplied with --inventory-json PATH.

The current portfolio planner retains its existing configured-observation semantics. This audit ran its read-only plan for explicit provisional endpoint 2026-11-03: it reported 33 daily dates and four complete ISO weeks (weeks 41–44) per product, without contacting CDS, submitting jobs, or modifying production outputs. After a successful live probe establishes a compatible common endpoint, generate a plan with:

    bash hpc/submit_all_products.sh --through YYYY-MM-DD --mode plan

Replace the placeholder with the verified endpoint from the audit. No verified endpoint was established in this run.

## Source references

- [ERA5 daily statistics collection](https://cds.climate.copernicus.eu/api/catalogue/v1/collections/derived-era5-single-levels-daily-statistics)
- [ERA5 single-level hourly collection](https://cds.climate.copernicus.eu/api/catalogue/v1/collections/reanalysis-era5-single-levels)
- [ERA5-Land daily statistics collection](https://cds.climate.copernicus.eu/api/catalogue/v1/collections/derived-era5-land-daily-statistics)
- [AgERA5 collection metadata](https://cds.climate.copernicus.eu/api/catalogue/v1/collections/sis-agrometeorological-indicators)
- [AgERA5 dataset options and version notice](https://cds.climate.copernicus.eu/datasets/sis-agrometeorological-indicators?tab=download)
- [CDS API setup guide](https://cds.climate.copernicus.eu/how-to-api)

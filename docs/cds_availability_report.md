# CDS latest-available-date and update readiness

**Availability audit timestamp:** 2026-11-11T15:31:58Z
**Retrieval readiness follow-up:** 2026-11-11T16:54:30Z
**Current decision:** UPDATE_BLOCKED (supersedes the initial partial-readiness decision)
**Atlas repository inspected:** /project/disease_ecology/cds-datagrab, main, b5315a71793d700313a1c257125892079e03d854
**Local feature branch base:** a6345a25dd43706e3149c86db7ecfbdf61eb8a93
**Production inventory timestamp:** latest successful portfolio manifest modified 2026-10-15T17:39:07Z; manifest 20261015T163459Z_portfolio.

## Decision and endpoints

The production portfolio is internally reconciled through 2026-10-01. CDS metadata advertises dates later than production for each of the five source workflows. No source has a complete retrieval probe in this audit, so no latest verified source date or verified common portfolio endpoint can be reported.

The minimum advertised date across the five source workflows is **2026-11-03**, the provisional common endpoint with status METADATA_ONLY. Independent catalog endpoints are 2026-11-03 for ERA5 daily statistics, 2026-11-05 for ERA5 hourly LAI and ERA5-Land daily statistics, and 2026-11-03 for AgERA5. The ERA5 daily-statistics collection supplies both minimum temperature and soil moisture.

CDS request-constraints payloads were not retrieved. The latest date accepted by date-specific request constraints is therefore **unknown** for every source. The Atlas credential-presence check found no ecmwfr_PAT and no ~/.cdsapirc; the Python cdsapi client was also absent. No live data request was attempted. Every source remains METADATA_ONLY. A common endpoint is **not established**.

## Source-family evidence

| Workflow | CDS dataset | Configured request | Version | Latest advertised | Latest constraints-accepted | Latest verified | Status |
|---|---|---|---|---:|---|---|---|
| era5_mintemp | derived-era5-single-levels-daily-statistics | 2m_temperature, daily minimum, UTC+00, 6-hourly | not pinned | 2026-11-03 | unknown | unknown | METADATA_ONLY |
| era5_soilmoist | derived-era5-single-levels-daily-statistics | volumetric_soil_water_layer_1, daily mean, UTC+00, 6-hourly | not pinned | 2026-11-03 | unknown | unknown | METADATA_ONLY |
| era5_lai_low | reanalysis-era5-single-levels | leaf_area_index_low_vegetation, 00:00 UTC | not pinned | 2026-11-05 | unknown | unknown | METADATA_ONLY |
| agera5_relhum_min | sis-agrometeorological-indicators | 2m_relative_humidity_derived, 24_hour_minimum | 2_0 | 2026-11-03 | unknown | unknown | METADATA_ONLY |
| era5land_daily_mean_utc06 | derived-era5-land-daily-statistics | Eight variables, daily mean, UTC−6, hourly source sampling | not pinned | 2026-11-05 | unknown | unknown | METADATA_ONLY |

Catalogue publication/update metadata: ERA5 daily statistics published 2024-10-14, updated 2026-11-09; ERA5 hourly published 2018-06-14, updated 2026-11-11; ERA5-Land daily statistics published 2024-10-14, updated 2026-11-11; AgERA5 published 2020-01-30, updated 2026-11-10. All four collections advertise daily update frequency and an available CDS sanity status. These fields describe catalogue state and do not prove that any specific date/variable request is retrievable.

The eight ERA5-Land variables in the single shared request are 2m_temperature, soil_temperature_level_1, soil_temperature_level_2, volumetric_soil_water_layer_1, volumetric_soil_water_layer_2, surface_pressure, leaf_area_index_high_vegetation, and leaf_area_index_low_vegetation. A usable family endpoint requires all eight in the same inspected response.

### AgERA5 version and compatibility

Production configuration already requests version 2_0; there is no pending v1/v1.1 to v2 switch. The official CDS notice says v1.1 updates ended in June 2026 and v2 continues to update. The configured relative-humidity variable and 24-hour minimum statistic appear in the current v2 dataset options. This is a static catalogue/configuration compatibility finding, not an accepted request or data probe. No numerical comparison against v1.1 was performed; production request sidecars do not establish the actual source version used for every historical artifact. No migration is recommended by this audit because the current workflow is already configured for v2.

### Preliminary/final and climatology interpretation

The ERA5 hourly collection describes the ERA5T preliminary stream and later finalization, commonly after two to three months. The collection metadata does not expose date-level finality, and no date-specific artifact was retrieved. Finality for the candidate dates is therefore NOT_EXPOSED; they must not be described as verified final data. The ERA5-Land and AgERA5 metadata reviewed here also do not establish per-date finality.

ERA5 low-vegetation LAI and ERA5-Land high/low vegetation LAI are monthly climatology products. Daily raster date labels do not represent new interannual source information for those variables.

## Production inventory and product update plan

The latest successful production portfolio run is 20261015T163459Z_portfolio; two 2026-10-14 portfolio attempts were cancelled and were superseded. The current production inventory has 1,735 daily outputs per product from 2022-01-01 through 2026-10-01, with no gaps and all daily sidecars present. Each product has 247 weekly outputs from 2022-W01 through 2026-W39; the last week ends Sunday 2026-09-27. The configured temporal.observed_end remains the historical 2026-07-26 value and was not changed. The hard horizon remains 2026-12-31.

The table gives product-specific catalog-conditional windows. Missing-day counts are blank because no verified CDS endpoint exists. The three ERA5/AgERA5 daily workflows conditionally extend through November 3 (33 dates, October 2–November 3); ERA5 hourly LAI and the eight-variable ERA5-Land family conditionally extend through November 5 (35 dates). The synchronized portfolio candidate of November 3 would represent 396 daily product outputs and four complete ISO weeks wholly within the incremental window (weeks 41–44, ending 2026-11-01), or 48 weekly product outputs, all conditional on successful complete probes.

| Product | Source workflow | CDS dataset | Version | Advertised | Production latest | Verified missing days | Catalog-conditional days | Conditional complete week | Conditional new weeks | Confidence | Action |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---|
| era5_mintemp | era5_mintemp | ERA5 daily statistics | not pinned | 2026-11-03 | 2026-10-01 | unknown | 33 | 2026-11-01 | 4 | METADATA_ONLY | hold pending complete retrieval evidence |
| era5_soilmoist | era5_soilmoist | ERA5 daily statistics | not pinned | 2026-11-03 | 2026-10-01 | unknown | 33 | 2026-11-01 | 4 | METADATA_ONLY | hold pending complete retrieval evidence |
| era5_lai_low | era5_lai_low | ERA5 hourly single levels | not pinned | 2026-11-05 | 2026-10-01 | unknown | 35 | 2026-11-01 | 4 | METADATA_ONLY | hold; labels are monthly climatology dates |
| agera5_relhum_min | agera5_relhum_min | AgERA5 indicators | 2_0 | 2026-11-03 | 2026-10-01 | unknown | 33 | 2026-11-01 | 4 | METADATA_ONLY | hold pending complete retrieval evidence |
| era5land_tmean | era5land_daily_mean_utc06 | ERA5-Land daily statistics | not pinned | 2026-11-05 | 2026-10-01 | unknown | 35 | 2026-11-01 | 4 | METADATA_ONLY | hold pending all eight variables |
| era5land_soiltemp_l1_mean | era5land_daily_mean_utc06 | ERA5-Land daily statistics | not pinned | 2026-11-05 | 2026-10-01 | unknown | 35 | 2026-11-01 | 4 | METADATA_ONLY | hold pending all eight variables |
| era5land_soiltemp_l2_mean | era5land_daily_mean_utc06 | ERA5-Land daily statistics | not pinned | 2026-11-05 | 2026-10-01 | unknown | 35 | 2026-11-01 | 4 | METADATA_ONLY | hold pending all eight variables |
| era5land_soilwater_l1_mean | era5land_daily_mean_utc06 | ERA5-Land daily statistics | not pinned | 2026-11-05 | 2026-10-01 | unknown | 35 | 2026-11-01 | 4 | METADATA_ONLY | hold pending all eight variables |
| era5land_soilwater_l2_mean | era5land_daily_mean_utc06 | ERA5-Land daily statistics | not pinned | 2026-11-05 | 2026-10-01 | unknown | 35 | 2026-11-01 | 4 | METADATA_ONLY | hold pending all eight variables |
| era5land_surface_pressure_mean | era5land_daily_mean_utc06 | ERA5-Land daily statistics | not pinned | 2026-11-05 | 2026-10-01 | unknown | 35 | 2026-11-01 | 4 | METADATA_ONLY | hold pending all eight variables |
| era5land_lai_high_mean | era5land_daily_mean_utc06 | ERA5-Land daily statistics | not pinned | 2026-11-05 | 2026-10-01 | unknown | 35 | 2026-11-01 | 4 | METADATA_ONLY | hold; monthly climatology dates |
| era5land_lai_low_mean | era5land_daily_mean_utc06 | ERA5-Land daily statistics | not pinned | 2026-11-05 | 2026-10-01 | unknown | 35 | 2026-11-01 | 4 | METADATA_ONLY | hold; monthly climatology dates |

### Archives and estimated request workload

Candidate raw source archives under _sources include 62 ERA5-Land ZIP files; 120 ERA5 minimum-temperature NetCDF files; 120 ERA5 soil-moisture NetCDF files; 65 ERA5 LAI .nc plus 55 .netcdf files; and 64 AgERA5 ZIP plus 55 .netcdf files. These are not certified reusable for the proposed windows until request manifests/sidecars match date coverage, request hash, configured variable/statistic, request area, and source version.

A monthly chunking estimate for October 2 through November 3/5 is **10 source requests**: two monthly chunks for each of five source workflows. ERA5-Land sends all eight variables in each shared monthly request. This is an upper-bound planning estimate before qualifying reusable archives; it is not a submitted request count.

No available observations were verified and no overlap reprocessing is recommended from this audit. The inventory contains no dates after October 1.

## Readiness, planning command, and blockers

The data inventory is reconciled and the catalog advertises later candidate dates, so the work is partially ready for a production plan. An update is not ready to execute: exact date constraint acceptance and artifact completeness are unverified for all five sources, and no synchronized verified endpoint exists.

If a later bounded audit verifies 2026-11-03 as the minimum compatible endpoint, the exact portfolio planning command will be:

    bash hpc/submit_all_products.sh --through 2026-11-03 --mode plan

The read-only plan was executed on Atlas with this explicit provisional target. It reported an incremental window of 2026-10-02 through 2026-11-03, 33 daily dates per product, and 4 complete ISO weeks per product (weeks 41–44); every product had 0 daily and 0 weekly outputs present within that incremental window. It marked the explicit target unverified and confirmed CDS contacted=false, Slurm jobs submitted=false, and production outputs modified=false. Keep production update mode off until probes establish a verified common endpoint and the plan is reviewed.

The proposed live discovery command in a credential-configured environment is:

    Rscript --vanilla scripts/discover_cds_availability.R --probe --max-backtrack-days 3 --output-dir docs

Then pass the endpoint returned as VERIFIED for the common portfolio to the plan command. The new discovery capability keeps the existing latest-common behavior unchanged.

## CHIME compatibility recommendation

The current CHIME adapter reports local manifest state and configured endpoint. It should expose separate fields for local_currentness, upstream_currentness, upstream_verification_status, source_version_compatibility, portfolio_readiness, and recommended_action. A local CURRENT result should not imply that CDS has no newer data. A source with METADATA_ONLY should report unverified upstream state; an incompatible source version should block the portfolio endpoint. Preserve manifest-first status, exact-plan approval, and guarded execution. Feed per-source evidence into downstream dependency impact summaries. No CHIME changes or downstream jobs were made.

## Official source links

- [ERA5 daily statistics collection](https://cds.climate.copernicus.eu/api/catalogue/v1/collections/derived-era5-single-levels-daily-statistics)
- [ERA5 hourly single-level collection, including ERA5T description](https://cds.climate.copernicus.eu/api/catalogue/v1/collections/reanalysis-era5-single-levels)
- [ERA5-Land daily statistics collection](https://cds.climate.copernicus.eu/api/catalogue/v1/collections/derived-era5-land-daily-statistics)
- [AgERA5 collection metadata](https://cds.climate.copernicus.eu/api/catalogue/v1/collections/sis-agrometeorological-indicators)
- [AgERA5 dataset options and version notice](https://cds.climate.copernicus.eu/datasets/sis-agrometeorological-indicators?tab=download)
- [CDS API setup guide](https://cds.climate.copernicus.eu/how-to-api)

## Retrieval verification follow-up — 2026-11-11

This follow-up supersedes the earlier UPDATE_PARTIALLY_READY conclusion. The current decision is UPDATE_BLOCKED because no source has a verified retrieval date and the required Atlas authentication could not be rechecked in this turn.

### Authentication and retrieval path

The production retriever is the existing R interface: perform_cds_transfer() calls ecmwfr::wf_request(..., transfer = TRUE), and the bounded discovery probe uses the same ecmwfr request path with temporary scratch outputs. The repository setup script expects ecmwfr_PAT in the secure Atlas environment (or an interactive ecmwfr::wf_set_key() setup on a secure login node). Python cdsapi is not required, and it was not installed.

The latest recorded Atlas presence check, at 2026-11-11T15:31:58Z, found ecmwfr_PAT unset and ~/.cdsapirc absent; no credential value was read. It did not test whether an ecmwfr key is already stored through wf_set_key(). A follow-up attempt verified that the WSL ControlMaster was running, but the policy-required wrapper /home/john/bin/atlas-ssh was missing in this WSL environment. Therefore current authentication could not be confirmed. The exact absent environment configuration from the last check is ecmwfr_PAT; the stored wf_set_key() credential state was not assessed. ~/.cdsapirc is not required by the established R path. Live verification stopped before any CDS request.

| Source workflow | Advertised date | Retrieval result | Latest verified |
|---|---:|---|---|
| era5_mintemp | 2026-11-03 | NOT_ATTEMPTED_AUTH_BLOCKED; 2m_temperature, daily minimum | unknown |
| era5_soilmoist | 2026-11-03 | NOT_ATTEMPTED_AUTH_BLOCKED; volumetric_soil_water_layer_1, daily mean | unknown |
| era5_lai_low | 2026-11-05 | NOT_ATTEMPTED_AUTH_BLOCKED; low-vegetation LAI at 00:00 UTC (monthly-climatology date label) | unknown |
| agera5_relhum_min | 2026-11-03 | NOT_ATTEMPTED_AUTH_BLOCKED; configured v2.0 relative-humidity 24-hour minimum | unknown |
| era5land_daily_mean_utc06 | 2026-11-05 | NOT_ATTEMPTED_AUTH_BLOCKED; complete eight-variable request not retrieved | unknown |

All five source families remain METADATA_ONLY. No request acceptance, downloaded artifact, temporal coordinate, returned variable set, or finality evidence was observed in this follow-up. No source is classified as unavailable.

### Conditional portfolio plan

The last actual read-only planner result was from the prior audit. It used:

    bash hpc/submit_all_products.sh --through 2026-11-03 --mode plan

For the explicit, still-unverified endpoint, it reported 2026-10-02 through 2026-11-03: 33 incremental daily dates per product, or 396 daily outputs across 12 products. The four complete ISO weeks were 2026-W41 through 2026-W44, or 48 weekly outputs. The plan found 0/33 daily and 0/4 weekly outputs present in that incremental window. The pre-existing baseline was 1,735 daily and 247 weekly outputs per product through 2026-10-01 and 2026-W39; the planner's earliest-missing-date behavior retains those valid outputs. Candidate raw archives remain unqualified for reuse.

The planner was not rerun in this follow-up: there is no verified common endpoint, and the required Atlas wrapper is unavailable. If an update were later approved after all five source workflows verify a common endpoint of 2026-11-03, the documented portfolio path expects 5 source jobs, 5 aggregation jobs, and 1 portfolio validation job (11 Slurm jobs total). The earlier monthly-chunk estimate is 10 source request chunks before any archives are proven reusable. No Slurm jobs were submitted.

After secure ecmwfr_PAT configuration and restoration of the authorized Atlas wrapper, resume verification with:

    Rscript --vanilla scripts/discover_cds_availability.R --probe --max-backtrack-days 3 --output-dir docs

Only if the resulting evidence establishes 2026-11-03 as VERIFIED for all five source workflows should the portfolio update command be considered:

    bash hpc/submit_all_products.sh --through 2026-11-03 --mode update

That update command is conditional and was not run. No production data, manifests, or outputs were modified.

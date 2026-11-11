# CDS latest-available-date and update readiness

**Availability audit timestamp:** 2026-11-11T18:08:55Z
**Retrieval verification:** 2026-11-11T18:08:55Z
**Current decision:** UPDATE_PARTIALLY_READY (ERA5-Land verified; four workflows remain unresolved)
**Atlas repository inspected:** /project/disease_ecology/cds-datagrab, main, b5315a71793d700313a1c257125892079e03d854
**Local feature branch:** codex/cds-availability-audit at 825452da33d66aa4dcc3bac20cc8b01a8686c7b3
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

This follow-up supersedes the earlier authentication-blocked report. The R process had ecmwfr_PAT available from its environment, and the installed ecmwfr client authenticated successfully for the shared ERA5-Land retrieval. The credential value was not displayed, logged, copied, or committed. The secrets.yaml fallback is implemented and focused-tested with dummy credentials; the live R process did not need to read that file. Python cdsapi is not required.

The existing R request path and repository validators were used. CDS response archives were normalized through the existing ZIP handling; ERA5-Land members were mapped and checked with the existing eight-product archive validator. All probe outputs were temporary and isolated from production data.

| Source workflow | Latest advertised | Latest candidate retrieval | Exact 2026-11-03 retrieval | Returned evidence |
|---|---:|---|---|---|
| era5_mintemp | 2026-11-05 | 2026-11-05 ERROR | ERROR at 2026-11-03; no request accepted | no coordinates or variables returned |
| era5_soilmoist | 2026-11-05 | 2026-11-05 ERROR | ERROR at 2026-11-03; no request accepted | no coordinates or variables returned |
| era5_lai_low | 2026-11-05 | 2026-11-05 ERROR | ERROR at 2026-11-03; no request accepted | no coordinates or variables returned |
| agera5_relhum_min | 2026-11-03 | 2026-11-03 ERROR | ERROR at 2026-11-03; no request accepted | no coordinates or variables returned |
| era5land_daily_mean_utc06 | 2026-11-05 | 2026-11-05 VERIFIED | VERIFIED 2026-11-03 | 8/8 variables; 2026-11-03 |

ERA5-Land returned the exact 2026-11-03 temporal coordinate and all eight configured variables: 2m_temperature, soil_temperature_level_1, soil_temperature_level_2, volumetric_soil_water_layer_1, volumetric_soil_water_layer_2, surface_pressure, leaf_area_index_high_vegetation, leaf_area_index_low_vegetation. Its latest candidate, 2026-11-05, also passed the existing archive/date/variable checks. The other four workflows returned errors before a request was accepted; no artifact, temporal coordinate, or returned-variable set was available for inspection. The safe error summary did not retain an HTTP status for these failures, so they remain ERROR, not UNAVAILABLE. The current catalogue constraints omit year/month/day enums; the accepted ERA5-Land retrieval proves its requested dates directly, while date admissibility remains unknown for the four failed workflows.

**Verified common endpoint: none.** Only ERA5-Land is verified (latest verified endpoint 2026-11-05); the four failed workflows prevent a common endpoint. The provisional 2026-11-03 date remains METADATA_ONLY for the portfolio as a whole.

### Read-only portfolio plan

The existing portfolio planner ran against the production output root for 2026-11-03, with its plan JSON written under Atlas /tmp. It returned 2026-10-02 through 2026-11-03: 33 daily outputs per product (396 total) and 4 complete ISO weeks per product (48 weekly outputs total). The weeks are 2026-W41, 2026-W42, 2026-W43, 2026-W44. All 12 products had 0/33 daily and 0/4 weekly outputs present within the incremental window. Existing validated coverage through 2026-10-01 (daily) and 2026-09-27 (weekly) is reused; no overlap reprocessing is planned.

If all five workflows later verify a common endpoint of 2026-11-03, the portfolio wrapper would schedule 5 source jobs, 5 aggregation jobs, and 1 validation job (11 total). The plan itself contacted no CDS service, submitted no Slurm jobs, and modified no production outputs.

### Decision and next action

**UPDATE_PARTIALLY_READY.** ERA5-Land is verified, but no common verified endpoint exists because four source workflows errored before request acceptance. Production update mode is not cleared. Diagnose those four errors and repeat bounded retrieval verification for all five sources at 2026-11-03.

After all five workflows verify, rerun the plan and review it before using this exact production command:

    bash hpc/submit_all_products.sh --through 2026-11-03 --mode update

No production update command or Slurm job was run. The focused Atlas test result for the availability module was 53 passed, 0 failed, 0 warnings.

## Standalone failure diagnosis and bounded retest — 2026-11-11

This section supersedes the earlier generic error descriptions. The saved audit JSON had dropped exception details. A bounded diagnostic replay established that the four original failures were local path-resolution errors: `.cds_availability_live_probe()` passed every source to `resolve_source_storage_paths()`, which requires `project.source_family_id`. The four standalone configs have no such field, so each raised `simpleError: source_family_id is invalid` after request construction and before CDS submission. ERA5-Land has a configured family ID and uses this resolver in production.

The request definitions themselves match production: discovery uses `build_variable_requests()` and `build_cds_api_payload()` with the source configs, so dataset, variable, date, statistic/time, area, and format were not duplicated. Production standalone workflows use `resolve_storage_paths()`; the shared ERA5-Land workflow uses `resolve_source_storage_paths()`. Standalone discovery transfers now use the production `perform_cds_transfer()` wrapper and retry policy. The previously working ERA5-Land probe transfer path remains unchanged. No scientific-configuration changes were made.

One bounded request per affected workflow was then submitted for 2026-11-03 using the production request and transfer functions, into isolated scratch storage. All four requests were constructed and reached CDS, which rejected each with HTTP 401 (`Authentication failed / operation not allowed`). The download wrapper surfaced a `simpleError`; its sanitized traceback passes through `download_cds_requests()` and the error boundary. None was accepted, and no returned artifact, temporal coordinate, or variable was available for inspection. A credential was available to the R process; its value was not displayed, logged, copied, or committed, and the secrets file was not modified. No retries were made after the authentication rejection. The 401 does not distinguish a bad/expired PAT from missing CDS account or dataset authorization; that is the remaining blocker.

| Source workflow | Nov 3 request | Request accepted | Returned observation evidence | Latest verified endpoint |
|---|---|---:|---|---:|
| era5_mintemp | CDS HTTP 401; authentication/authorization rejection | No | None | None |
| era5_soilmoist | CDS HTTP 401; authentication/authorization rejection | No | None | None |
| era5_lai_low | CDS HTTP 401; authentication/authorization rejection | No | None | None |
| agera5_relhum_min | CDS HTTP 401; authentication/authorization rejection | No | None | None |
| era5land_daily_mean_utc06 | Prior successful retrieval | Yes | 2026-11-03; all 8 configured variables; latest verified 2026-11-05 | 2026-11-05 |

**Verified common endpoint: none.** The four standalone sources remain unverified. 2026-11-03 is still only a catalogue candidate for the complete portfolio. The previously run read-only portfolio plan remains conditional on that target: 2026-10-02 through 2026-11-03, 33 incremental daily outputs per product (396 total), 4 complete ISO weeks per product (48 total; 2026-W41 through 2026-W44), with 0 outputs present in that incremental window. It reuses the valid daily baseline through 2026-10-01 and weekly baseline through 2026-09-27. Expected update workload remains 5 source jobs, 5 aggregation jobs, and 1 portfolio-validation job (11 total). No jobs were submitted and production data were not modified.

**Decision: `UPDATE_PARTIALLY_READY`.** ERA5-Land is verified through 2026-11-05, but the four HTTP 401 responses prevent a common endpoint and block a portfolio update. After CDS credential/account permissions are corrected, rerun the bounded Nov 3 retrieval probes and the read-only plan. Do not run production update mode before all five sources share a verified endpoint. The production command, once verified and reviewed, remains:

    bash hpc/submit_all_products.sh --through 2026-11-03 --mode update

## Known-working ERA5 minimum-temperature reference diagnosis — 2026-11-11

The operator's successful 2026-11-03 reference request matches the configured production values for dataset (`derived-era5-single-levels-daily-statistics`), product type, variable, date, daily minimum, UTC time zone, and 6-hour frequency. Production additionally sends the configured spatial `area`, `data_format=netcdf`, and `download_format=unarchived`; the discovery builder uses the production request builder, so no date/statistic/time-zone difference was found. `perform_cds_transfer()` calls `ecmwfr::wf_request(request=c(list(dataset_short_name=...), payload), transfer=TRUE, path=dirname(target_path))`; its production call uses ecmwfr's default user/timeout/polling arguments and retries transient errors only.

The Atlas client is ecmwfr 2.0.3. Its `wf_get_key()` checks `ecmwfr_PAT` before the ecmwfr keyring. In the isolated R process, `ecmwfr_PAT` was absent before the repository loader ran; the existing loader successfully populated it from the ignored `secrets.yaml`. Only credential presence was emitted. The successful Python example does not establish that the Atlas PAT is the same account credential.

Static inspection of the installed client shows two relevant endpoints. Dataset resolution performs an unauthenticated GET to `https://cds.climate.copernicus.eu/api/catalogue/v1/collections/`; `wf_datasets()` converts any HTTP error to `Server not reachable...`, and `guess_service()` then reports a generic dataset-not-found/credentials-mismatch error. Task submission uses `https://cds.climate.copernicus.eu/api/retrieve/v1/processes/{dataset_short_name}/execute` and sends the token in a `PRIVATE-TOKEN` header. The earlier four 2026-11-03 diagnostics recorded HTTP 401 at task submission, before acceptance. This is consistent with authentication/authorization rejection; it does not establish which account or permission failed.

One bounded R call was made with the exact reference fields, a five-minute timeout, and isolated temporary output. The request was constructed and `wf_request()` returned an error, but the diagnostic wrapper then failed because its scratch source copy lacked the sanitizer helper. The R error's status, endpoint, and call stack were therefore not recorded, and this call's submission stage cannot be determined. No returned artifact or observation was verified, and no further live requests were made. This incomplete reproduction does not supersede the earlier four HTTP 401 records. Because the reference values match production and the 401 is an authentication/authorization response, no scientific or request-parameter correction is justified by current evidence.

**Readiness is unchanged: `UPDATE_PARTIALLY_READY`.** ERA5-Land remains verified through 2026-11-05; the four standalone sources have no verified observations, and no verified common endpoint exists. The read-only Nov 3 plan remains 396 incremental daily outputs, 48 complete ISO-week outputs, and 11 expected Slurm jobs, all conditional. No production downloads, jobs, or data changes were made. The focused availability test run in the existing Atlas scratch checkout reported 53 passed, 0 failed, 1 warning from a temporary non-Git test fixture invoking `git rev-parse`.

## Definitive minimum-temperature reference reproduction — 2026-11-11

The diagnostic was rerun from a complete Git snapshot at `066c3a24e15fbea495bfb957c40612e802fc9f27`. The Atlas package was installed from that same snapshot with the repository installer; the installed commit marker matched the source SHA. Focused availability tests passed **73/73**, with no failures or warnings. An installed-package smoke test also passed simulated HTTP 401 classification and 503 credential redaction.

Atlas used ecmwfr 2.0.3 with API base `https://cds.climate.copernicus.eu/api`. The loader found `ecmwfr_PAT` absent in the R process and populated it from the existing ignored `secrets.yaml`; only presence was checked or reported. ecmwfr's `wf_get_key()` prefers that environment variable over the keyring and sends it in a `PRIVATE-TOKEN` header. Standalone and ERA5-Land submissions resolve credentials through the same ecmwfr environment mechanism. Atlas had no `~/.cdsapirc`; the successful Python example therefore does not establish that its configured account credential equals the Atlas PAT.

Exactly one bounded R `wf_request()` invocation used the operator's exact fields: dataset `derived-era5-single-levels-daily-statistics`, `2m_temperature`, 2026-11-03, daily minimum, `utc+00:00`, `6_hourly`, and `reanalysis`. It used temporary scratch output, a five-minute timeout, and no submission retry. The request was constructed and submitted; CDS returned **HTTP 401** from `https://cds.climate.copernicus.eu/api/retrieve/v1/processes/derived-era5-single-levels-daily-statistics/execute`. The existing error helper classified it as `simpleError;error;condition`, stage `cds_task_submission`, sanitized message “CDS rejected the request with HTTP 401 (authentication or authorization failure),” submission attempted=true, accepted=false. No artifact, date coordinate, or variable was returned.

This exact reference request also failed in R, so the extra production `area`, `data_format`, and `download_format` fields do not explain the 401. The source-confirmed failing path is `ecmwfr::wf_request()` → `ds_service$submit()` → `httr::VERB(POST, .../execute)` → HTTP-error check → `stop()`. The diagnostic helper returned only the outer 12 stack frames, so that source-confirmed path is the relevant traceback rather than a full captured inner stack.

ecmwfr resolves dataset/service metadata before submission using GET requests to `/api/catalogue/v1/collections/`. Its `wf_datasets()` converts any HTTP error to “Server not reachable...”; `wf_check_request()` then catches that error and `guess_service()` reports a generic dataset-not-found/credential-mismatch error. Those catalog GETs are not made through the traced `VERB` call, so their response status was not captured in this run. The observed request reached the task POST, establishing that service resolution succeeded for this attempt; the 401 was at task submission.

**Diagnosis:** the known-working Python parameter set is not the cause of the R failure: the same reference fields were rejected by CDS at the Atlas ecmwfr authenticated task submission. Evidence does not distinguish PAT validity from CDS account or dataset permissions. No request or scientific correction was made. The other three standalone sources were not retested. The common verified endpoint remains unset, and readiness remains `UPDATE_PARTIALLY_READY`; no production data or Slurm jobs were touched.
## Corrected Atlas credential and live common-endpoint verification — 2026-11-11

This is the latest verification and supersedes the earlier standalone HTTP 401 results. The Atlas secrets.yaml PAT had been malformed; the operator corrected it. Using the existing credential loader, with ecmwfr_PAT absent before loading, the installed R package loaded the token from that file without displaying, logging, copying, or modifying it. The file was confirmed owner-only (0600). The CDS API call used ecmwfr_PAT authentication in ecmwfr's PRIVATE-TOKEN header; no separate CDS username or user ID was required or supplied. ecmwfr 2.0.3 authenticated successfully.

All live retrievals used the established R production request builder, perform_cds_transfer()/ecmwfr, ZIP/NetCDF normalization, and existing validation in isolated probe scratch. Each standalone response was inspected for the requested temporal coordinate and configured variable:

| Source workflow | Requested / observed date | Returned variable | Result |
|---|---|---|---|
| era5_mintemp | 2026-11-03 | 2m_temperature | VERIFIED |
| era5_soilmoist | 2026-11-03 | volumetric_soil_water_layer_1 | VERIFIED |
| era5_lai_low | 2026-11-03 | leaf_area_index_low_vegetation | VERIFIED |
| agera5_relhum_min | 2026-11-03 | 2m_relative_humidity_derived (dataset version 2.0) | VERIFIED |
| era5land_daily_mean_utc06 | Previously verified through 2026-11-05; includes 2026-11-03 | All eight configured variables | VERIFIED; preserved from the prior successful retrieval |

For ERA5-Land the preserved variables are 2m_temperature, soil_temperature_level_1, soil_temperature_level_2, volumetric_soil_water_layer_1, volumetric_soil_water_layer_2, surface_pressure, leaf_area_index_high_vegetation, and leaf_area_index_low_vegetation. No ERA5-Land request was repeated in this run.

**Latest verified endpoints:** era5_mintemp 2026-11-03; era5_soilmoist 2026-11-03; era5_lai_low 2026-11-03; agera5_relhum_min 2026-11-03; shared ERA5-Land 2026-11-05. **Verified common endpoint: 2026-11-03.**

The existing portfolio wrapper was run in read-only plan mode through 2026-11-03. It reports 12 products, an incremental window of 2026-10-02 through 2026-11-03, 33 daily dates per product (396 total), and four complete ISO weeks per product (48 total: 2026-W41 through 2026-W44). No valid daily or weekly outputs were present in those incremental windows; the existing valid baseline through 2026-10-01 daily and 2026-09-27 weekly is reused. Expected workload if an update is later submitted is 5 source jobs, 5 aggregation jobs, and 1 final validation job (11 total).

The planner still prints unverified explicit target because configured temporal.observed_end values remain 2026-07-26. Those scientific/workflow configuration files were left unchanged as requested. The live retrieval evidence above establishes the explicit 2026-11-03 target. Use this exact command for the production update when authorized:

    bash hpc/submit_all_products.sh --through 2026-11-03 --mode update

The focused tests passed: 73/73, with 0 failures and 0 warnings, using package source and installed commit 892197745ce290bc236fe5cf5baf1c7a316b5e73. The read-only planner contacted no CDS endpoint, submitted no Slurm jobs, and modified no production outputs. No production jobs or data were changed during this task.

**Final decision: UPDATE_READY.**

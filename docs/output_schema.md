# Output and provenance reference

This reference describes fields currently written by the ERA5-Land family manifests, request registry, extracted-source inventories, daily sidecars, and coverage diagnostics. Fields are not inferred from older run records; historical manifests may contain fewer fields.

## Storage paths

```text
<root>/
├── data/<profile>/<product_id>/
│   ├── daily/       # authoritative daily GeoTIFFs and sidecars
│   ├── weekly/      # authoritative complete ISO-week GeoTIFFs and sidecars
│   └── ...
├── data/<profile>/_sources/era5land_daily_mean_utc06/
│   ├── raw/         # one validated monthly archive per request
│   ├── extracted/   # extracted members under <request_hash>/
│   └── requests/    # request registry
├── runs/<profile>/<product-or-source>/<run_id>/
└── logs/<pipeline|slurm>/<profile>/
```

Raw monthly ERA5-Land archives are stored once under the shared source family. The eight product directories remain isolated for derived daily/weekly outputs. Request-scoped extraction contains `member_inventory.csv` and `source_map.csv`, which map the shared archive/member to product/date outputs.

## Request registry

The registry path is `data/<profile>/_sources/era5land_daily_mean_utc06/requests/request_registry.csv`. Each row is keyed by `source_family`, `request_hash`, `start_date`, and `end_date`. Current columns are:

```text
source_family, request_hash, start_date, end_date, request_days,
cds_job_id, cds_job_url, request_status, submitted_at, last_checked_at,
retrieved_at, local_raw_path, local_bytes, local_checksum,
error_class, error_message, source_commit, config_checksum
```

Current lifecycle states are `planned`, `submitted`, `processing`, `retrieved`, `expired`, and `failed`. Registry writes use a temporary file and atomic replacement. A valid local archive is reconciled to `retrieved`; a persisted job URL is reused instead of staging a duplicate active request.

## Source and product manifests

Family run manifests record `source_family_id`, `request_hash`, request dates and variables, source/raw/extracted paths, `product_ids`, `family_status`, timestamps, `successful_products`, `failed_products`, `successful_product_dates`, `failed_product_dates`, `raw_reused`, `archive_reused`, `extraction_reused`, `CDS_contacted`, daily output counts, and coverage totals. They also carry support-mask provenance: master-template checksum, support-mask checksum, unsupported-cell audit checksum, audited cell IDs, and support-distance threshold.

Product run manifests record the source-family lineage (`shared_raw_path`, shared extraction directory, source member, source alias, request hash, request dates, and request-specific map row count), product/date outcomes, `status`, successful/failed dates, daily written/reused/replaced counts, coverage totals, `failure_stage`, `failure_message`, and, for failures, `condition_class`, `condition_call`, and `traceback`. Product results include `fast_forwarded = true` when a complete product was reused and `coverage_metrics_source` to distinguish recomputed metrics from existing output metadata.

Failure records use `failure_stage` and `failure_message` for the pipeline-level outcome. Date-level results use the same fields and retain `condition_class`, `condition_message`, `condition_call`, and bounded `traceback` when a reader or processing condition is available.

## Extracted-source inventory and map

`member_inventory.csv` records archive/member checksums, member names and sizes, extracted paths, container and NetCDF inspection status, product ID, CDS variable, environmental alias, source units, dimension names/lengths, time dimension, and decoded dates. `source_map.csv` has one row per product/date and records request hash, product, alias, archive member, units, time index, source date, and output date. Scalar metadata variables such as `number` are not treated as environmental members.

## Daily and weekly outputs

Daily filenames are `<prefix>_YYYY-MM-DD.tif`; weekly filenames are `<prefix>_YYYY-Www.tif`. Every authoritative daily output is accompanied by a JSON sidecar. ERA5-Land daily sidecars include product/source metadata, `source_family_id`, `request_hash`, request start/end, source member, source alias, source archive path, source-map row count, daily statistic/time-zone/frequency, unit conversion, template/support-mask provenance, coverage repair diagnostics, output range/counts, `output_sha256`, and `output_reopened_valid`.

Coverage fields include master-template cells, ERA5-Land-supported cells, structural exclusions, pre-repair missing supported cells, repaired supported cells, unexpected post-repair missing cells, outside-support finite cells, component records, and final checksum/reopen results. Coverage validation writes masks named `missing_inside`, `outside_mask`, `structural_support_exclusion`, and `unexpected_post_repair_missing`; component details are written to `repair_components_<product>_<date>.csv` when enabled.

Weekly sidecars record the ISO week, variable/spec hash, selected daily dates and paths, selected daily checksums, template checksum, aggregation algorithm version, input fingerprint, output checksum, and reuse-defining input fingerprint. Weekly outputs require seven valid daily inputs and preserve structural support exclusions.

## Source-bound numerical tolerance

`validate_source_values()` applies an absolute tolerance of `1e-10` only when testing finite source values against finite `source_hard_valid_range` bounds. Values within tolerance are normalized to the exact boundary; the scientific hard range is unchanged, and material violations still fail. For example, the ERA5-Land volumetric soil-water source range is exactly `[0, 1]`.

The reader result records `source_raw_minimum`, `source_raw_maximum`, `source_minimum`, `source_maximum`, `source_lower_clamped_count`, `source_upper_clamped_count`, and `source_validation_tolerance`. The current daily sidecar writer exposes the normalized source extrema as `source_minimum` and `source_maximum`; it does not claim the raw/clamp fields as sidecar fields. This distinction is intentional and reflects the current implementation.

## Root-error preservation

Reader/read failures preserve the original condition details: `condition_class`, `condition_message`, `condition_call`, and bounded traceback/call-stack information. A secondary error raised while recording failure bookkeeping is stored separately as a diagnostic-recording error when possible; it does not replace the original reader exception or its message.

The protected master template is `spatial_domain/study_area_raster.tif`. The support artifacts are `spatial_domain/derived/era5land_support_mask.tif` and `spatial_domain/derived/era5land_unsupported_cells.csv`. The template SHA-256 is:

```text
4BE01F0ECAFF35216A72EB8F27E791311AF90D35B5A4FFF1E46A74EDB6DC633B
```

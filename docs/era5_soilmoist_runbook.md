# ERA5 soilmoist runbook

`era5_soilmoist` is the weekly NWS soil-moisture covariate. It is volumetric soil water in the upper 0–7 cm (layer 1), with CDS variable `volumetric_soil_water_layer_1` and preferred NetCDF short name `swvl1`. Units remain m3 m-3. The CDS daily-statistics product supplies daily means from 6-hourly UTC samples; the workflow computes complete-week arithmetic means of seven daily rasters.

ERA5 soil water is defined globally, including water surfaces. This workflow intentionally applies the established study-area template mask only; it does not introduce a new land-sea mask. Outputs are grid-cell values and should not be interpreted as point field measurements.

## Spatial and value rules

The validated template is `spatial_domain/study_area_raster.tif`, with 16,759 non-NA cells, dimensions 202 × 293, the existing Albers equal-area CRS in kilometres, and SHA256 `4BE01F0ECAFF35216A72EB8F27E791311AF90D35B5A4FFF1E46A74EDB6DC633B`. The CDS area is `[42.75, -126, -1.25, -34]`. Projection is exactly one `terra::project(..., method="bilinear")` call followed by the template mask.

Values outside [0, 1] fail, with ±1e-6 floating-point tolerance normalized to the boundary. The soft warning range is [0.01, 0.80] and does not invalidate a raster. Very dry and very wet values are retained as potentially meaningful for NWS pupal ecology.

## Configurations and smoke sequence

- `config/era5_soilmoist_smoke.yml`: July 1–3, three daily outputs, one incomplete week, no weekly output.
- `config/era5_soilmoist_weekly_smoke.yml`: July 6–12, seven daily outputs and `soilmoist_2026-W28.tif`.
- `config/era5_soilmoist_production.yml`: January 1, 2022 through July 12, 2026, estimation disabled.

Prepare but do not execute these Atlas commands:

```bash
cd /project/disease_ecology/cds-datagrab
CDS_DATAGRAB_ROOT=/project/disease_ecology/cds-datagrab-smoke-output PROFILE=smoke CONFIG=config/era5_soilmoist_smoke.yml MODE=plan DRY_RUN=true OBSERVED_END=2026-07-03 bash hpc/submit_era5_soilmoist.sh
CDS_DATAGRAB_ROOT=/project/disease_ecology/cds-datagrab-smoke-output PROFILE=smoke CONFIG=config/era5_soilmoist_smoke.yml MODE=full DRY_RUN=false OBSERVED_END=2026-07-03 bash hpc/submit_era5_soilmoist.sh
CDS_DATAGRAB_ROOT=/project/disease_ecology/cds-datagrab-smoke-output PROFILE=smoke CONFIG=config/era5_soilmoist_weekly_smoke.yml MODE=plan DRY_RUN=true bash hpc/submit_era5_soilmoist.sh
CDS_DATAGRAB_ROOT=/project/disease_ecology/cds-datagrab-smoke-output PROFILE=smoke CONFIG=config/era5_soilmoist_weekly_smoke.yml MODE=full DRY_RUN=false OBSERVED_END=2026-07-12 bash hpc/submit_era5_soilmoist.sh
```

The three-day acceptance is 3 valid daily, 0 invalid, 0 weekly written, 1 incomplete week, pipeline success. The seven-day acceptance is 7 valid daily, 0 invalid, 1 complete week, 1 weekly written, and `soilmoist_2026-W28.tif`.

## One-year staging and idempotence

Use the shared root `/project/disease_ecology/cds-datagrab-output` and run through `2022-12-31` only after the dry plan is reviewed:

```bash
CDS_DATAGRAB_ROOT=/project/disease_ecology/cds-datagrab-output PROFILE=production CONFIG=config/era5_soilmoist_production.yml MODE=full DRY_RUN=false OBSERVED_END=2022-12-31 bash hpc/submit_era5_soilmoist.sh
```

Expected inventory is 365 valid daily rasters, 51 complete weekly rasters, and two incomplete boundary weeks. Review winter, spring, summer, and autumn rasters and independently calculate sample weekly means. Rerunning the same command should plan no dates, make no CDS requests, write no daily or weekly outputs, reuse 365 daily products and 51 weekly products, and finish successfully.

After those checks, advance cumulatively through 2023-12-31, 2024-12-31, 2025-12-31, and 2026-07-26, never concurrently. The validated final inventory is 1,668 daily and 238 complete weekly rasters, with zero invalid or missing dates.

## Provenance, reruns, and audits

Raw targets are `era5_soilmoist_daily_YYYY-MM_<request_hash>.nc`; daily and weekly outputs use the `soilmoist_` prefix. Run manifests record the variable specification hash, spatial-area hash, planned request hashes, active request hashes, source-map dates, template checksum, and value statistics.

Weekly outputs have `.json` sidecars containing ordered daily paths and SHA256 values, the weekly statistic, template checksum, algorithm version, input fingerprint, and output checksum. A matching readable raster and sidecar is reused. A missing sidecar, stale hash, changed daily checksum, changed statistic/template, bad geometry, or incomplete coverage causes one replacement and sidecar creation. Legacy weekly files without sidecars are therefore upgraded once, then reused.

## Interpretation limitations

ERA5 soil moisture is a model grid-cell volumetric water-content estimate, not a point observation. Bilinear projection and the template mask preserve the validated spatial architecture but do not increase physical resolution. Soil layer 1 is only the upper 0–7 cm; it should not be treated as total root-zone storage or converted to millimetres without an independently justified depth model.

# ERA5-Land staged request lifecycle

The production workflow separates remote CDS work from Atlas wall time:

```text
planned → submitted → processing → retrieved → local process/aggregate
                      ├──────────────→ failed
                      └──────────────→ expired
```

The durable registry is:

```text
data/<profile>/_sources/era5land_daily_mean_utc06/requests/request_registry.csv
```

Each monthly row is keyed by source family, request hash, start date, and end date. It records the CDS job URL/ID, request status and timestamps, local archive path, size, SHA-256 checksum, source/config provenance, and error fields. Registry writes are atomic.

## States and duplicate prevention

- `planned`: the monthly request is known locally but has no valid local archive or persisted active job.
- `submitted`: staging returned a durable CDS job URL/ID and persisted it immediately.
- `processing`: the job is queued/running, the remote endpoint is not ready, or a transfer produced an incomplete archive.
- `retrieved`: the local archive is valid, non-empty, readable as ZIP, and contains the expected eight NetCDF members.
- `expired`: CDS reports an expired/deleted request; the original job ID remains in the row.
- `failed`: staging or CDS reports a terminal failure.

Staging first validates/reuses a local archive, then reuses a registered job URL, and submits only when neither exists. The registry key and persisted URL prevent duplicate active CDS requests. The known legacy unavailable-file condition is migrated back to `processing` when a job URL remains and no valid local archive exists.

## Commands

The shell wrapper exposes the following actual options:

```bash
export CONFIG=config/era5land_daily_mean_utc06_production.yml
export CDS_DATAGRAB_ROOT=/project/disease_ecology/cds-datagrab-output

# Plan: no CDS contact and no Slurm submission.
bash hpc/submit_era5land_daily_mean.sh --config "$CONFIG" --output-root "$CDS_DATAGRAB_ROOT" --dry-run

# Stage missing monthly jobs and persist each result.
bash hpc/submit_era5land_daily_mean.sh --config "$CONFIG" --output-root "$CDS_DATAGRAB_ROOT" --stage-requests

# Query/retrieve registered jobs that are available.
bash hpc/submit_era5land_daily_mean.sh --config "$CONFIG" --output-root "$CDS_DATAGRAB_ROOT" --retrieve-requests

# Process validated local archives only; it never contacts CDS.
bash hpc/submit_era5land_daily_mean.sh --config "$CONFIG" --output-root "$CDS_DATAGRAB_ROOT" --process
```

The wrapper submits the stage, retrieve, and process modes to separate Slurm runners. The historical process/full wrapper is configured for a 72-hour wall time; stage and retrieval use shorter dedicated runners. The direct R CLI also supports `--mode aggregate` for a weekly-capable local pass and `--mode full` for its combined workflow:

```bash
Rscript scripts/run_era5land_daily_mean.R --help
Rscript scripts/run_era5land_daily_mean.R --config config/era5land_daily_mean_utc06_weekly_smoke.yml --output-root /project/disease_ecology/cds-datagrab-smoke-output --mode aggregate --dry-run false --start-date 2026-02-02 --end-date 2026-02-08
```

The shell wrapper has no separate aggregate option. Do not repeat stage/retrieve just because processing or aggregation must resume when the 55 monthly archives are already valid locally.

## Local processing and reuse

Processing reads only validated local archives. It extracts the shared archive under `extracted/<request_hash>/`, validates the eight-member inventory and source map, and fans out to product directories. Complete monthly requests are fast-forwarded without reopening source members. For an incomplete request, complete products are fast-forwarded and only incomplete products are processed. Existing valid TIFFs and request-specific sidecars are reused unless `--overwrite` is supplied.

The expected production acquisition is already present locally for the validated daily period. Inspect the registry and inventories before deciding that a new stage or retrieval pass is necessary; valid raw archives must not be re-downloaded merely to resume local work.

## Sidecar provenance repair

```bash
Rscript scripts/repair_era5land_daily_sidecar_provenance.R \
  --config "$CONFIG" --output-root "$CDS_DATAGRAB_ROOT"
Rscript scripts/repair_era5land_daily_sidecar_provenance.R \
  --config "$CONFIG" --output-root "$CDS_DATAGRAB_ROOT" --apply
```

The default is a dry-run audit. `--apply` mutates only whitelisted provenance fields in date-scoped sidecars, uses atomic JSON replacement, never rewrites TIFFs, and retains an audit CSV at `diagnostics/era5land_daily_sidecar_provenance_repair.csv`. Ambiguous mappings fail rather than being guessed, and repeat application is idempotent.

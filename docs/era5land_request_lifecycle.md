# ERA5-Land staged request lifecycle

The production workflow separates remote CDS work from Atlas wall time:

```text
PLAN
  ↓
STAGE CDS REQUESTS
  ↓
CDS PROCESSES REMOTELY
  ↓
RETRIEVE AVAILABLE RESULTS
  ↓
repeat retrieval until complete
  ↓
PROCESS DAILY RASTERS
  ↓
AGGREGATE WEEKLY RASTERS
```

The durable registry is stored at:

```text
data/<profile>/_sources/era5land_daily_mean_utc06/requests/request_registry.csv
```

Each monthly request has one row keyed by source family, request hash, start date,
and end date. The row records the CDS job URL and ID, state, timestamps, local
archive path, size, SHA-256 checksum, configuration checksum, and errors. Registry
writes use a temporary file in the same directory followed by an atomic replacement.

`--stage-requests` validates and reuses local ZIP archives, reuses any registered
CDS job, and submits only requests with neither. It calls `wf_request(...,
transfer = FALSE)` and persists the returned job URL immediately. It does not wait
for CDS processing or process rasters.

`--retrieve-requests` first queries each persisted CDS job endpoint for structured
remote state. Queued/running jobs remain `processing` and do not invoke
`wf_transfer()`. Successful jobs are passed to `wf_transfer()`. Available ZIPs
are validated for the expected eight NetCDF members, moved into the deterministic
raw path atomically, and recorded with their checksum. The known legacy
`Your requested file is unavailable - check url` registry state is migrated to
`processing` when its job URL is still present and no valid local archive exists.
Explicitly failed jobs become `failed`; expired jobs become `expired` with their
original job ID retained. A retrieval pass with pending jobs exits successfully.

`--process` reads only locally retrieved, validated archives and performs extraction,
daily raster processing, and weekly aggregation. It never contacts CDS. `--execute`
is a resumable convenience mode that stages, performs one non-blocking retrieval
pass, and processes only when all source requests are locally available.

Processing is restartable at both monthly-request and product level. Before reading
an archive, `--process` validates every expected daily TIFF, sidecar, template/range
check, and request hash for the configured products. A complete month is fast-forwarded;
for a partial month, complete products are reused and only incomplete products read
their extracted member. Existing valid TIFFs are reused and are never overwritten
unless `--overwrite` is supplied. Daily sidecars carry the source-family request hash,
monthly dates, archive path, member, and alias for the request that generated them.

Sidecars written by older versions can be audited and repaired without rebuilding
rasters:

```bash
Rscript scripts/repair_era5land_daily_sidecar_provenance.R --config "$CONFIG" --output-root "$CDS_DATAGRAB_ROOT"
Rscript scripts/repair_era5land_daily_sidecar_provenance.R --config "$CONFIG" --output-root "$CDS_DATAGRAB_ROOT" --apply
```

The repair utility defaults to dry-run, updates only whitelisted provenance fields,
and writes an audit CSV in apply mode. Historical process jobs use a 72-hour wall-time;
staging and retrieval remain separate and should not be rerun merely because local
processing is restarted.

For the production output root, the operational commands are:

```bash
export CDS_DATAGRAB_ROOT=/project/disease_ecology/cds-datagrab-output
export CONFIG=config/era5land_daily_mean_utc06_production.yml

# Inventory only: no CDS contact and no Slurm submission.
bash hpc/submit_era5land_daily_mean.sh --config "$CONFIG" --output-root "$CDS_DATAGRAB_ROOT" --dry-run

# Stage the missing monthly requests and exit after durable persistence.
bash hpc/submit_era5land_daily_mean.sh --config "$CONFIG" --output-root "$CDS_DATAGRAB_ROOT" --stage-requests

# Re-run as often as needed; pending CDS work is not a Slurm failure.
bash hpc/submit_era5land_daily_mean.sh --config "$CONFIG" --output-root "$CDS_DATAGRAB_ROOT" --retrieve-requests

# Once the inventory reports no pending requests, process local archives.
bash hpc/submit_era5land_daily_mean.sh --config "$CONFIG" --output-root "$CDS_DATAGRAB_ROOT" --process
```

Existing valid raw archives are recognized by their deterministic request stem,
non-zero size, ZIP readability, and eight-member ERA5-Land structure. Their old
CDS job IDs are not required. A partial transfer remains outside the final raw
path and leaves the request retryable.

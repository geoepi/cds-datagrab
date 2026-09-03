#!/bin/bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-${SLURM_SUBMIT_DIR:-$(pwd)}}"
CDS_DATAGRAB_ROOT="${CDS_DATAGRAB_ROOT:-/project/disease_ecology/cds-datagrab-output}"
PROFILE="${PROFILE:-production}"
CONFIG="${CONFIG:-config/era5_mintemp_production.yml}"
MODE="${MODE:-full}"
DRY_RUN="${DRY_RUN:-false}"
OBSERVED_END="${OBSERVED_END:-}"
START_DATE="${START_DATE:-}"
END_DATE="${END_DATE:-}"
CHIME_EXECUTION_ID="${CHIME_EXECUTION_ID:-}"

[[ "$PROFILE" == production ]] || { echo "PROFILE must be production" >&2; exit 2; }
cds_datagrab_validate_chime_execution_id
[[ -n "$OBSERVED_END" ]] || { echo "OBSERVED_END is required for production submissions" >&2; exit 2; }
if ! normalized_end=$(date -d "$OBSERVED_END" +%F 2>/dev/null); then
  echo "OBSERVED_END must be a valid ISO date: $OBSERVED_END" >&2; exit 2
fi
[[ "$normalized_end" < 2022-01-01 ]] && { echo "OBSERVED_END cannot precede 2022-01-01" >&2; exit 2; }
[[ -n "$CDS_DATAGRAB_ROOT" && "$CDS_DATAGRAB_ROOT" != "/" ]] || { echo "Unsafe empty/root CDS_DATAGRAB_ROOT" >&2; exit 2; }
mkdir -p "$CDS_DATAGRAB_ROOT/logs/slurm/production"
[[ -d "$CDS_DATAGRAB_ROOT" && -w "$CDS_DATAGRAB_ROOT" ]] || { echo "CDS_DATAGRAB_ROOT is not writable: $CDS_DATAGRAB_ROOT" >&2; exit 2; }
root_abs=$(cd "$CDS_DATAGRAB_ROOT" && pwd -P)
repo_abs=$(cd "$REPO_DIR" && pwd -P)
[[ "$root_abs" != "$repo_abs" ]] || { echo "CDS_DATAGRAB_ROOT cannot be the repository root" >&2; exit 2; }
marker="$root_abs/.cds-datagrab-root"
if [[ -e "$marker" ]]; then
  grep -q '"application"[[:space:]]*:[[:space:]]*"cds-datagrab"' "$marker" || { echo "Invalid cds-datagrab root marker: $marker" >&2; exit 2; }
else
  (umask 077; printf '{"application":"cds-datagrab","schema_version":1,"created_utc":"%s"}\n' "$(date -u +%FT%TZ)" > "$marker") || { echo "Could not create root marker: $marker" >&2; exit 2; }
  grep -q '"application"[[:space:]]*:[[:space:]]*"cds-datagrab"' "$marker" || { echo "Could not validate root marker: $marker" >&2; exit 2; }
fi

# The shared wrapper owns submission and pipeline logic; this wrapper only supplies
# production defaults and validates the explicit endpoint/root contract.
export REPO_DIR CDS_DATAGRAB_ROOT PROFILE CONFIG MODE DRY_RUN OBSERVED_END START_DATE END_DATE CHIME_EXECUTION_ID
exec "$REPO_DIR/hpc/submit_era5_mintemp.sh"

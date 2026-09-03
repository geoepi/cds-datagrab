#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="${REPO_DIR:-${SLURM_SUBMIT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd -P)}}"
source "$SCRIPT_DIR/lib/cds_datagrab_env.sh"
CONFIG="${CONFIG:?CONFIG must be set by the variable wrapper}"
MODE="${MODE:-plan}"; DRY_RUN="${DRY_RUN:-true}"; OBSERVED_END="${OBSERVED_END:-auto}"; FUTURE_END="${FUTURE_END:-}"; START_DATE="${START_DATE:-}"; END_DATE="${END_DATE:-}"
CDS_DATAGRAB_R_LIB="${CDS_DATAGRAB_R_LIB:?CDS_DATAGRAB_R_LIB must point to the external installed cdsdatagrab library}"
case ":${R_LIBS_USER:-}:" in *":$CDS_DATAGRAB_R_LIB:"*) ;; "::") R_LIBS_USER="$CDS_DATAGRAB_R_LIB" ;; *) R_LIBS_USER="$CDS_DATAGRAB_R_LIB:${R_LIBS_USER}" ;; esac
R_LIBS_SITE="${R_LIBS_SITE:-}"
PROFILE="${PROFILE:-}"; JOB_NAME="${JOB_NAME:?JOB_NAME must be set by the variable wrapper}"
SLURM_OUTPUT="${SLURM_OUTPUT:?SLURM_OUTPUT must be set by the variable wrapper}"; SLURM_ERROR="${SLURM_ERROR:?SLURM_ERROR must be set by the variable wrapper}"
SBATCH_SCRIPT="${SBATCH_SCRIPT:-$REPO_DIR/hpc/run_era5_variable.slurm}"
[[ "$CDS_DATAGRAB_ROOT" != "/" && -n "$CDS_DATAGRAB_ROOT" ]] || { echo "CDS_DATAGRAB_ROOT is unsafe" >&2; exit 2; }
[[ "$PROFILE" == smoke || "$PROFILE" == production ]] || { echo "PROFILE must be smoke or production" >&2; exit 2; }
cds_datagrab_prepare_environment
if [[ -n "$START_DATE" || -n "$END_DATE" ]]; then cds_datagrab_validate_window; fi
mkdir -p "$CDS_DATAGRAB_ROOT/logs/slurm/$PROFILE"
export REPO_DIR PROFILE CONFIG MODE DRY_RUN OBSERVED_END FUTURE_END START_DATE END_DATE CDS_DATAGRAB_ROOT CDS_DATAGRAB_R_LIB R_LIBS_USER CHIME_EXECUTION_ID
if [[ "${DIRECT_EXECUTION:-false}" == "true" ]]; then
  bash "$SBATCH_SCRIPT"
  exit 0
fi
job_id=$(sbatch --parsable --job-name="$JOB_NAME" --output="$SLURM_OUTPUT" --error="$SLURM_ERROR" --export=ALL,CDS_DATAGRAB_ROOT="$CDS_DATAGRAB_ROOT",CDS_DATAGRAB_R_LIB="$CDS_DATAGRAB_R_LIB",R_LIBS_USER="$R_LIBS_USER",R_LIBS_SITE="${R_LIBS_SITE:-}",PROFILE="$PROFILE",CONFIG="$CONFIG",MODE="$MODE",DRY_RUN="$DRY_RUN",OBSERVED_END="$OBSERVED_END",FUTURE_END="$FUTURE_END",START_DATE="$START_DATE",END_DATE="$END_DATE",CHIME_EXECUTION_ID="$CHIME_EXECUTION_ID" "$SBATCH_SCRIPT")
printf 'submitted job ID: %s\njob name: %s\nconfiguration: %s\nmode: %s\nconfigured/effective window override: %s to %s\noutput root: %s\nstdout path pattern: %s\nstderr path pattern: %s\n' "$job_id" "$JOB_NAME" "$CONFIG" "$MODE" "${START_DATE:-configured}" "${END_DATE:-configured}" "$CDS_DATAGRAB_ROOT" "$SLURM_OUTPUT" "$SLURM_ERROR"

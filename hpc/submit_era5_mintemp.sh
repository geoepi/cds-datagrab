#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; REPO_DIR="${REPO_DIR:-${SLURM_SUBMIT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd -P)}}"; source "$SCRIPT_DIR/lib/cds_datagrab_env.sh"
CONFIG="${CONFIG:-config/era5_mintemp.yml}"; MODE="${MODE:-plan}"; DRY_RUN="${DRY_RUN:-true}"; OBSERVED_END="${OBSERVED_END:-auto}"; FUTURE_END="${FUTURE_END:-}"; PROFILE="${PROFILE:-}"
START_DATE="${START_DATE:-}"; END_DATE="${END_DATE:-}"
cds_datagrab_prepare_environment; [[ -n "${START_DATE:-}" || -n "${END_DATE:-}" ]] && cds_datagrab_validate_window; mkdir -p "$CDS_DATAGRAB_ROOT/logs/slurm/$PROFILE"
export REPO_DIR CONFIG PROFILE CDS_DATAGRAB_ROOT CDS_DATAGRAB_R_LIB MODE DRY_RUN OBSERVED_END FUTURE_END START_DATE END_DATE CHIME_EXECUTION_ID
JOB_NAME="cds_mint" SLURM_OUTPUT="${SLURM_OUTPUT:-$CDS_DATAGRAB_ROOT/logs/slurm/$PROFILE/cds_mintemp_%j.out}" SLURM_ERROR="${SLURM_ERROR:-$CDS_DATAGRAB_ROOT/logs/slurm/$PROFILE/cds_mintemp_%j.err}" SBATCH_SCRIPT="${SBATCH_SCRIPT:-$REPO_DIR/hpc/run_era5_variable.slurm}" bash "$REPO_DIR/hpc/submit_era5_variable.sh"

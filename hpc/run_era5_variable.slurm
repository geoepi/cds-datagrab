#!/bin/bash
# Shared ERA5 variable worker. Job identity and log paths are supplied by sbatch.
#SBATCH -A disease_ecology
#SBATCH -N 1
#SBATCH -n 1
#SBATCH --cpus-per-task=4
#SBATCH --time=12:00:00
#SBATCH --mem=32G
set -euo pipefail
REPO_DIR="${REPO_DIR:-${SLURM_SUBMIT_DIR}}"
source "$REPO_DIR/hpc/lib/cds_datagrab_env.sh"
cds_datagrab_load_atlas_modules
CONFIG="${CONFIG:?CONFIG must be set}"; MODE="${MODE:-plan}"; DRY_RUN="${DRY_RUN:-true}"; OBSERVED_END="${OBSERVED_END:-auto}"; FUTURE_END="${FUTURE_END:-}"; START_DATE="${START_DATE:-}"; END_DATE="${END_DATE:-}"; CHIME_EXECUTION_ID="${CHIME_EXECUTION_ID:-}"
CDS_DATAGRAB_ROOT="${CDS_DATAGRAB_ROOT:?CDS_DATAGRAB_ROOT must be set}"
CDS_DATAGRAB_R_LIB="${CDS_DATAGRAB_R_LIB:?CDS_DATAGRAB_R_LIB must point to the external installed cdsdatagrab library}"
case ":${R_LIBS_USER:-}:" in *":$CDS_DATAGRAB_R_LIB:"*) ;; "::") R_LIBS_USER="$CDS_DATAGRAB_R_LIB" ;; *) R_LIBS_USER="$CDS_DATAGRAB_R_LIB:${R_LIBS_USER}" ;; esac
R_LIBS_SITE="${R_LIBS_SITE:-}"
export CDS_DATAGRAB_R_LIB R_LIBS_USER R_LIBS_SITE CHIME_EXECUTION_ID
case "${DRY_RUN,,}" in true|1|yes) EXECUTION_FLAG="--dry-run" ;; false|0|no) EXECUTION_FLAG="--execute" ;; *) echo "DRY_RUN must be true or false; received: ${DRY_RUN}" >&2; exit 2 ;; esac
cd "$REPO_DIR"
hostname; date; git status --short || true; git rev-parse HEAD || true; module list 2>&1; R --version
Rscript "$REPO_DIR/hpc/preflight_cdsdatagrab.R"
Rscript scripts/check_dependencies.R --mode "$MODE"
args=(scripts/run_pipeline.R --config "$CONFIG" --mode "$MODE" --output-root "$CDS_DATAGRAB_ROOT" "$EXECUTION_FLAG")
if [[ "$OBSERVED_END" != "auto" ]]; then args+=(--observed-end "$OBSERVED_END"); fi
if [[ -n "$FUTURE_END" ]]; then args+=(--future-end "$FUTURE_END"); fi
if [[ -n "$START_DATE" ]]; then args+=(--start-date "$START_DATE"); fi
if [[ -n "$END_DATE" ]]; then args+=(--end-date "$END_DATE"); fi
printf 'Rscript'; printf ' %q' "${args[@]}"; printf '\n'; echo "CDS token validation will occur inside R."; Rscript "${args[@]}"

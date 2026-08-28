#!/usr/bin/env bash
#SBATCH -A disease_ecology
#SBATCH -N 1
#SBATCH -n 1
#SBATCH --cpus-per-task=4
#SBATCH --time=72:00:00
#SBATCH --mem=32G
set -euo pipefail
REPO_DIR="${REPO_DIR:-${SLURM_SUBMIT_DIR}}"; source "$REPO_DIR/hpc/lib/cds_datagrab_env.sh"; cds_datagrab_load_atlas_modules
Rscript "$REPO_DIR/hpc/preflight_cdsdatagrab.R"; cds_datagrab_check_dependencies
args=("$REPO_DIR/scripts/run_era5land_daily_mean.R" --config "$CONFIG" --mode "$MODE" --output-root "$CDS_DATAGRAB_ROOT" --products "$PRODUCT_IDS")
case "${DRY_RUN,,}" in true|1|yes) args+=(--dry-run true);; false|0|no) args+=(--dry-run false);; *) echo "DRY_RUN must be true or false" >&2; exit 2;; esac
[[ "${OVERWRITE:-false}" == true ]] && args+=(--overwrite)
[[ "${REBUILD_ALL_WEEKS:-false}" == true ]] && args+=(--rebuild-all-weeks)
[[ -n "${START_DATE:-}" ]] && args+=(--start-date "$START_DATE"); [[ -n "${END_DATE:-}" ]] && args+=(--end-date "$END_DATE"); exec Rscript "${args[@]}"

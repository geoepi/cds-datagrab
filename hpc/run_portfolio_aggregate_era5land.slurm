#!/bin/bash
#SBATCH -A disease_ecology
#SBATCH -N 1
#SBATCH -n 1
#SBATCH --cpus-per-task=4
#SBATCH --time=48:00:00
#SBATCH --mem=32G
set -euo pipefail
REPO_DIR="${REPO_DIR:-${SLURM_SUBMIT_DIR}}"
source "$REPO_DIR/hpc/lib/cds_datagrab_env.sh"
cds_datagrab_load_atlas_modules
CONFIG="${CONFIG:?CONFIG must be set}"
PRODUCT_IDS="${PRODUCT_IDS:?PRODUCT_IDS must be set}"
CDS_DATAGRAB_ROOT="${CDS_DATAGRAB_ROOT:?CDS_DATAGRAB_ROOT must be set}"
START_DATE="${START_DATE:?START_DATE must be set}"
END_DATE="${END_DATE:?END_DATE must be set}"
export CDS_DATAGRAB_R_LIB R_LIBS_USER="${CDS_DATAGRAB_R_LIB}:${HOME_R_LIB}"
cds_datagrab_verify_commits
Rscript "$REPO_DIR/hpc/preflight_cdsdatagrab.R"
cd "$REPO_DIR"
Rscript scripts/run_era5land_daily_mean.R --config "$CONFIG" --mode aggregate --dry-run false --output-root "$CDS_DATAGRAB_ROOT" --products "$PRODUCT_IDS" --start-date "$START_DATE" --end-date "$END_DATE"

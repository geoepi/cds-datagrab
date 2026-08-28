#!/usr/bin/env bash
#SBATCH -A disease_ecology
#SBATCH -N 1
#SBATCH -n 1
#SBATCH --cpus-per-task=1
#SBATCH --time=02:00:00
#SBATCH --mem=8G
set -euo pipefail
REPO_DIR="${REPO_DIR:-${SLURM_SUBMIT_DIR}}"
source "$REPO_DIR/hpc/lib/cds_datagrab_env.sh"
source "$REPO_DIR/hpc/lib/run_era5land_daily_mean_mode.sh"
cds_datagrab_load_atlas_modules
cds_datagrab_run_era5land_mode

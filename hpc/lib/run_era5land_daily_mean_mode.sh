#!/usr/bin/env bash
set -euo pipefail

cds_datagrab_run_era5land_mode() {
  local -a args
  Rscript "$REPO_DIR/hpc/preflight_cdsdatagrab.R"
  cds_datagrab_check_dependencies
  args=("$REPO_DIR/scripts/run_era5land_daily_mean.R" --config "$CONFIG" --mode "$MODE" --output-root "$CDS_DATAGRAB_ROOT" --products "$PRODUCT_IDS")
  case "${DRY_RUN,,}" in
    true|1|yes) args+=(--dry-run true) ;;
    false|0|no) args+=(--dry-run false) ;;
    *) echo "DRY_RUN must be true or false" >&2; return 2 ;;
  esac
  [[ "${OVERWRITE:-false}" == true ]] && args+=(--overwrite)
  [[ "${REBUILD_ALL_WEEKS:-false}" == true ]] && args+=(--rebuild-all-weeks)
  [[ -n "${START_DATE:-}" ]] && args+=(--start-date "$START_DATE")
  [[ -n "${END_DATE:-}" ]] && args+=(--end-date "$END_DATE")
  exec Rscript "${args[@]}"
}

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="${REPO_DIR:-${SLURM_SUBMIT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd -P)}}"
source "$SCRIPT_DIR/lib/cds_datagrab_env.sh"

usage() {
  cat <<'USAGE'
Usage: bash hpc/submit_era5land_daily_mean.sh [options]

Required execution option (exactly one):
  --dry-run                    Plan locally; do not submit a Slurm job.
  --stage-requests             Submit missing CDS requests and exit after persistence.
  --retrieve-requests          Retrieve available registered CDS results.
  --process                    Process locally retrieved archives only.
  --execute                    Submit the rendered full workflow to Slurm.

Other options:
  --config PATH                Configuration file.
  --output-root PATH           Explicit output root; overrides profile defaults.
  --overwrite                  Replace existing daily/weekly outputs.
  --rebuild-all-weeks         Rebuild all complete weeks in the selected window.
  --help                      Show this help text.
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 2
}

require_value() {
  local option="$1"
  [[ $# -ge 2 && -n "${2:-}" && "${2:-}" != --* ]] || die "$option requires a value"
}

CONFIG="${CONFIG:-config/era5land_daily_mean_utc06_smoke.yml}"
OUTPUT_ROOT_ARG=""
EXECUTION_MODE=""
OVERWRITE="false"
REBUILD_ALL_WEEKS="false"
START_DATE="${START_DATE:-}"
END_DATE="${END_DATE:-}"
PRODUCT="era5land_daily_mean_utc06"
PRODUCT_IDS="${PRODUCT_IDS:-era5land_tmean,era5land_soiltemp_l1_mean,era5land_soiltemp_l2_mean,era5land_soilwater_l1_mean,era5land_soilwater_l2_mean,era5land_surface_pressure_mean,era5land_lai_high_mean,era5land_lai_low_mean}"

while (( $# > 0 )); do
  case "$1" in
    --config)
      require_value "$1" "${2:-}"
      [[ -z "${CONFIG_FROM_CLI:-}" ]] || die "--config was supplied more than once"
      CONFIG_FROM_CLI=true; CONFIG="$2"; shift 2 ;;
    --output-root)
      require_value "$1" "${2:-}"
      [[ -z "${OUTPUT_ROOT_FROM_CLI:-}" ]] || die "--output-root was supplied more than once"
      OUTPUT_ROOT_FROM_CLI=true; OUTPUT_ROOT_ARG="$2"; shift 2 ;;
    --dry-run|--stage-requests|--retrieve-requests|--process|--execute)
      [[ -z "$EXECUTION_MODE" ]] || die "workflow execution options are mutually exclusive"
      case "$1" in
        --dry-run) EXECUTION_MODE="dry-run";;
        --stage-requests) EXECUTION_MODE="stage";;
        --retrieve-requests) EXECUTION_MODE="retrieve";;
        --process) EXECUTION_MODE="process";;
        --execute) EXECUTION_MODE="execute";;
      esac
      shift ;;
    --overwrite)
      [[ "$OVERWRITE" == false ]] || die "--overwrite was supplied more than once"
      OVERWRITE="true"; shift ;;
    --rebuild-all-weeks)
      [[ "$REBUILD_ALL_WEEKS" == false ]] || die "--rebuild-all-weeks was supplied more than once"
      REBUILD_ALL_WEEKS="true"; shift ;;
    --help)
      usage; exit 0 ;;
    *)
      die "unknown option or positional argument: $1" ;;
  esac
done

[[ -n "$EXECUTION_MODE" ]] || die "exactly one workflow execution option is required"
if [[ -n "$OUTPUT_ROOT_ARG" ]]; then
  CDS_DATAGRAB_ROOT="$OUTPUT_ROOT_ARG"
  export CDS_DATAGRAB_ROOT
fi

if [[ "$EXECUTION_MODE" == dry-run ]]; then
  MODE="plan"
  DRY_RUN="true"
  cds_datagrab_prepare_plan_environment
else
  case "$EXECUTION_MODE" in
    stage) MODE="stage-requests";;
    retrieve) MODE="retrieve-requests";;
    process) MODE="process";;
    execute) MODE="full";;
  esac
  DRY_RUN="false"
  cds_datagrab_prepare_environment
fi

case "$MODE" in
  stage-requests) SLURM_RUNNER="run_era5land_daily_mean_stage.slurm";;
  retrieve-requests) SLURM_RUNNER="run_era5land_daily_mean_retrieve.slurm";;
  process) SLURM_RUNNER="run_era5land_daily_mean_process.slurm";;
  *) SLURM_RUNNER="run_era5land_daily_mean.slurm";;
esac

if [[ -n "$START_DATE" || -n "$END_DATE" ]]; then
  cds_datagrab_validate_window
fi

plan_args=(Rscript --vanilla "$REPO_DIR/hpc/plan_era5land_daily_mean.R" --config "$CONFIG" --output-root "$CDS_DATAGRAB_ROOT" --products "$PRODUCT_IDS")
[[ -n "$START_DATE" ]] && plan_args+=(--start-date "$START_DATE")
[[ -n "$END_DATE" ]] && plan_args+=(--end-date "$END_DATE")
plan_output="$("${plan_args[@]}")" || die "ERA5-Land submission plan could not be constructed"

plan_value() {
  local key="$1"
  printf '%s\n' "$plan_output" | awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

PLAN_START_DATE="$(plan_value START_DATE)"
PLAN_END_DATE="$(plan_value END_DATE)"
PRODUCT_COUNT="$(plan_value PRODUCT_COUNT)"
DAILY_EXPECTED="$(plan_value DAILY_EXPECTED)"
COMPLETE_WEEKS="$(plan_value COMPLETE_WEEKS)"
WEEKLY_EXPECTED="$(plan_value WEEKLY_EXPECTED)"
SOURCE_REQUEST_COUNT="$(plan_value SOURCE_REQUEST_COUNT)"
[[ "$SOURCE_REQUEST_COUNT" =~ ^[1-9][0-9]*$ ]] || die "ERA5-Land plan is inconsistent: source request count is zero"
[[ "$PRODUCT_COUNT" == 8 ]] || die "ERA5-Land plan is inconsistent: expected eight registered products, found $PRODUCT_COUNT"
[[ "$DAILY_EXPECTED" =~ ^[0-9]+$ && "$WEEKLY_EXPECTED" =~ ^[0-9]+$ ]] || die "ERA5-Land plan returned invalid output counts"

era5land_inventory_counts() {
  local daily=0 weekly=0 product daily_dir weekly_dir count
  local -a products
  IFS=',' read -r -a products <<< "$PRODUCT_IDS"
  for product in "${products[@]}"; do
    daily_dir="$CDS_DATAGRAB_ROOT/data/$PROFILE/$product/daily"
    weekly_dir="$CDS_DATAGRAB_ROOT/data/$PROFILE/$product/weekly"
    if [[ -d "$daily_dir" ]]; then
      count="$(find "$daily_dir" -maxdepth 1 -type f -name "${product}_*.tif" | wc -l)"
      daily=$((daily + count))
    fi
    if [[ -d "$weekly_dir" ]]; then
      count="$(find "$weekly_dir" -maxdepth 1 -type f -name "${product}_*.tif" | wc -l)"
      weekly=$((weekly + count))
    fi
  done
  printf '%s %s\n' "$daily" "$weekly"
}

read -r DAILY_INVENTORY WEEKLY_INVENTORY <<< "$(era5land_inventory_counts)"

render_inner_command() {
  local -a args
  args=(Rscript "$REPO_DIR/scripts/run_era5land_daily_mean.R" --config "$CONFIG" --mode "$MODE" --output-root "$CDS_DATAGRAB_ROOT" --products "$PRODUCT_IDS" --dry-run "$DRY_RUN")
  [[ "$OVERWRITE" == true ]] && args+=(--overwrite)
  [[ "$REBUILD_ALL_WEEKS" == true ]] && args+=(--rebuild-all-weeks)
  [[ -n "$START_DATE" ]] && args+=(--start-date "$START_DATE")
  [[ -n "$END_DATE" ]] && args+=(--end-date "$END_DATE")
  printf '%q' "${args[0]}"
  printf ' %q' "${args[@]:1}"
}

SOURCE_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo unavailable)"
INSTALLED_COMMIT="$(cat "${CDS_DATAGRAB_R_LIB}/.cds-datagrab-installed-commit" 2>/dev/null || echo unavailable)"
INNER_COMMAND="$(render_inner_command)"

  printf 'source family: era5land_daily_mean_utc06\nconfiguration: %s\nconfiguration checksum: %s\nprofile: %s\noutput root: %s (%s)\nexecution mode: %s\nworkflow mode: %s\neffective dates: %s through %s\nproducts (%s): %s\ndaily outputs expected: %s\ndaily outputs currently indexed: %s\ncomplete ISO weeks: %s\nweekly outputs expected: %s\nweekly outputs currently indexed: %s\nsource request count: %s\nsource commit: %s\ninstalled commit: %s\nrendered inner command: %s\n' \
  "$CONFIG" "$(sha256sum "$CONFIG" | awk '{print $1}')" "$PROFILE" "$CDS_DATAGRAB_ROOT" "$CDS_DATAGRAB_ROOT_SOURCE" "$EXECUTION_MODE" \
  "$MODE" \
  "$PLAN_START_DATE" "$PLAN_END_DATE" "$PRODUCT_COUNT" "$PRODUCT_IDS" "$DAILY_EXPECTED" "$DAILY_INVENTORY" "$COMPLETE_WEEKS" "$WEEKLY_EXPECTED" "$WEEKLY_INVENTORY" "$SOURCE_REQUEST_COUNT" "$SOURCE_COMMIT" "$INSTALLED_COMMIT" "$INNER_COMMAND"
printf 'request plan:\n%s\n' "$plan_output"

if [[ "$EXECUTION_MODE" == dry-run ]]; then
  printf 'CDS contacted: false\nSlurm job submitted: false\n'
  exit 0
fi

mkdir -p "$CDS_DATAGRAB_ROOT/logs/slurm/$PROFILE"
export REPO_DIR CONFIG PROFILE MODE DRY_RUN START_DATE END_DATE CDS_DATAGRAB_ROOT CDS_DATAGRAB_R_LIB PRODUCT_IDS EXECUTION_MODE OVERWRITE REBUILD_ALL_WEEKS
if [[ "${DIRECT_EXECUTION:-false}" == true ]]; then
  exec bash "$REPO_DIR/hpc/$SLURM_RUNNER"
fi

job_id="$(sbatch --parsable \
  --job-name="cds_era5land_daily_mean_${MODE}" \
  --output="$CDS_DATAGRAB_ROOT/logs/slurm/$PROFILE/cds_era5land_daily_mean_%j.out" \
  --error="$CDS_DATAGRAB_ROOT/logs/slurm/$PROFILE/cds_era5land_daily_mean_%j.err" \
  --export=ALL,REPO_DIR,CONFIG,PROFILE,MODE,DRY_RUN,START_DATE,END_DATE,CDS_DATAGRAB_ROOT,CDS_DATAGRAB_R_LIB,PRODUCT_IDS,EXECUTION_MODE,OVERWRITE,REBUILD_ALL_WEEKS \
  "$REPO_DIR/hpc/$SLURM_RUNNER")"
printf 'submitted job ID: %s\nSlurm log path: %s/logs/slurm/%s/cds_era5land_daily_mean_%%j.{out,err}\n' "$job_id" "$CDS_DATAGRAB_ROOT" "$PROFILE"

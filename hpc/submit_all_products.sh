#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="${REPO_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd -P)}"
source "$SCRIPT_DIR/lib/cds_datagrab_env.sh"

CONFIG="${PORTFOLIO_CONFIG:-config/production_portfolio.yml}"
THROUGH="latest-common"
MODE="plan"
OUTPUT_ROOT_ARG="${CDS_DATAGRAB_ROOT:-}"

die() { echo "ERROR: $*" >&2; exit 2; }
require_value() { [[ $# -ge 2 && -n "${2:-}" && "${2:-}" != --* ]] || die "$1 requires a value"; }
while (($#)); do
  case "$1" in
    --through) require_value "$1" "${2:-}"; THROUGH="$2"; shift 2;;
    --mode) require_value "$1" "${2:-}"; MODE="$2"; shift 2;;
    --output-root) require_value "$1" "${2:-}"; OUTPUT_ROOT_ARG="$2"; shift 2;;
    --config) require_value "$1" "${2:-}"; CONFIG="$2"; shift 2;;
    --help) echo "Usage: bash hpc/submit_all_products.sh --through latest-common|YYYY-MM-DD --mode plan|update [--output-root PATH]"; exit 0;;
    *) die "unknown option: $1";;
  esac
done
[[ "$MODE" == plan || "$MODE" == update ]] || die "--mode must be plan or update"
if [[ "$THROUGH" != latest-common && ! "$THROUGH" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then die "--through must be latest-common or YYYY-MM-DD"; fi
[[ -z "$OUTPUT_ROOT_ARG" ]] || export CDS_DATAGRAB_ROOT="$OUTPUT_ROOT_ARG"
export REPO_DIR CONFIG PROFILE=production
if [[ "$MODE" == plan ]]; then cds_datagrab_prepare_plan_environment; else cds_datagrab_prepare_environment; fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
PLAN_JSON="$TMP_DIR/portfolio_plan.json"
PLAN_OUTPUT="$TMP_DIR/portfolio_plan.txt"
Rscript --vanilla "$REPO_DIR/hpc/plan_production_portfolio.R" --config "$CONFIG" --output-root "$CDS_DATAGRAB_ROOT" --through "$THROUGH" --plan-json "$PLAN_JSON" > "$PLAN_OUTPUT"
plan_value() { awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$PLAN_OUTPUT"; }
COMMON_START="$(plan_value COMMON_START)"
COMMON_END="$(plan_value COMMON_END)"
WEEK_COUNT="$(plan_value COMPLETE_ISO_WEEK_COUNT)"
PRODUCT_COUNT="$(plan_value PRODUCT_COUNT)"
SOURCE_COUNT="$(plan_value SOURCE_WORKFLOW_COUNT)"

cat <<SUMMARY
Portfolio: production
Products: $PRODUCT_COUNT
Source workflows: $SOURCE_COUNT
Requested through: $THROUGH
SUMMARY
awk -F'|' '$1 == "AVAILABILITY" { printf "  %s\n", $2 ": " $3 "; " $4 "; " $5 }' "$PLAN_OUTPUT"
printf 'Common endpoint: %s through %s\nComplete ISO weeks: %s\n' "$COMMON_START" "$COMMON_END" "$WEEK_COUNT"
awk -F'|' '$1 == "PRODUCT" { printf "  %-36s daily %s/%s weekly %s/%s\n", $2, $5, $4, $7, $6 }' "$PLAN_OUTPUT"

chunk_starts=()
chunk_ends=()
start_year="${COMMON_START:0:4}"
end_year="${COMMON_END:0:4}"
for ((year=start_year; year<=end_year; year++)); do
  chunk_start="${year}-01-01"
  chunk_end="${year}-12-31"
  [[ "$year" == "$start_year" ]] && chunk_start="$COMMON_START"
  [[ "$year" == "$end_year" ]] && chunk_end="$COMMON_END"
  chunk_starts+=("$chunk_start")
  chunk_ends+=("$chunk_end")
done

render_standalone_command() {
  local config="$1" wrapper="$2" start="$3" end="$4"
  printf 'CONFIG=%q PROFILE=production MODE=full DRY_RUN=false START_DATE=%q END_DATE=%q CDS_DATAGRAB_ROOT=%q bash %q' \
    "$config" "$start" "$end" "$CDS_DATAGRAB_ROOT" "$wrapper"
}
render_era5land_command() {
  local config="$1" wrapper="$2" products="$3" start="$4" end="$5"
  printf 'CONFIG=%q PROFILE=production START_DATE=%q END_DATE=%q PRODUCT_IDS=%q SBATCH_SCRIPT=%q CDS_DATAGRAB_ROOT=%q bash %q --execute' \
    "$config" "$start" "$end" "$products" "$REPO_DIR/hpc/run_era5land_daily_mean.slurm" "$CDS_DATAGRAB_ROOT" "$wrapper"
}

echo "Child source commands:"
for i in "${!chunk_starts[@]}"; do
  echo "Annual child window: ${chunk_starts[$i]} through ${chunk_ends[$i]}"
  while IFS='|' read -r kind source config wrapper products; do
    [[ "$kind" == SOURCE ]] || continue
    if [[ "$source" == era5land_daily_mean_utc06 ]]; then render_era5land_command "$config" "$wrapper" "$products" "${chunk_starts[$i]}" "${chunk_ends[$i]}"; else render_standalone_command "$config" "$wrapper" "${chunk_starts[$i]}" "${chunk_ends[$i]}"; fi
    echo
  done < <(awk -F'|' '$1 == "SOURCE" { print }' "$PLAN_OUTPUT")
done

if [[ "$MODE" == plan ]]; then
  echo "Plan mode: CDS contacted: false; Slurm jobs submitted: false; production outputs modified: false"
  exit 0
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)_portfolio"
MANIFEST="$CDS_DATAGRAB_ROOT/runs/production/_portfolio/$RUN_ID/portfolio_manifest.json"
SOURCE_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo unavailable)"
INSTALLED_COMMIT="$(cat "${CDS_DATAGRAB_R_LIB}/.cds-datagrab-installed-commit" 2>/dev/null || echo unavailable)"
mkdir -p "$CDS_DATAGRAB_ROOT/logs/slurm/production"
Rscript --vanilla "$REPO_DIR/scripts/portfolio_manifest.R" --operation create --manifest "$MANIFEST" --plan-json "$PLAN_JSON" --output-root "$CDS_DATAGRAB_ROOT" --run-id "$RUN_ID" --source-commit "$SOURCE_COMMIT" --installed-commit "$INSTALLED_COMMIT" >/dev/null

declare -a source_pids=()
declare -a source_names=()
for i in "${!chunk_starts[@]}"; do
  while IFS='|' read -r kind source config wrapper products; do
    [[ "$kind" == SOURCE ]] || continue
    source_name="${source}__${chunk_starts[$i]:0:4}"
    source_names+=("$source_name")
    log="$TMP_DIR/source_${source_name}.log"
    if [[ "$source" == era5land_daily_mean_utc06 ]]; then
      ( eval "$(render_era5land_command "$config" "$wrapper" "$products" "${chunk_starts[$i]}" "${chunk_ends[$i]}")" >"$log" 2>&1 ) &
    else
      ( eval "$(render_standalone_command "$config" "$wrapper" "${chunk_starts[$i]}" "${chunk_ends[$i]}")" >"$log" 2>&1 ) &
    fi
    source_pids+=("$!")
  done < <(awk -F'|' '$1 == "SOURCE" { print }' "$PLAN_OUTPUT")
done

declare -A source_jobs=()
source_failed=0
for i in "${!source_pids[@]}"; do
  if ! wait "${source_pids[$i]}"; then source_failed=1; fi
  job_id="$(sed -n 's/^submitted job ID: //p' "$TMP_DIR/source_${source_names[$i]}.log" | tail -n 1 | tr -d '\r')"
  if [[ -z "$job_id" ]]; then source_failed=1; else source_jobs["${source_names[$i]}"]="$job_id"; fi
done
source_mapping=""
source_dependency_ids=()
for source in "${source_names[@]}"; do
  [[ -n "${source_jobs[$source]:-}" ]] || continue
  source_mapping+="${source}=${source_jobs[$source]},"
  source_dependency_ids+=("${source_jobs[$source]}")
done
source_mapping="${source_mapping%,}"
if (( source_failed )); then
  Rscript --vanilla "$REPO_DIR/scripts/portfolio_manifest.R" --operation update --manifest "$MANIFEST" --status source_failed --source-jobs "$source_mapping" --failure-stage source_submission --failure-message "One or more source workflows could not be submitted; inspect the captured child output" >/dev/null || true
  cat "$TMP_DIR"/source_*.log >&2
  exit 1
fi
Rscript --vanilla "$REPO_DIR/scripts/portfolio_manifest.R" --operation update --manifest "$MANIFEST" --status source_running --source-jobs "$source_mapping" >/dev/null
printf 'Portfolio run: %s\nSource jobs:\n' "$RUN_ID"
for source in "${source_names[@]}"; do printf '  %-30s %s\n' "$source" "${source_jobs[$source]}"; done
dependency="afterok:$(IFS=:; echo "${source_dependency_ids[*]}")"
echo "Aggregation dependency: $dependency"
declare -A aggregation_jobs=()
for i in "${!chunk_starts[@]}"; do
  while IFS='|' read -r kind source config wrapper products; do
    [[ "$kind" == SOURCE ]] || continue
    chunk_year="${chunk_starts[$i]:0:4}"
    if [[ "$source" == era5land_daily_mean_utc06 ]]; then
      # PRODUCT_IDS is comma-separated, while Slurm uses commas to delimit
      # --export entries.  Put the values in the submission environment and
      # export the complete environment so Slurm cannot truncate the family.
      job_id="$(REPO_DIR="$REPO_DIR" CONFIG="$config" PRODUCT_IDS="$products" START_DATE="${chunk_starts[$i]}" END_DATE="${chunk_ends[$i]}" CDS_DATAGRAB_ROOT="$CDS_DATAGRAB_ROOT" CDS_DATAGRAB_R_LIB="$CDS_DATAGRAB_R_LIB" sbatch --parsable --dependency="$dependency" --job-name="cds_portfolio_era5land_${chunk_year}_aggregate" --output="$CDS_DATAGRAB_ROOT/logs/slurm/production/cds_portfolio_era5land_${chunk_year}_aggregate_%j.out" --error="$CDS_DATAGRAB_ROOT/logs/slurm/production/cds_portfolio_era5land_${chunk_year}_aggregate_%j.err" --export=ALL "$REPO_DIR/hpc/run_portfolio_aggregate_era5land.slurm")"
      aggregation_jobs["era5land_daily_mean_utc06__${chunk_year}"]="$job_id"
    else
      product="$(printf '%s' "$products" | cut -d, -f1)"
      job_id="$(sbatch --parsable --dependency="$dependency" --job-name="cds_portfolio_${product}_${chunk_year}_aggregate" --output="$CDS_DATAGRAB_ROOT/logs/slurm/production/cds_portfolio_${product}_${chunk_year}_aggregate_%j.out" --error="$CDS_DATAGRAB_ROOT/logs/slurm/production/cds_portfolio_${product}_${chunk_year}_aggregate_%j.err" --export=ALL,REPO_DIR,CONFIG="$config",PRODUCT="$product",START_DATE="${chunk_starts[$i]}",END_DATE="${chunk_ends[$i]}",CDS_DATAGRAB_ROOT="$CDS_DATAGRAB_ROOT",CDS_DATAGRAB_R_LIB="$CDS_DATAGRAB_R_LIB" "$REPO_DIR/hpc/run_portfolio_aggregate_product.slurm")"
      aggregation_jobs["${product}__${chunk_year}"]="$job_id"
    fi
  done < <(awk -F'|' '$1 == "SOURCE" { print }' "$PLAN_OUTPUT")
done
agg_mapping=""
agg_dependency_ids=()
for key in "${!aggregation_jobs[@]}"; do
  agg_mapping+="${key}=${aggregation_jobs[$key]},"
  agg_dependency_ids+=("${aggregation_jobs[$key]}")
done
agg_mapping="${agg_mapping%,}"
Rscript --vanilla "$REPO_DIR/scripts/portfolio_manifest.R" --operation update --manifest "$MANIFEST" --status aggregation_running --aggregation-jobs "$agg_mapping" >/dev/null
aggregation_dependency="afterok:$(IFS=:; echo "${agg_dependency_ids[*]}")"
validation_job="$(sbatch --parsable --dependency="$aggregation_dependency" --job-name="cds_portfolio_validate" --output="$CDS_DATAGRAB_ROOT/logs/slurm/production/cds_portfolio_validate_%j.out" --error="$CDS_DATAGRAB_ROOT/logs/slurm/production/cds_portfolio_validate_%j.err" --export=ALL,REPO_DIR,PORTFOLIO_MANIFEST="$MANIFEST",CDS_DATAGRAB_R_LIB="$CDS_DATAGRAB_R_LIB" "$REPO_DIR/hpc/run_portfolio_validate.slurm")"
Rscript --vanilla "$REPO_DIR/scripts/portfolio_manifest.R" --operation update --manifest "$MANIFEST" --status validation_running --validation-job "$validation_job" >/dev/null
printf 'Aggregation jobs dependency: %s\nValidation job: %s\nManifest: %s\n' "$aggregation_dependency" "$validation_job" "$MANIFEST"

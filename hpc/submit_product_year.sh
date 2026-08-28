#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib/cds_datagrab_env.sh"
product=""; year=""; mode="plan"; output_root=""; end_date=""
while (($#)); do
  case "$1" in
    --product) product="$2"; shift 2;;
    --year) year="$2"; shift 2;;
    --mode) mode="$2"; shift 2;;
    --output-root) output_root="$2"; shift 2;;
    --end-date) end_date="$2"; shift 2;;
    *) echo "Unknown argument: $1" >&2; exit 2;;
  esac
done
case "$product" in
  era5_mintemp) wrapper="$SCRIPT_DIR/submit_era5_mintemp.sh"; config="config/era5_mintemp_production.yml";;
  era5_soilmoist) wrapper="$SCRIPT_DIR/submit_era5_soilmoist.sh"; config="config/era5_soilmoist_production.yml";;
  era5_lai_low) wrapper="$SCRIPT_DIR/submit_era5_lai_low.sh"; config="config/era5_lai_low_production.yml";;
  agera5_relhum_min) wrapper="$SCRIPT_DIR/submit_agera5_relhum_min.sh"; config="config/agera5_relhum_min_production.yml";;
  era5land_daily_mean_utc06) wrapper="$SCRIPT_DIR/submit_era5land_daily_mean.sh"; config="config/era5land_daily_mean_utc06_production.yml"; family_products="era5land_tmean,era5land_soiltemp_l1_mean,era5land_soiltemp_l2_mean,era5land_soilwater_l1_mean,era5land_soilwater_l2_mean,era5land_surface_pressure_mean,era5land_lai_high_mean,era5land_lai_low_mean";;
  era5land_tmean|era5land_soiltemp_l1_mean|era5land_soiltemp_l2_mean|era5land_soilwater_l1_mean|era5land_soilwater_l2_mean|era5land_surface_pressure_mean|era5land_lai_high_mean|era5land_lai_low_mean) wrapper="$SCRIPT_DIR/submit_era5land_daily_mean.sh"; config="config/era5land_daily_mean_utc06_production.yml"; family_products="$product";;
  *) echo "Unknown product identifier: $product" >&2; exit 2;;
esac
[[ "$year" =~ ^20(22|23|24|25|26)$ ]] || { echo "Year must be between 2022 and 2026" >&2; exit 2; }
[[ "$mode" == plan || "$mode" == execute ]] || { echo "Mode must be plan or execute" >&2; exit 2; }
export PRODUCT="$product" PRODUCT_IDS="${family_products:-}" CONFIG="$config" PROFILE=production START_DATE="${year}-01-01" END_DATE="${end_date:-${year}-12-31}" DRY_RUN=true CDS_DATAGRAB_ROOT="${output_root:-${CDS_DATAGRAB_ROOT:-}}"
if [[ "$mode" == execute ]]; then DRY_RUN=false; export DRY_RUN; fi
cds_datagrab_prepare_environment
cds_datagrab_validate_window
mkdir -p "$CDS_DATAGRAB_ROOT/logs/slurm/production"
cds_datagrab_print_summary
exec bash "$wrapper"

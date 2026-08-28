#!/usr/bin/env Rscript
args <- commandArgs(trailingOnly = TRUE)
`%||%` <- function(x, y) if (is.null(x) || length(x) == 0L) y else x
value <- function(flag, default = NULL) { i <- match(flag, args); if (is.na(i) || i == length(args)) default else args[[i + 1L]] }
if ("--help" %in% args || "-h" %in% args) {
  cat(paste0(
    "Usage: Rscript scripts/debug_era5land_slice.R --config PATH --product ID --date YYYY-MM-DD [--output-root PATH]\n\n",
    "Options:\n",
    "  --config PATH       ERA5-Land family configuration (default: smoke config)\n",
    "  --product ID        One of the eight ERA5-Land product identifiers\n",
    "  --date YYYY-MM-DD   Configured processing date to debug\n",
    "  --output-root PATH  Optional external cds-datagrab output root\n",
    "  --help, -h          Print this help and exit\n"
  ))
  quit(save = "no", status = 0L, runLast = FALSE)
}
config_path <- value("--config", "config/era5land_daily_mean_utc06_smoke.yml")
product_id <- value("--product")
date_text <- value("--date")
output_root <- value("--output-root")
if (is.null(product_id) || is.null(date_text)) stop("--product and --date are required", call. = FALSE)
date <- as.Date(date_text)
if (is.na(date)) stop("--date must be YYYY-MM-DD", call. = FALSE)

library(cdsdatagrab)
ids <- era5land_family_product_ids()
if (!product_id %in% ids) stop("Unknown ERA5-Land product: ", product_id, call. = FALSE)
cfg <- read_pipeline_config(config_path)
root <- resolve_project_root(dirname(config_path))
cfg <- resolve_config_paths(cfg, root, output_root, FALSE)
cfg <- validate_pipeline_config(cfg)
if (!identical(as.character(cfg$project$source_family_id), "era5land_daily_mean_utc06")) stop("Configuration is not an ERA5-Land family configuration", call. = FALSE)
family_dates <- era5land_expected_dates(cfg, dry_run = FALSE)
era5land_validate_debug_date(date, family_dates)
source_paths <- resolve_source_storage_paths(cfg, root, output_root, create = FALSE)
diag <- diagnose_spatial_domain(cfg$spatial$template_path, cfg$spatial$bbox_path, cfg)
requests <- build_era5land_daily_mean_requests(family_dates, diag$final_cds_area, cfg, ids)
request <- era5land_request_for_date(requests, date)
extracted_dir <- file.path(source_paths$extracted_dir, request$request_hash)
inventory_path <- file.path(extracted_dir, "member_inventory.csv")
if (!file.exists(inventory_path)) stop("No cached extraction for request hash ", request$request_hash, " at ", extracted_dir, call. = FALSE)
inventory <- utils::read.csv(inventory_path, stringsAsFactors = FALSE)
member <- cdsdatagrab:::era5land_member_for_product(inventory, product_id)
spec <- get_variable_spec(product_id)
member_request <- request; member_request$target <- basename(member$extracted_path)
member_map <- cdsdatagrab:::era5land_member_date_map(member, request, member_request)
member_map <- member_map[as.Date(member_map$date) == date, , drop = FALSE]
if (nrow(member_map) != 1L || !identical(as.character(as.Date(member_map$date[[1L]])), format(date, "%Y-%m-%d"))) stop("Expected exactly one selected product/date mapping for ", product_id, " on ", format(date), call. = FALSE)
pcfg <- cfg; pcfg$project$dataset_id <- product_id; pcfg$cds$variable <- spec$cds_variable; pcfg$cds$daily_statistic <- spec$daily_statistic; pcfg$paths <- list(root = source_paths$root)
pcfg <- resolve_config_paths(pcfg, root, source_paths$root, FALSE)
p <- resolve_storage_paths(pcfg, root, source_paths$root, create = TRUE)
run_id <- paste0("debug_era5land_slice_", product_id, "_", format(date, "%Y-%m-%d"), "_", format(Sys.time(), "%Y%m%dT%H%M%SZ", tz = "UTC"))
run_dir <- file.path(p$runs_root, run_id); fs::dir_create(run_dir, recurse = TRUE)
cat(sprintf("configured family dates: %s\n", paste(format(family_dates, "%Y-%m-%d"), collapse = ",")))
cat(sprintf("selected source request dates: %s\n", paste(format(as.Date(request$raw_request_dates), "%Y-%m-%d"), collapse = ",")))
cat(sprintf("selected source request hash: %s\n", request$request_hash))
cat(sprintf("cached extraction: %s\n", extracted_dir))
cat(sprintf("selected product: %s\n", product_id))
cat(sprintf("selected processing date: %s\n", format(date, "%Y-%m-%d")))
cat("CDS contacted: false\n")
support_mask_info <- getFromNamespace("era5land_support_mask_info", "cdsdatagrab")
support_info <- support_mask_info(cfg, terra::rast(cfg$spatial$template_path), required = TRUE)
cat(sprintf("master-template cells: %s\nERA5-Land-supported cells: %s\nstructurally unsupported cells: %s\nstructural support mask: %s\nunsupported-cell audit: %s\n", support_info$master_template_cells, support_info$era5land_supported_cells, support_info$unsupported_count, support_info$paths$support_mask, support_info$paths$unsupported_cells_audit))
result <- process_downloaded_variable(member$extracted_path, p$daily_dir, cfg$spatial$template_path, cfg$spatial$bbox_path, pcfg, spec,
  overwrite_dates = date, expected_dates = date, run_expected_dates = date, request_manifest = list(member_request), date_source_map = member_map, run_dir = run_dir)
if (length(result$coverage_diagnostics)) {
  for (record in result$coverage_diagnostics) {
    geometry <- record$donor_geometry %||% list()
    if (length(geometry)) {
      cat(sprintf("bilinear donor geometry matches template: %s\n", tolower(as.character(geometry$bilinear$compare_geom))))
      cat(sprintf("nearest donor geometry matches template: %s\n", tolower(as.character(geometry$nearest$compare_geom))))
      cat(sprintf("full donor vector length: template=%s bilinear=%s nearest=%s\n", record$full_value_vector_lengths[["template"]], record$full_value_vector_lengths[["bilinear"]], record$full_value_vector_lengths[["nearest"]]))
      cat(sprintf("donor validation range (processed units): [%s, %s]\n", record$source_range[[1L]], record$source_range[[2L]]))
    }
    cat(sprintf("target-grid supported: radius1=%s radius2=%s total=%s source-fallback-attempted=%s\n", record$target_ring_radius_1_supported_count %||% NA, record$target_ring_radius_2_supported_count %||% NA, record$target_grid_supported_count %||% NA, record$source_fallback_attempted_count %||% NA))
    for (detail in utils::head(record$details %||% list(), 3L)) {
      for (candidate in utils::head(detail$candidate_diagnostics %||% list(), 8L)) {
        cat(sprintf("donor-candidate: target=%s candidate=%s row=%s col=%s inside=%s bilinear=%s nearest=%s in_bilinear_pool=%s in_nearest_pool=%s\n", candidate$target_cell, candidate$candidate_cell, candidate$candidate_row, candidate$candidate_column, candidate$template_inside, candidate$bilinear_value, candidate$nearest_value, candidate$candidate_in_bilinear_donor_pool, candidate$candidate_in_nearest_donor_pool))
      }
    }
    known_details <- Filter(function(detail) any(vapply(detail$candidate_diagnostics %||% list(), function(candidate) identical(as.integer(candidate$target_cell), 6159L) || identical(as.integer(candidate$candidate_cell), 5866L), logical(1))), record$details %||% list())
    for (detail in known_details) {
      for (candidate in detail$candidate_diagnostics) {
        if (identical(as.integer(candidate$target_cell), 6159L) || identical(as.integer(candidate$candidate_cell), 5866L)) cat(sprintf("known-donor-candidate: target=%s candidate=%s row=%s col=%s inside=%s bilinear=%s nearest=%s in_bilinear_pool=%s in_nearest_pool=%s\n", candidate$target_cell, candidate$candidate_cell, candidate$candidate_row, candidate$candidate_column, candidate$template_inside, candidate$bilinear_value, candidate$nearest_value, candidate$candidate_in_bilinear_donor_pool, candidate$candidate_in_nearest_donor_pool))
      }
    }
    cat(sprintf("coverage: date=%s master=%s supported=%s structural=%s pre-repair-missing=%s pre-repair-missing-supported=%s components=%s repaired-supported=%s post-repair-unexpected-missing=%s outside-support-finite=%s outside-mask=%s\n", record$date %||% date, record$master_template_cells %||% NA, record$era5land_supported_cells %||% NA, record$structurally_unsupported_cells %||% NA, record$pre_repair_missing_cells %||% record$missing_inside_pre_repair_count %||% NA, record$pre_repair_missing_supported_cells %||% NA, length(record$component_records %||% list()), record$repair_count %||% NA, record$post_repair_unexpected_missing_cells %||% record$missing_inside_post_repair_count %||% NA, record$outside_support_finite_cells %||% NA, record$outside_mask_finite_cells %||% record$outside_mask_count %||% NA))
    if (length(record$component_records)) print(utils::head(utils::read.csv(record$coverage_diagnostic_paths[["component_csv"]]), 20L))
  }
}
if (length(result$processing_failures)) {
  failure <- result$processing_failures[[1L]]
  cat(sprintf("slice failed: product=%s date=%s stage=%s class=%s message=%s\n", product_id, failure$date %||% date, failure$stage %||% failure$processing_step, paste(failure$condition_class %||% failure$error_class, collapse = ","), failure$condition_message %||% failure$error_message), file = stderr())
  quit(save = "no", status = 1L, runLast = FALSE)
}
cat(sprintf("slice status=success output=%s run_dir=%s\n", paste(result$written, collapse = ","), run_dir))

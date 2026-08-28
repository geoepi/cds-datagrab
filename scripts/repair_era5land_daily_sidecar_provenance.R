#!/usr/bin/env Rscript

era5land_repair_tif_selection <- function(tif_path, prefix, selected_start, selected_end) {
  parsed <- parse_grid_filename(tif_path, prefix)
  if (!isTRUE(parsed$valid) || !identical(parsed$timestep, "daily")) {
    return(list(examine = TRUE, valid = FALSE, date = as.Date(NA), date_iso = NA_character_))
  }
  date <- normalize_date_vector(parsed$date, "daily TIFF date")
  start <- normalize_date_vector(selected_start, "selected repair start")
  end <- normalize_date_vector(selected_end, "selected repair end")
  if (length(date) != 1L || length(start) != 1L || length(end) != 1L || start > end) stop("Repair TIFF selection requires scalar dates and an increasing interval", call. = FALSE)
  list(examine = isTRUE(date >= start && date <= end), valid = TRUE, date = date, date_iso = canonical_iso_dates(date, "daily TIFF date")[[1L]])
}

usage <- function() {
  cat("Usage: Rscript scripts/repair_era5land_daily_sidecar_provenance.R --config PATH --output-root PATH [--apply] [--start-date YYYY-MM-DD] [--end-date YYYY-MM-DD]\n")
  quit(status = 2L)
}

args <- commandArgs(trailingOnly = TRUE)
value <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args) || startsWith(args[[i + 1L]], "--")) usage()
  args[[i + 1L]]
}
has_flag <- function(flag) flag %in% args
config_path <- value("--config", "config/era5land_daily_mean_utc06_production.yml")
output_root <- value("--output-root")
if (is.null(output_root) || !nzchar(output_root)) usage()
apply_changes <- has_flag("--apply")
start_text <- value("--start-date")
end_text <- value("--end-date")

project_root <- normalizePath(getwd(), winslash = "/", mustWork = TRUE)
while (!file.exists(file.path(project_root, "DESCRIPTION")) && dirname(project_root) != project_root) project_root <- dirname(project_root)
if (!file.exists(file.path(project_root, "DESCRIPTION"))) stop("Run the repair utility from inside the repository checkout", call. = FALSE)
invisible(lapply(list.files(file.path(project_root, "R"), pattern = "[.]R$", full.names = TRUE), source, local = FALSE))
config_path <- if (grepl("^(?:[A-Za-z]:|/|\\\\)", config_path)) config_path else file.path(project_root, config_path)
cfg <- read_pipeline_config(config_path)
attr(cfg, "config_path") <- normalizePath(config_path, winslash = "/", mustWork = TRUE)
attr(cfg, "project_root") <- project_root
cfg <- resolve_config_paths(cfg, project_root, output_root, FALSE)
cfg <- validate_pipeline_config(cfg)
if (!identical(as.character(cfg$project$source_family_id), "era5land_daily_mean_utc06")) stop("Configuration is not an ERA5-Land daily-mean source-family configuration", call. = FALSE)

configured_family_dates <- era5land_expected_dates(cfg, dry_run = FALSE)
selected_start <- normalize_date_vector(start_text %||% min(configured_family_dates), "start_date")
selected_end <- normalize_date_vector(end_text %||% max(configured_family_dates), "end_date")
if (length(selected_start) != 1L || length(selected_end) != 1L || selected_start > selected_end) stop("Repair date range must be a valid increasing date interval", call. = FALSE)
family_dates <- configured_family_dates[configured_family_dates >= selected_start & configured_family_dates <= selected_end]
domain <- diagnose_spatial_domain(cfg$spatial$template_path, cfg$spatial$bbox_path, cfg)
requests <- build_era5land_daily_mean_requests(family_dates, domain$final_cds_area, cfg, era5land_family_product_ids())
source_paths <- resolve_source_storage_paths(cfg, project_root, output_root, create = FALSE)

scalar <- function(x) if (is.null(x) || !length(x)) NA_character_ else as.character(x[[1L]])
audit_rows <- list()
add_audit <- function(product_id, date, tif_path, sidecar_path, old, new, before, after, status, message) {
  audit_rows[[length(audit_rows) + 1L]] <<- data.frame(
    product_id = product_id, date = date, tif_path = tif_path, sidecar_path = sidecar_path,
    request_hash_old = scalar(old$request_hash), request_hash_new = scalar(new$request_hash),
    source_member_old = scalar(old$source_member), source_member_new = scalar(new$source_member),
    source_archive_path_old = scalar(old$source_archive_path), source_archive_path_new = scalar(new$source_archive_path),
    sidecar_sha256_before = before, sidecar_sha256_after = after, status = status, message = message,
    stringsAsFactors = FALSE
  )
}

for (product_id in era5land_family_product_ids()) {
  spec <- get_variable_spec(product_id)
  pcfg <- cfg
  pcfg$project$dataset_id <- product_id
  pcfg$cds$variable <- spec$cds_variable
  pcfg$cds$daily_statistic <- spec$daily_statistic
  paths <- resolve_storage_paths(pcfg, project_root, output_root, create = FALSE)
  if (!dir.exists(paths$daily_dir)) next
  files <- list.files(paths$daily_dir, pattern = paste0("^", gsub("([][{}()+*^$|\\\\?.])", "\\\\1", spec$daily_filename_prefix), "_.*[.]tiff?$"), full.names = TRUE)
  inventory_cache <- new.env(parent = emptyenv())
  for (tif_path in files) {
    selection <- era5land_repair_tif_selection(tif_path, spec$daily_filename_prefix, selected_start, selected_end)
    if (!isTRUE(selection$examine)) next
    sidecar_path <- paste0(tif_path, ".json")
    if (!isTRUE(selection$valid)) {
      add_audit(product_id, NA_character_, tif_path, sidecar_path, list(), list(), NA_character_, NA_character_, "failed", "daily TIFF filename/date could not be parsed")
      next
    }
    date <- selection$date_iso
    matches <- vapply(requests, function(request) date %in% canonical_iso_dates(request$raw_request_dates, "request dates"), logical(1))
    if (sum(matches) != 1L) {
      add_audit(product_id, date, tif_path, sidecar_path, list(), list(), NA_character_, NA_character_, "ambiguous", paste0("date mapped to ", sum(matches), " monthly requests"))
      next
    }
    request <- requests[[which(matches)]]
    inventory_path <- file.path(source_paths$extracted_dir, request$request_hash, "member_inventory.csv")
    inventory <- if (exists(request$request_hash, inventory_cache, inherits = FALSE)) get(request$request_hash, inventory_cache) else {
      value <- if (file.exists(inventory_path)) tryCatch(utils::read.csv(inventory_path, stringsAsFactors = FALSE), error = function(e) NULL) else NULL
      assign(request$request_hash, value, inventory_cache); value
    }
    member <- if (!is.null(inventory) && "product_id" %in% names(inventory)) inventory[inventory$product_id == product_id, , drop = FALSE] else data.frame()
    if (nrow(member) != 1L) {
      add_audit(product_id, date, tif_path, sidecar_path, list(), list(), NA_character_, NA_character_, "failed", "could not identify exactly one extracted source member")
      next
    }
    source_map_path <- file.path(dirname(member$extracted_path[[1L]]), "source_map.csv")
    member_info <- list(member_name = member$member_name[[1L]], environmental_variable_alias = member$environmental_variable_alias[[1L]], archive_path = member$archive_path[[1L]], source_map_rows = if (file.exists(source_map_path)) nrow(utils::read.csv(source_map_path, stringsAsFactors = FALSE)) else 0L)
    old <- if (file.exists(sidecar_path)) tryCatch(jsonlite::read_json(sidecar_path, simplifyVector = FALSE), error = function(e) list()) else list()
    new <- tryCatch(era5land_annotation_fields(old, spec, request, member_info), error = function(e) list())
    repair <- era5land_repair_product_sidecar(sidecar_path, spec, request, member_info, apply = apply_changes)
    add_audit(product_id, date, tif_path, sidecar_path, old, new, repair$before, repair$after, repair$status, repair$message)
  }
}

audit <- if (length(audit_rows)) do.call(rbind, audit_rows) else data.frame()
if (isTRUE(apply_changes)) {
  diagnostics_dir <- file.path(output_root, "diagnostics")
  fs::dir_create(diagnostics_dir, recurse = TRUE)
  utils::write.csv(audit, file.path(diagnostics_dir, "era5land_daily_sidecar_provenance_repair.csv"), row.names = FALSE)
}
counts <- table(factor(audit$status, levels = c("already_correct", "needs_repair", "repaired", "ambiguous", "missing_sidecar", "failed")))
cat(sprintf("dry_run=%s examined=%d already_correct=%d needs_repair=%d ambiguous=%d missing_sidecar=%d failed=%d\n", !apply_changes, nrow(audit), counts[["already_correct"]], counts[["needs_repair"]], counts[["ambiguous"]], counts[["missing_sidecar"]], counts[["failed"]]))
if (isTRUE(apply_changes)) cat("audit_csv=", file.path(output_root, "diagnostics", "era5land_daily_sidecar_provenance_repair.csv"), "\n", sep = "") else if (nrow(audit)) print(audit[c("product_id", "date", "status", "message")], row.names = FALSE)

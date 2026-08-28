era5land_support_mask_paths <- function(config) {
  coverage <- config$coverage %||% list()
  list(support_mask = coverage$support_mask %||% NULL, unsupported_cells_audit = coverage$unsupported_cells_audit %||% NULL,
    local_target_radius_cells = as.integer(coverage$local_target_radius_cells %||% config$validation$coverage_max_donor_radius_cells %||% 2L),
    source_buffer_max_km = as.numeric(coverage$source_buffer_max_km %||% config$validation$coverage_max_source_buffer_km %||% 35))
}

era5land_is_family_config <- function(config, spec = NULL) {
  spec <- spec %||% tryCatch(get_variable_spec(config$project$dataset_id, config), error = function(e) NULL)
  !is.null(spec) && identical(as.character(spec$source_family_id %||% ""), "era5land_daily_mean_utc06")
}

era5land_support_mask_info <- function(config, template, required = FALSE) {
  if (!era5land_is_family_config(config)) return(NULL)
  paths <- era5land_support_mask_paths(config)
  if (is.null(paths$support_mask) || is.null(paths$unsupported_cells_audit)) {
    if (isTRUE(required)) stop("ERA5-Land support mask and unsupported-cell audit must be configured", call. = FALSE)
    return(NULL)
  }
  if (!file.exists(paths$support_mask)) stop("ERA5-Land support mask is missing: ", paths$support_mask, call. = FALSE)
  if (!file.exists(paths$unsupported_cells_audit)) stop("ERA5-Land support audit is missing: ", paths$unsupported_cells_audit, call. = FALSE)
  mask <- terra::rast(paths$support_mask)
  if (!isTRUE(terra::compareGeom(mask, template, stopOnError = FALSE, messages = FALSE))) stop("ERA5-Land support mask geometry does not match the master template", call. = FALSE)
  audit <- utils::read.csv(paths$unsupported_cells_audit, stringsAsFactors = FALSE)
  required_columns <- c("cell", "longitude", "latitude", "reason", "affected_products", "nearest_finite_source_distance_km", "source_request_hash", "representative_date", "support_decision_method")
  if (!all(required_columns %in% names(audit))) stop("ERA5-Land support audit is missing required columns", call. = FALSE)
  cells <- as.integer(audit$cell); master_values <- as.numeric(terra::values(template, mat = FALSE)); mask_values <- as.numeric(terra::values(mask, mat = FALSE))
  if (!length(cells) || anyNA(cells) || anyDuplicated(cells) || any(cells < 1L | cells > terra::ncell(template))) stop("ERA5-Land support audit cell IDs are invalid", call. = FALSE)
  if (any(is.na(master_values[cells]))) stop("ERA5-Land audited structural cells must be inside the master template", call. = FALSE)
  unsupported <- which(!is.na(master_values) & is.na(mask_values)); if (!identical(sort(as.integer(unsupported)), sort(cells))) stop("ERA5-Land support mask and audit cell IDs disagree", call. = FALSE)
  if (any(!is.na(mask_values) & is.na(master_values))) stop("ERA5-Land support mask contains finite values outside the master template", call. = FALSE)
  list(mask = mask, audit = audit, paths = paths, master_template_path = config$spatial$template_path %||% NA_character_, master_template_sha256 = if (file.exists(config$spatial$template_path %||% "")) digest::digest(file = config$spatial$template_path, algo = "sha256") else NA_character_, support_mask_sha256 = digest::digest(file = paths$support_mask, algo = "sha256"), audit_sha256 = digest::digest(file = paths$unsupported_cells_audit, algo = "sha256"), unsupported_cells = as.integer(cells), unsupported_count = length(cells), master_template_cells = sum(!is.na(master_values)), era5land_supported_cells = sum(!is.na(mask_values)), support_distance_threshold_km = paths$source_buffer_max_km)
}

era5land_support_provenance <- function(config) {
  template <- if (requireNamespace("terra", quietly = TRUE) && file.exists(config$spatial$template_path %||% "")) terra::rast(config$spatial$template_path) else NULL
  info <- if (!is.null(template)) era5land_support_mask_info(config, template, required = FALSE) else NULL
  if (is.null(info)) return(list())
  list(master_template_path = info$master_template_path, master_template_sha256 = info$master_template_sha256, era5land_support_mask_path = info$paths$support_mask, era5land_support_mask_sha256 = info$support_mask_sha256, unsupported_cells_audit_path = info$paths$unsupported_cells_audit, unsupported_cells_audit_sha256 = info$audit_sha256, structurally_unsupported_cell_count = info$unsupported_count, structurally_unsupported_cell_ids = info$unsupported_cells, structurally_unsupported_coordinates = info$audit[c("cell", "longitude", "latitude")], support_distance_threshold_km = info$support_distance_threshold_km, support_audit_request_hashes = unique(as.character(info$audit$source_request_hash)), support_audit_representative_dates = unique(as.character(info$audit$representative_date)))
}

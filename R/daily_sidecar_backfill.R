legacy_daily_sidecar_metadata <- function(tif_path, date, spec, template, validation) {
  raster <- terra::rast(tif_path)
  values <- as.numeric(terra::values(raster, mat = FALSE))
  finite <- is.finite(values)
  list(
    variable_id = spec$id,
    short_name = spec$short_name,
    long_name = spec$long_name,
    source_dataset = spec$dataset_short_name,
    source_variable = spec$cds_variable,
    output_units = spec$output_units,
    unit_conversion = spec$unit_conversion,
    daily_statistic = spec$daily_statistic,
    weekly_statistic = spec$weekly_statistic,
    spatial_interpolation = spec$spatial_interpolation,
    source_family_id = NA_character_,
    request_hash = NA_character_,
    request_start = NA_character_,
    request_end = NA_character_,
    source_member = NA_character_,
    source_alias = NA_character_,
    source_archive_path = NA_character_,
    source_map_rows = NA_integer_,
    daily_time_zone = spec$time_zone,
    daily_sampling_frequency = spec$frequency,
    daily_statistic_source = "legacy_daily_output",
    provenance_status = "legacy_backfilled_unresolved",
    provenance_note = "Historical source request and archive provenance were unavailable; unavailable fields are null.",
    date = as.character(date),
    variable_spec_hash = spec$variable_spec_hash,
    template_sha256 = template_fingerprint(template)$sha256,
    master_template_sha256 = template_fingerprint(template)$sha256,
    output_sha256 = digest::digest(file = tif_path, algo = "sha256"),
    output_minimum = if (any(finite)) min(values[finite]) else NA_real_,
    output_maximum = if (any(finite)) max(values[finite]) else NA_real_,
    non_na_count = sum(finite),
    na_count = sum(is.na(values)),
    output_reopened_valid = isTRUE(validation$valid),
    created_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
    backfill_utility = "backfill_daily_sidecars"
  )
}

atomic_write_sidecar_if_absent <- function(value, path) {
  fs::dir_create(dirname(path), recurse = TRUE)
  if (file.exists(path)) stop("sidecar appeared before atomic promotion", call. = FALSE)
  tmp <- tempfile(paste0(".", basename(path), ".tmp-"), tmpdir = dirname(path), fileext = ".json")
  on.exit(if (file.exists(tmp)) unlink(tmp, force = TRUE), add = TRUE)
  jsonlite::write_json(value, tmp, pretty = TRUE, auto_unbox = TRUE, null = "null", na = "null")
  checked <- tryCatch(jsonlite::read_json(tmp, simplifyVector = FALSE), error = function(e) e)
  if (inherits(checked, "error")) stop("Temporary sidecar failed validation: ", conditionMessage(checked), call. = FALSE)
  if (!file.rename(tmp, path)) stop("Could not atomically promote sidecar: ", path, call. = FALSE)
  invisible(path)
}

backfill_daily_sidecars <- function(config_path, output_root, product_id = NULL,
                                    start_date = NULL, end_date = NULL, apply = FALSE) {
  if (missing(output_root) || is.null(output_root) || !nzchar(output_root)) stop("output_root is required", call. = FALSE)
  project_root <- resolve_project_root(dirname(config_path))
  cfg <- read_pipeline_config(config_path)
  attr(cfg, "config_path") <- normalizePath(config_path, winslash = "/", mustWork = FALSE)
  attr(cfg, "project_root") <- project_root
  cfg <- resolve_config_paths(cfg, project_root, output_root, FALSE)
  cfg <- validate_pipeline_config(cfg)
  product_id <- as.character(product_id %||% cfg$project$dataset_id)
  if (length(product_id) != 1L || is.na(product_id)) stop("product_id must be one scalar product ID", call. = FALSE)
  cfg$project$dataset_id <- product_id
  spec <- get_variable_spec(product_id, cfg)
  paths <- resolve_storage_paths(cfg, project_root, output_root, create = FALSE)
  audit <- list()
  add <- function(status, date, tif_path, sidecar_path, message) {
    audit[[length(audit) + 1L]] <<- data.frame(
      product_id = product_id, date = as.character(date), tif_path = tif_path,
      sidecar_path = sidecar_path, status = status, message = message,
      stringsAsFactors = FALSE
    )
  }
  if (dir.exists(paths$daily_dir)) {
    files <- list.files(paths$daily_dir, pattern = "[.]tiff?$", full.names = TRUE, ignore.case = TRUE)
    selected_start <- as.Date(start_date %||% cfg$temporal$initial_start_date)
    selected_end <- as.Date(end_date %||% cfg$temporal$observed_end)
    if (anyNA(c(selected_start, selected_end)) || selected_start > selected_end) stop("Backfill date range is invalid", call. = FALSE)
    template <- tryCatch(terra::rast(cfg$spatial$template_path), error = function(e) NULL)
    if (is.null(template)) stop("Cannot validate sidecars without a readable template", call. = FALSE)
    for (tif_path in files) {
      parsed <- parse_grid_filename(tif_path, spec$daily_filename_prefix)
      sidecar_path <- paste0(tif_path, ".json")
      if (!isTRUE(parsed$valid) || !identical(parsed$timestep, "daily") || is.na(parsed$date)) {
        next
      }
      date <- as.Date(parsed$date)
      if (date < selected_start || date > selected_end) next
      if (file.exists(sidecar_path)) {
        existing <- tryCatch(jsonlite::read_json(sidecar_path, simplifyVector = FALSE), error = function(e) NULL)
        add(if (is.null(existing)) "failed" else "reused", date, tif_path, sidecar_path,
          if (is.null(existing)) "existing sidecar is invalid; left unchanged" else "existing sidecar retained")
        next
      }
      validation <- tryCatch(validate_daily_output(tif_path, date, template, cfg, variable_spec = spec), error = function(e) list(valid = FALSE, message = conditionMessage(e)))
      if (!isTRUE(validation$valid)) {
        add("failed", date, tif_path, sidecar_path, paste0("daily TIFF validation failed: ", validation$message %||% "unknown error"))
        next
      }
      metadata <- legacy_daily_sidecar_metadata(tif_path, date, spec, template, validation)
      if (!isTRUE(apply)) {
        add("planned", date, tif_path, sidecar_path, "valid legacy TIFF would receive a sidecar")
        next
      }
      if (file.exists(sidecar_path)) {
        add("reused", date, tif_path, sidecar_path, "sidecar appeared during backfill and was retained")
        next
      }
      written <- tryCatch({ atomic_write_sidecar_if_absent(metadata, sidecar_path); TRUE }, error = function(e) { add("failed", date, tif_path, sidecar_path, conditionMessage(e)); FALSE })
      if (written) add("written", date, tif_path, sidecar_path, "legacy sidecar written without rewriting TIFF")
    }
  }
  audit <- if (length(audit)) do.call(rbind, audit) else data.frame(product_id = character(), date = character(), tif_path = character(), sidecar_path = character(), status = character(), message = character(), stringsAsFactors = FALSE)
  list(status = if (any(audit$status == "failed")) "failed" else "success", audit = audit,
       written = sum(audit$status == "written"), planned = sum(audit$status == "planned"),
       reused = sum(audit$status == "reused"), failed = sum(audit$status == "failed"),
       output_root = output_root, product_id = product_id)
}

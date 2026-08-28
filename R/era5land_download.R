# Download postconditions and raw-artifact reuse. This file is loaded after the
# legacy downloader so the content-aware implementation is the active one.

validate_downloaded_target <- function(path, expected_request = NULL) {
  exists <- file.exists(path); size <- if (exists) as.numeric(file.info(path)$size) else 0
  format <- if (exists && size > 0) detect_container_type(path) else "unknown"
  readable <- FALSE; nc_ok <- FALSE; archive_readable <- FALSE; reason <- ""
  selected_reader <- NA_character_; selected_reader_metadata_readable <- FALSE
  scientific_variable_present <- FALSE; time_coordinate_readable <- FALSE; decoded_dates_valid <- FALSE
  if (!exists) reason <- "expected_target_not_created" else if (size <= 0) reason <- "target_zero_bytes" else if (format == "zip") {
    listing <- tryCatch(utils::unzip(path, list = TRUE), error = function(e) NULL)
    archive_readable <- !is.null(listing) && nrow(listing) > 0L
    readable <- archive_readable; scientific_variable_present <- archive_readable
    if (!readable) reason <- "zip_archive_not_readable"
  } else if (format %in% c("netcdf_classic", "netcdf4_hdf5")) {
    md <- tryCatch(inspect_netcdf_ncdf4(path), error = function(e) e)
    nc_ok <- !inherits(md, "error"); readable <- nc_ok; selected_reader <- if (nc_ok) "ncdf4" else NA_character_
    if (nc_ok) {
      family <- !is.null(expected_request) && identical(expected_request$source_family_id, "era5land_daily_mean_utc06")
      expected_spec <- if (family) get_variable_spec("era5land_tmean") else tryCatch(get_variable_spec(expected_request$variable), error = function(e) get_variable_spec("era5_mintemp"))
      selected <- if (family) unlist(lapply(expected_request$product_ids %||% .era5land_product_ids(), function(id) intersect(get_variable_spec(id)$netcdf_variable_names, names(md$variables)))) else intersect(expected_spec$netcdf_variable_names, names(md$variables))
      scientific_variable_present <- if (family) length(unique(selected)) == length(expected_request$product_ids %||% .era5land_product_ids()) else length(selected) > 0L
      time_coordinate_readable <- length(md$decoded_dates) > 0L
      expected_dates <- if (!is.null(expected_request)) normalize_date_vector(sprintf("%s-%s-%s", expected_request$year, expected_request$month, expected_request$day), "expected_dates") else as.Date(character())
      decoded_dates_valid <- time_coordinate_readable && (!length(expected_dates) || identical(format(md$decoded_dates, "%Y-%m-%d"), format(expected_dates, "%Y-%m-%d")))
      if (!length(md$coordinate_variables$latitude) || !length(md$coordinate_variables$longitude) || !scientific_variable_present || !decoded_dates_valid) {
        readable <- FALSE; nc_ok <- FALSE; reason <- "netcdf_metadata_incomplete_or_dates_mismatch"
      }
      if (nc_ok && length(selected) && !family) {
        source_units <- md$variables[[selected[[1L]]]]$units
        lai_dimensionless <- identical(expected_spec$id, "era5_lai_low") && tolower(trimws(as.character(source_units %||% ""))) %in% c("1", "dimensionless")
        if (!identical(normalize_source_units(source_units), normalize_source_units(expected_spec$source_units)) && !lai_dimensionless) {
          readable <- FALSE; nc_ok <- FALSE; reason <- "netcdf_source_units_mismatch"
        }
      }
      selected_reader_metadata_readable <- nc_ok
    }
  } else if (format == "grib") {
    readable <- TRUE; scientific_variable_present <- TRUE
  } else reason <- "unsupported_response_format"
  request_match <- NA
  if (readable && !is.null(expected_request)) {
    request_match <- identical(raw_request_stem(basename(path)), raw_request_stem(as.character(expected_request$target)))
    if (!request_match) reason <- "request_target_mismatch"
  } else if (readable) request_match <- TRUE
  valid <- exists && size > 0 && format %in% c("zip", "netcdf_classic", "netcdf4_hdf5", "grib") && readable && isTRUE(request_match)
  if (valid) reason <- "ok"
  list(path = normalizePath(path, winslash = "/", mustWork = FALSE), exists = exists, size = size, format = format,
    readable = readable, container_readable = readable, archive_readable = archive_readable, ncdf4_metadata_readable = nc_ok,
    gdal_metadata_readable = FALSE, selected_reader = selected_reader, selected_reader_metadata_readable = selected_reader_metadata_readable,
    scientific_variable_present = scientific_variable_present, time_coordinate_readable = time_coordinate_readable,
    decoded_dates_valid = decoded_dates_valid, netcdf_metadata_readable = nc_ok, request_match = request_match, valid = valid,
    failure_reason = reason)
}

download_result_row <- function(request, target, status, post, elapsed = NA_real_, returned = "", warnings = "", error_class = "", error_message = "", finalization = NULL) {
  data.frame(planned_target = request$target, target_filename = request$target, resolved_target_path = target, status = status, valid = post$valid, exists = post$exists,
    size = post$size, format = post$format, readable = post$readable, netcdf_metadata_readable = post$netcdf_metadata_readable,
    request_match = post$request_match, failure_reason = post$failure_reason, returned_path = returned, elapsed_seconds = elapsed,
    warnings = warnings, error_class = error_class, error_message = error_message,
    raw_original_path = finalization$original_raw_path %||% "", final_raw_path = finalization$final_raw_path %||% target,
    detected_container = finalization$detected_container %||% post$format, extension_content_match = finalization$extension_content_match %||% NA,
    file_size = finalization$file_size %||% post$size, sha256 = finalization$sha256 %||% NA_character_, raw_reused = isTRUE(finalization$raw_reused),
    partial_status = paste(finalization$partial_status %||% character(), collapse = ";"), stringsAsFactors = FALSE)
}

download_cds_requests <- function(requests, raw_dir = NULL, run_dir = NULL, dry_run = TRUE, overwrite = FALSE, workers = 1, paths = NULL, config = NULL, run_id = NULL, transfer_fun = NULL) {
  if (is.null(paths)) { paths <- list(raw_dir = raw_dir, dataset_root = dirname(raw_dir), root_marker = file.path(dirname(dirname(dirname(raw_dir))), ".cds-datagrab-root")); if (!file.exists(paths$root_marker)) stop("Storage root marker is missing", call. = FALSE) }
  fs::dir_create(paths$raw_dir, recurse = TRUE); if (is.null(run_id)) run_id <- basename(run_dir %||% "download")
  statuses <- lapply(requests, function(req) {
    validate_cds_request_structure(req); target <- resolve_download_target(req, paths); info <- find_reusable_raw_artifact(req, paths)
    candidates <- unique(c(info$candidates, info$partials)); existing_valid <- NULL; existing_path <- NULL
    if (!overwrite) for (candidate in candidates) { check <- validate_downloaded_target(candidate, req); if (isTRUE(check$valid)) { existing_valid <- check; existing_path <- candidate; break } }
    if (!is.null(existing_valid)) {
      finalized <- finalize_raw_artifact(existing_path, req, paths, run_dir, info$partials)
      final_check <- validate_downloaded_target(finalized$final_raw_path, req); finalized$raw_reused <- TRUE
      return(download_result_row(req, finalized$final_raw_path, "reused_existing", final_check, finalization = finalized))
    }
    if (length(info$candidates) && !dry_run) {
      qdir <- file.path(paths$raw_quarantine_dir %||% file.path(paths$dataset_root, "quarantine", "raw"), run_id); fs::dir_create(qdir, recurse = TRUE)
      for (candidate in info$candidates) if (file.exists(candidate)) fs::file_move(candidate, file.path(qdir, basename(candidate)), overwrite = FALSE)
    }
    if (dry_run) return(download_result_row(req, target, "planned", list(valid = NA, exists = NA, size = NA, format = NA, readable = NA, netcdf_metadata_readable = NA, request_match = NA, failure_reason = "")))
    tmpdir <- file.path(paths$raw_dir, ".partial"); fs::dir_create(tmpdir, recurse = TRUE); tmp <- file.path(tmpdir, paste0(basename(target), ".part")); if (file.exists(tmp)) unlink(tmp)
    api_payload <- build_cds_api_payload(req); if (!is.null(run_dir)) jsonlite::write_json(api_payload, file.path(run_dir, "cds_api_payload.json"), pretty = TRUE, auto_unbox = TRUE)
    start <- Sys.time(); warning_text <- character(); transfer <- transfer_fun %||% perform_cds_transfer
    ans <- tryCatch(withCallingHandlers({
      call <- function() if (identical(transfer, perform_cds_transfer)) transfer(req$dataset_short_name, api_payload, tmp) else if (length(formals(transfer)) >= 3L) transfer(req$dataset_short_name, api_payload, tmp) else transfer(api_payload, tmp)
      call()
    }, warning = function(w) { warning_text <<- c(warning_text, conditionMessage(w)); invokeRestart("muffleWarning") }), error = function(e) structure(list(success = FALSE, error_class = class(e), error_message = conditionMessage(e), formatted_message = format_cds_error(e)), class = "cds_download_failure"))
    elapsed <- as.numeric(difftime(Sys.time(), start, units = "secs")); returned <- if (is.character(ans) && length(ans) == 1L) ans else if (is.list(ans) && is.character(ans$path %||% NULL)) ans$path else NA_character_; candidate <- if (!is.na(returned) && file.exists(returned)) returned else tmp
    if (!file.exists(candidate) && !is.na(returned)) candidate <- returned
    if (file.exists(candidate) && normalizePath(candidate, winslash = "/", mustWork = FALSE) != normalizePath(tmp, winslash = "/", mustWork = FALSE)) {
      if (!.descendant(candidate, paths$root)) stop("Returned transfer path is outside approved output root.", call. = FALSE)
      fs::file_copy(candidate, tmp, overwrite = TRUE); candidate <- tmp
    }
    tmp_request <- req; tmp_request$target <- basename(tmp); post <- validate_downloaded_target(tmp, tmp_request)
    if (inherits(ans, "cds_download_failure")) { post$valid <- FALSE; post$failure_reason <- ans$formatted_message %||% ans$error_message }
    if (!post$valid) {
      row <- download_result_row(req, target, "failed", post, elapsed, ifelse(is.na(returned), "", returned), paste(warning_text, collapse = " | "), if (inherits(ans, "cds_download_failure")) paste(class(ans), collapse = ";") else "", if (inherits(ans, "cds_download_failure")) ans$error_message else "")
      attr(row, "cds_failure") <- TRUE; return(row)
    }
    finalized <- finalize_raw_artifact(candidate, req, paths, run_dir, info$partials); final_check <- validate_downloaded_target(finalized$final_raw_path, req)
    row <- download_result_row(req, finalized$final_raw_path, "downloaded", final_check, elapsed, ifelse(is.na(returned), "", returned), paste(warning_text, collapse = " | "), finalization = finalized)
    if (!final_check$valid) attr(row, "cds_failure") <- TRUE
    row
  })
  out <- if (length(statuses)) do.call(rbind, statuses) else data.frame(); if (!is.null(run_dir)) utils::write.csv(out, file.path(run_dir, "download_manifest.csv"), row.names = FALSE)
  if (!dry_run && nrow(out) && any(!is.na(out$valid) & !out$valid)) stop(paste0("pipeline_status=failed\nfailed_stage=download\ndownload_target_exists=FALSE\nfailure_reason=", out$failure_reason[[which(!out$valid)[1L]]]), call. = FALSE)
  out
}

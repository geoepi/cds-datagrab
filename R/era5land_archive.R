# Content-aware ERA5-Land archive finalization, extraction, and member mapping.

detect_container_type <- function(path) {
  if (!file.exists(path) || is.na(file.info(path)$size) || file.info(path)$size < 2) return("unknown")
  con <- file(path, "rb"); on.exit(close(con), add = TRUE)
  b <- readBin(con, "raw", n = 8L)
  hex <- tolower(paste(sprintf("%02x", as.integer(b)), collapse = ""))
  if (startsWith(hex, "504b0304") || startsWith(hex, "504b0506") || startsWith(hex, "504b0708")) return("zip")
  if (startsWith(hex, "43444601") || startsWith(hex, "43444602") || startsWith(hex, "43444605")) return("netcdf_classic")
  if (startsWith(hex, "894844460d0a1a0a")) return("netcdf4_hdf5")
  if (startsWith(hex, "47524942")) return("grib")
  "unknown"
}

container_extension <- function(container) switch(container, zip = "zip", netcdf_classic = "nc", netcdf4_hdf5 = "nc", grib = "grib", "bin")
raw_request_stem <- function(target) sub("\\.(nc|netcdf|zip|grib)$", "", basename(target), ignore.case = TRUE)
raw_candidate_paths <- function(raw_dir, target) {
  if (!dir.exists(raw_dir)) return(character())
  stem <- raw_request_stem(target)
  paths <- list.files(raw_dir, full.names = TRUE, recursive = FALSE, all.files = FALSE)
  paths[file.info(paths)$isdir %in% FALSE & vapply(paths, function(p) raw_request_stem(basename(p)) == stem, logical(1))]
}

raw_checksum <- function(path) digest::digest(file = path, algo = "sha256")

finalize_raw_artifact <- function(candidate, request, paths, run_dir = NULL, partial_candidates = character()) {
  if (!file.exists(candidate)) stop("Downloaded candidate does not exist: ", candidate, call. = FALSE)
  detected <- detect_container_type(candidate)
  if (!detected %in% c("zip", "netcdf_classic", "netcdf4_hdf5", "grib")) stop("Unsupported downloaded container: ", detected, call. = FALSE)
  stem <- raw_request_stem(request$target)
  final_path <- file.path(paths$raw_dir, paste0(stem, ".", container_extension(detected)))
  candidate_abs <- normalizePath(candidate, winslash = "/", mustWork = TRUE)
  final_abs <- normalizePath(final_path, winslash = "/", mustWork = FALSE)
  size <- as.numeric(file.info(candidate_abs)$size); checksum <- raw_checksum(candidate_abs)
  if (!identical(candidate_abs, final_abs)) {
    if (file.exists(final_path)) {
      same <- as.numeric(file.info(final_path)$size) == size && identical(raw_checksum(final_path), checksum)
      if (!same) stop("A different deterministic raw artifact already exists: ", final_path, call. = FALSE)
      unlink(candidate_abs)
    } else if (!file.rename(candidate_abs, final_path)) {
      stop("Could not atomically finalize raw artifact: ", final_path, call. = FALSE)
    }
  }
  verified_size <- as.numeric(file.info(final_path)$size)
  verified_checksum <- raw_checksum(final_path)
  if (!identical(verified_size, size) || !identical(verified_checksum, checksum)) stop("Raw artifact failed post-finalization verification: ", final_path, call. = FALSE)
  partial_status <- character()
  for (p in unique(partial_candidates[file.exists(partial_candidates)])) {
    if (normalizePath(p, winslash = "/", mustWork = FALSE) == normalizePath(final_path, winslash = "/", mustWork = FALSE)) next
    same <- as.numeric(file.info(p)$size) == verified_size && identical(raw_checksum(p), verified_checksum)
    if (same) { unlink(p); partial_status <- c(partial_status, "identical_partial_removed") } else partial_status <- c(partial_status, "different_partial_retained")
  }
  result <- list(request_hash = request$request_hash %||% NA_character_, downloaded_path = candidate_abs, original_raw_path = candidate_abs, final_raw_path = normalizePath(final_path, winslash = "/", mustWork = TRUE), detected_container = detected,
    original_extension = tools::file_ext(candidate_abs), final_extension = container_extension(detected), extension_content_match = identical(tolower(tools::file_ext(candidate_abs)), container_extension(detected)),
    final_extension_content_match = identical(tolower(tools::file_ext(final_path)), container_extension(detected)),
    file_size = verified_size, sha256 = verified_checksum, partial_status = unique(partial_status), raw_reused = FALSE)
  if (!is.null(run_dir)) jsonlite::write_json(result, file.path(run_dir, "raw_finalization.json"), pretty = TRUE, auto_unbox = TRUE, null = "null")
  result
}

find_reusable_raw_artifact <- function(request, paths) {
  candidates <- raw_candidate_paths(paths$raw_dir, request$target)
  partial_dir <- file.path(paths$raw_dir, ".partial")
  partials <- if (dir.exists(partial_dir)) list.files(partial_dir, full.names = TRUE, recursive = FALSE) else character()
  partials <- partials[file.info(partials)$isdir %in% FALSE & !grepl("[.]part$", partials, ignore.case = TRUE)]
  list(candidates = candidates, partials = partials)
}

archive_member_safe <- function(name) {
  n <- gsub("\\\\", "/", as.character(name))
  nzchar(n) && !grepl("(^/|^[A-Za-z]:|(^|/)\\.\\.(/|$))", n) && !grepl("(^|/)$", n)
}

era5land_expected_member_map <- function() {
  ids <- .era5land_product_ids()
  data.frame(product_id = ids, cds_variable = vapply(ids, function(id) get_variable_spec(id)$cds_variable, character(1)), stringsAsFactors = FALSE)
}

era5land_member_candidate <- function(md, product_id) {
  spec <- get_variable_spec(product_id)
  alias <- tryCatch(resolve_netcdf_variable(md, spec), error = function(e) NULL)
  if (is.null(alias)) return(NULL)
  v <- md$variables[[alias]]
  expected_units <- normalize_source_units(spec$source_units); actual_units <- normalize_source_units(v$units)
  if (!identical(expected_units, actual_units)) stop("Source units for ", product_id, " alias ", alias, " are incompatible: ", v$units, call. = FALSE)
  dims <- v$dimensions
  roles <- list(longitude = dims[grepl("^(longitude|lon)$", dims, ignore.case = TRUE)], latitude = dims[grepl("^(latitude|lat)$", dims, ignore.case = TRUE)], time = dims[grepl("^(valid_time|time|date)$", dims, ignore.case = TRUE)])
  if (any(vapply(roles, length, integer(1)) != 1L)) stop("Environmental variable ", alias, " must have longitude, latitude, and valid_time/time dimensions", call. = FALSE)
  list(product_id = product_id, cds_variable = spec$cds_variable, alias = alias, source_units = v$units, dimensions = dims, dimension_lengths = v$dimension_lengths, time_dimension = roles$time[[1L]])
}

era5land_extract_archive <- function(archive_path, extracted_root, request_hash, request_dates, run_dir = NULL) {
  if (detect_container_type(archive_path) != "zip") stop("ERA5-Land extraction requires a ZIP archive: ", archive_path, call. = FALSE)
  checksum <- raw_checksum(archive_path); final_dir <- file.path(extracted_root, request_hash); manifest_path <- file.path(final_dir, "member_inventory.csv")
  valid_existing <- function() {
    if (!dir.exists(final_dir) || !file.exists(manifest_path)) return(NULL)
    x <- tryCatch(utils::read.csv(manifest_path, stringsAsFactors = FALSE), error = function(e) NULL)
    if (is.null(x) || !nrow(x) || !all(c("archive_sha256", "extracted_path", "member_sha256") %in% names(x)) || !all(as.character(x$archive_sha256) == checksum)) return(NULL)
    if (!all(file.exists(x$extracted_path))) return(NULL)
    if (!all(vapply(seq_len(nrow(x)), function(i) identical(raw_checksum(x$extracted_path[[i]]), as.character(x$member_sha256[[i]])), logical(1)))) return(NULL)
    attr(x, "extraction_reused") <- TRUE; x
  }
  old <- valid_existing()
  if (!is.null(old)) return(old)
  if (dir.exists(final_dir)) {
    recovery <- file.path(extracted_root, ".partial", paste0(request_hash, "-recovery-", as.integer(Sys.time())))
    fs::dir_create(dirname(recovery), recurse = TRUE); if (!file.rename(final_dir, recovery)) unlink(final_dir, recursive = TRUE)
  }
  listing <- tryCatch(utils::unzip(archive_path, list = TRUE), error = function(e) stop("Malformed ERA5-Land ZIP archive: ", conditionMessage(e), call. = FALSE))
  members <- gsub("\\\\", "/", as.character(listing$Name))
  if (!length(members) || any(!vapply(members, archive_member_safe, logical(1))) || anyDuplicated(members)) stop("ERA5-Land archive contains unsafe or duplicate member paths", call. = FALSE)
  nc_members <- members[grepl("\\.(nc|netcdf)$", members, ignore.case = TRUE)]
  if (length(nc_members) != length(.era5land_product_ids())) stop("Expected eight ERA5-Land NetCDF members, found ", length(nc_members), call. = FALSE)
  temp_dir <- file.path(extracted_root, ".partial", paste0(request_hash, "-", as.integer(Sys.time()), "-", sample.int(1e6, 1L)))
  fs::dir_create(temp_dir, recurse = TRUE); on.exit(if (dir.exists(temp_dir)) unlink(temp_dir, recursive = TRUE), add = TRUE)
  utils::unzip(archive_path, exdir = temp_dir, overwrite = FALSE)
  extracted <- file.path(temp_dir, members)
  if (any(!file.exists(extracted))) stop("ERA5-Land extraction did not produce every archive member", call. = FALSE)
  expected_dates <- normalize_date_vector(request_dates, "request_dates")
  rows <- list(); mappings <- list(); used_products <- character()
  failed_member_row <- function(i, p, message) data.frame(request_hash = request_hash, archive_path = normalizePath(archive_path, winslash = "/", mustWork = TRUE), archive_sha256 = checksum,
    member_name = members[[i]], member_size = as.numeric(file.info(p)$size), member_sha256 = raw_checksum(p), extracted_path = normalizePath(p, winslash = "/", mustWork = FALSE), container_type = detect_container_type(p),
    netcdf_inspection_status = paste0("failed: ", message), environmental_variable_alias = NA_character_, product_id = NA_character_, cds_variable = NA_character_, source_units = NA_character_,
    dimension_names = NA_character_, dimension_lengths = NA_character_, time_dimension = NA_character_, decoded_dates = NA_character_, stringsAsFactors = FALSE)
  for (i in which(grepl("\\.(nc|netcdf)$", members, ignore.case = TRUE))) {
    p <- extracted[[i]]; md <- tryCatch(inspect_netcdf_ncdf4(p), error = function(e) e)
    if (inherits(md, "error")) { rows[[length(rows) + 1L]] <- failed_member_row(i, p, conditionMessage(md)); next }
    candidates <- lapply(.era5land_product_ids(), function(id) tryCatch(era5land_member_candidate(md, id), error = function(e) structure(list(error = conditionMessage(e)), class = "era5land_member_error")))
    hits <- which(vapply(candidates, function(x) !is.null(x) && !inherits(x, "era5land_member_error"), logical(1)))
    if (length(hits) != 1L) { rows[[length(rows) + 1L]] <- failed_member_row(i, p, paste0("expected exactly one registered environmental mapping; found ", length(hits))); next }
    mapping <- candidates[[hits[[1L]]]]; id <- mapping$product_id
    if (id %in% used_products) { rows[[length(rows) + 1L]] <- failed_member_row(i, p, paste0("duplicate product mapping for ", id)); next }
    dates <- tryCatch(normalize_date_vector(md$decoded_dates, paste0("decoded dates for ", members[[i]])), error = function(e) e)
    if (inherits(dates, "error")) { rows[[length(rows) + 1L]] <- failed_member_row(i, p, conditionMessage(dates)); next }
    if (!identical(as.character(dates), as.character(expected_dates))) { rows[[length(rows) + 1L]] <- failed_member_row(i, p, "member date coverage differs from request"); next }
    used_products <- c(used_products, id)
    row <- data.frame(request_hash = request_hash, archive_path = normalizePath(archive_path, winslash = "/", mustWork = TRUE), archive_sha256 = checksum,
      member_name = members[[i]], member_size = as.numeric(file.info(p)$size), member_sha256 = raw_checksum(p), extracted_path = normalizePath(p, winslash = "/", mustWork = FALSE), container_type = md$format,
      netcdf_inspection_status = "success", environmental_variable_alias = mapping$alias, product_id = id, cds_variable = mapping$cds_variable, source_units = mapping$source_units,
      dimension_names = paste(mapping$dimensions, collapse = ";"), dimension_lengths = paste(mapping$dimension_lengths, collapse = ";"), time_dimension = mapping$time_dimension,
      decoded_dates = paste(format(dates, "%Y-%m-%d"), collapse = ";"), stringsAsFactors = FALSE)
    rows[[length(rows) + 1L]] <- row
    for (j in seq_along(dates)) mappings[[length(mappings) + 1L]] <- data.frame(request_hash = request_hash, product_id = id, cds_variable = mapping$cds_variable,
      netcdf_alias = mapping$alias, archive_member = members[[i]], source_units = mapping$source_units, output_units = get_variable_spec(id)$output_units,
      time_dimension = mapping$time_dimension, time_index = j, source_date = format(dates[[j]], "%Y-%m-%d"), output_date = format(dates[[j]], "%Y-%m-%d"), stringsAsFactors = FALSE)
  }
  if (!setequal(used_products, .era5land_product_ids())) warning("ERA5-Land archive did not map all eight registered products; valid members were preserved", call. = FALSE)
  inventory <- do.call(rbind, rows); source_map <- do.call(rbind, mappings)
  if (!file.rename(temp_dir, final_dir)) stop("Could not atomically finalize ERA5-Land extraction: ", final_dir, call. = FALSE)
  inventory$extracted_path <- file.path(final_dir, members[which(grepl("\\.(nc|netcdf)$", members, ignore.case = TRUE))])
  inventory$extracted_path <- normalizePath(inventory$extracted_path, winslash = "/", mustWork = FALSE)
  utils::write.csv(inventory, file.path(final_dir, "member_inventory.csv"), row.names = FALSE)
  utils::write.csv(source_map, file.path(final_dir, "source_map.csv"), row.names = FALSE)
  if (!is.null(run_dir)) { fs::dir_create(run_dir, recurse = TRUE); utils::write.csv(inventory, file.path(run_dir, "member_inventory.csv"), row.names = FALSE); utils::write.csv(source_map, file.path(run_dir, "source_map.csv"), row.names = FALSE) }
  attr(inventory, "extraction_reused") <- FALSE; attr(inventory, "source_map") <- source_map; inventory
}

era5land_member_for_product <- function(inventory, product_id) {
  x <- inventory[inventory$product_id == product_id, , drop = FALSE]
  if (nrow(x) != 1L) stop("Expected exactly one extracted ERA5-Land member for product ", product_id, call. = FALSE)
  x
}

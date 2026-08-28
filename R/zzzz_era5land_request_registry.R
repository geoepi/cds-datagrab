# Durable, resumable state for the ERA5-Land monthly CDS source requests.

.era5land_registry_columns <- c(
  "source_family", "request_hash", "start_date", "end_date", "request_days",
  "cds_job_id", "cds_job_url", "request_status", "submitted_at",
  "last_checked_at", "retrieved_at", "local_raw_path", "local_bytes",
  "local_checksum", "error_class", "error_message", "source_commit",
  "config_checksum"
)

era5land_registry_path <- function(paths) {
  paths$request_registry %||% file.path(paths$source_root, "requests", "request_registry.csv")
}

era5land_empty_registry <- function() {
  out <- as.data.frame(setNames(replicate(length(.era5land_registry_columns), character(), simplify = FALSE), .era5land_registry_columns),
    stringsAsFactors = FALSE
  )
  out$local_bytes <- numeric()
  out
}

era5land_registry_key <- function(x) {
  paste(as.character(x$source_family %||% ""), as.character(x$request_hash %||% ""),
    as.character(x$start_date %||% ""), as.character(x$end_date %||% ""), sep = "\r")
}

era5land_has_value <- function(x) isTRUE(length(x) == 1L && !is.na(x) && nzchar(as.character(x)))

era5land_read_request_registry <- function(paths) {
  path <- era5land_registry_path(paths)
  if (!file.exists(path)) return(era5land_empty_registry())
  x <- tryCatch(utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE), error = function(e) {
    stop("Could not read ERA5-Land request registry: ", conditionMessage(e), call. = FALSE)
  })
  missing <- setdiff(.era5land_registry_columns, names(x))
  if (length(missing)) stop("ERA5-Land request registry is missing columns: ", paste(missing, collapse = ", "), call. = FALSE)
  x <- x[.era5land_registry_columns]
  if (!nrow(x)) return(era5land_empty_registry())
  x[] <- lapply(x, as.character)
  x$local_bytes <- suppressWarnings(as.numeric(x$local_bytes))
  keys <- vapply(seq_len(nrow(x)), function(i) era5land_registry_key(x[i, , drop = FALSE]), character(1))
  x[!duplicated(keys, fromLast = TRUE), , drop = FALSE]
}

era5land_write_request_registry <- function(registry, paths) {
  path <- era5land_registry_path(paths)
  fs::dir_create(dirname(path), recurse = TRUE)
  registry <- as.data.frame(registry, stringsAsFactors = FALSE)
  for (nm in setdiff(.era5land_registry_columns, names(registry))) registry[[nm]] <- NA_character_
  registry <- registry[.era5land_registry_columns]
  if (nrow(registry)) {
    registry[] <- lapply(registry, as.character)
    registry$local_bytes <- suppressWarnings(as.numeric(registry$local_bytes))
    keys <- vapply(seq_len(nrow(registry)), function(i) era5land_registry_key(registry[i, , drop = FALSE]), character(1))
    registry <- registry[!duplicated(keys, fromLast = TRUE), , drop = FALSE]
  }
  tmp <- tempfile("request_registry-", tmpdir = dirname(path), fileext = ".csv.tmp")
  on.exit(if (file.exists(tmp)) unlink(tmp), add = TRUE)
  utils::write.csv(registry, tmp, row.names = FALSE, na = "")
  if (file.exists(path) && file.rename(tmp, path)) return(invisible(path))
  if (file.exists(path)) {
    backup <- tempfile("request_registry-backup-", tmpdir = dirname(path), fileext = ".csv")
    if (!file.rename(path, backup)) stop("Could not stage the existing ERA5-Land request registry for atomic replacement", call. = FALSE)
    if (!file.rename(tmp, path)) {
      file.rename(backup, path)
      stop("Could not atomically replace the ERA5-Land request registry", call. = FALSE)
    }
    unlink(backup)
  } else if (!file.rename(tmp, path)) {
    stop("Could not atomically create the ERA5-Land request registry", call. = FALSE)
  }
  invisible(path)
}

era5land_registry_row_for_request <- function(request, config, status = "planned") {
  cfg_path <- attr(config, "config_path") %||% NULL
  cfg_checksum <- if (!is.null(cfg_path) && file.exists(cfg_path)) digest::digest(file = cfg_path, algo = "sha256") else NA_character_
  data.frame(
    source_family = request$source_family_id %||% "era5land_daily_mean_utc06",
    request_hash = as.character(request$request_hash),
    start_date = as.character(request$request_start %||% min(as.Date(request$raw_request_dates))),
    end_date = as.character(request$request_end %||% max(as.Date(request$raw_request_dates))),
    request_days = paste(as.character(request$raw_request_dates), collapse = ";"),
    cds_job_id = NA_character_, cds_job_url = NA_character_, request_status = status,
    submitted_at = NA_character_, last_checked_at = NA_character_, retrieved_at = NA_character_,
    local_raw_path = NA_character_, local_bytes = NA_real_, local_checksum = NA_character_,
    error_class = NA_character_, error_message = NA_character_,
    source_commit = if (!is.null(attr(config, "project_root"))) era5land_source_commit(attr(config, "project_root")) else Sys.getenv("CDS_DATAGRAB_SOURCE_COMMIT", unset = "unknown"),
    config_checksum = cfg_checksum, stringsAsFactors = FALSE
  )
}

era5land_registry_upsert <- function(registry, row) {
  registry <- as.data.frame(registry, stringsAsFactors = FALSE)
  row <- row[.era5land_registry_columns]
  if (!nrow(registry)) return(row)
  keys <- vapply(seq_len(nrow(registry)), function(i) era5land_registry_key(registry[i, , drop = FALSE]), character(1))
  key <- era5land_registry_key(row)
  if (key %in% keys) registry[which(keys == key)[[1L]], ] <- row[1L, ] else registry <- rbind(registry, row)
  registry
}

era5land_registry_row_index <- function(registry, request) {
  if (!nrow(registry)) return(integer())
  key <- era5land_registry_key(era5land_registry_row_for_request(request, list()))
  keys <- vapply(seq_len(nrow(registry)), function(i) era5land_registry_key(registry[i, , drop = FALSE]), character(1))
  which(keys == key)
}

era5land_source_commit <- function(root) {
  value <- Sys.getenv("CDS_DATAGRAB_SOURCE_COMMIT", unset = "")
  if (nzchar(value)) return(value)
  answer <- tryCatch(system2("git", c("-C", root, "rev-parse", "HEAD"), stdout = TRUE, stderr = FALSE), error = function(e) character())
  if (length(answer) && nzchar(answer[[1L]])) answer[[1L]] else "unknown"
}

era5land_validate_raw_archive <- function(path, request) {
  basic <- list(valid = FALSE, path = normalizePath(path, winslash = "/", mustWork = FALSE), reason = "")
  if (!file.exists(path)) { basic$reason <- "missing"; return(basic) }
  size <- as.numeric(file.info(path)$size)
  if (!is.finite(size) || size <= 0) { basic$reason <- "zero_bytes"; return(basic) }
  if (!identical(detect_container_type(path), "zip")) { basic$reason <- "not_zip"; return(basic) }
  listing <- tryCatch(utils::unzip(path, list = TRUE), error = function(e) NULL)
  members <- if (!is.null(listing)) gsub("\\\\", "/", as.character(listing$Name)) else character()
  nc_members <- members[grepl("\\.(nc|netcdf)$", members, ignore.case = TRUE)]
  stem_match <- identical(raw_request_stem(basename(path)), raw_request_stem(as.character(request$target)))
  structure_ok <- length(nc_members) == length(.era5land_product_ids()) && all(vapply(nc_members, archive_member_safe, logical(1))) && !anyDuplicated(nc_members)
  basic$valid <- isTRUE(stem_match) && isTRUE(structure_ok)
  basic$reason <- if (basic$valid) "ok" else paste(c(if (!stem_match) "request_target_mismatch", if (!structure_ok) "expected_eight_netcdf_members"), collapse = ";")
  basic$size <- size; basic$members <- nc_members; basic
}

era5land_local_archive <- function(request, paths) {
  candidates <- raw_candidate_paths(paths$raw_dir, request$target)
  valid <- candidates[vapply(candidates, function(path) isTRUE(era5land_validate_raw_archive(path, request)$valid), logical(1))]
  if (length(valid)) normalizePath(valid[[1L]], winslash = "/", mustWork = TRUE) else NULL
}

era5land_migrate_legacy_unavailable_rows <- function(registry, requests, paths, persist = FALSE) {
  if (!nrow(registry)) return(registry)
  exact_message <- "Your requested file is unavailable - check url"
  for (request in requests) {
    idx <- era5land_registry_row_index(registry, request)
    if (!length(idx)) next
    row <- registry[idx[[1L]], , drop = FALSE]
    eligible <- identical(as.character(row$request_status[[1L]]), "failed") &&
      identical(as.character(row$error_message[[1L]]), exact_message) &&
      era5land_has_value(row$cds_job_url[[1L]]) &&
      is.null(era5land_local_archive(request, paths))
    if (eligible) {
      row$request_status <- "processing"
      row$error_class <- "legacy_unavailable_reclassified"
      row$error_message <- exact_message
      registry <- era5land_registry_upsert(registry, row)
    }
  }
  if (persist) era5land_write_request_registry(registry, paths)
  registry
}

era5land_registry_reconcile <- function(requests, registry, paths, config, persist = FALSE) {
  registry <- era5land_migrate_legacy_unavailable_rows(registry, requests, paths, persist = FALSE)
  for (request in requests) {
    row <- era5land_registry_row_for_request(request, config)
    idx <- era5land_registry_row_index(registry, request)
    if (length(idx)) row <- registry[idx[[1L]], , drop = FALSE]
    local <- era5land_local_archive(request, paths)
    if (!is.null(local)) {
      row$request_status <- "retrieved"; row$local_raw_path <- local; row$local_bytes <- as.character(file.info(local)$size)
      row$local_checksum <- raw_checksum(local); if (!era5land_has_value(row$retrieved_at)) row$retrieved_at <- format(Sys.time(), tz = "UTC", usetz = TRUE)
      row$error_class <- NA_character_; row$error_message <- NA_character_
    } else if (!length(idx)) row$request_status <- "planned"
    registry <- era5land_registry_upsert(registry, row)
  }
  if (persist) era5land_write_request_registry(registry, paths)
  registry
}

era5land_request_inventory <- function(requests, registry, paths) {
  rows <- lapply(requests, function(request) {
    idx <- era5land_registry_row_index(registry, request)
    row <- if (length(idx)) registry[idx[[1L]], , drop = FALSE] else era5land_registry_row_for_request(request, list())
    local <- era5land_local_archive(request, paths)
    data.frame(request_hash = request$request_hash, start_date = request$request_start, end_date = request$request_end,
      local_valid = !is.null(local), local_path = local %||% "", registry_status = row$request_status,
      has_job = era5land_has_value(row$cds_job_url), stringsAsFactors = FALSE)
  })
  x <- if (length(rows)) do.call(rbind, rows) else data.frame()
  list(rows = x, source_requests_planned = nrow(x), raw_archives_valid = sum(x$local_valid),
    registered_pending_cds_jobs = sum(!x$local_valid & x$has_job & x$registry_status %in% c("submitted", "processing", "ready")),
    submitted_cds_jobs = sum(!x$local_valid & x$has_job & x$registry_status == "submitted"),
    processing_cds_jobs = sum(!x$local_valid & x$has_job & x$registry_status == "processing"),
    failed_cds_jobs = sum(!x$local_valid & x$registry_status == "failed"),
    expired_cds_jobs = sum(!x$local_valid & x$registry_status == "expired"),
    new_cds_requests_required = sum(!x$local_valid & !x$has_job),
    retrievals_ready = sum(!x$local_valid & x$registry_status == "ready"))
}

era5land_extract_cds_job_info <- function(result) {
  get_value <- function(name) {
    value <- tryCatch(result[[name]], error = function(e) NULL)
    if (is.function(value)) value <- tryCatch(value(), error = function(e) NULL)
    if (is.null(value) || !length(value)) NULL else as.character(value[[1L]])
  }
  url <- get_value("cds_job_url") %||% get_value("job_url") %||% get_value("href") %||% get_value("url")
  if (is.null(url)) url <- tryCatch(as.character(result$get_url()), error = function(e) NULL)
  if (is.null(url) || !nzchar(url)) stop("CDS staging returned no durable job URL", call. = FALSE)
  id <- get_value("cds_job_id") %||% get_value("job_id") %||% get_value("id")
  if (is.null(id) || !nzchar(id)) id <- sub("/$", "", sub("^.*/", "", url))
  list(cds_job_id = id, cds_job_url = url, result = result)
}

era5land_stage_cds_request <- function(request, stage_fun = NULL) {
  payload <- build_cds_api_payload(request)
  if (is.null(stage_fun)) {
    if (!requireNamespace("ecmwfr", quietly = TRUE)) stop("ecmwfr is required to stage CDS requests", call. = FALSE)
    result <- ecmwfr::wf_request(request = c(list(dataset_short_name = request$dataset_short_name), payload), transfer = FALSE)
  } else if (length(formals(stage_fun)) >= 2L) result <- stage_fun(request, payload) else result <- stage_fun(request)
  era5land_extract_cds_job_info(result)
}

era5land_stage_requests <- function(requests, registry, paths, config, stage_fun = NULL, dry_run = FALSE) {
  if (dry_run) return(list(registry = registry, submitted = 0L, reused = 0L, failures = list()))
  era5land_write_request_registry(registry, paths)
  failures <- list(); submitted <- 0L; reused <- 0L
  for (request in requests) {
    idx <- era5land_registry_row_index(registry, request)
    row <- if (length(idx)) registry[idx[[1L]], , drop = FALSE] else era5land_registry_row_for_request(request, config)
    local <- era5land_local_archive(request, paths)
    if (!is.null(local)) { reused <- reused + 1L; next }
    if (era5land_has_value(row$cds_job_url)) { reused <- reused + 1L; next }
    now <- format(Sys.time(), tz = "UTC", usetz = TRUE)
    staged <- tryCatch(era5land_stage_cds_request(request, stage_fun), error = function(e) e)
    if (inherits(staged, "error")) {
      row$request_status <- "failed"; row$error_class <- paste(class(staged), collapse = ";"); row$error_message <- conditionMessage(staged)
      failures[[request$request_hash]] <- row$error_message
    } else {
      row$cds_job_id <- staged$cds_job_id; row$cds_job_url <- staged$cds_job_url; row$request_status <- "submitted"
      row$submitted_at <- now; row$last_checked_at <- now; row$error_class <- NA_character_; row$error_message <- NA_character_; submitted <- submitted + 1L
    }
    registry <- era5land_registry_upsert(registry, row)
    era5land_write_request_registry(registry, paths)
  }
  list(registry = registry, submitted = submitted, reused = reused, failures = failures)
}

era5land_perform_cds_transfer <- function(url, target_path) {
  if (!requireNamespace("ecmwfr", quietly = TRUE)) stop("ecmwfr is required to retrieve CDS requests", call. = FALSE)
  ecmwfr::wf_transfer(url, path = dirname(target_path), filename = basename(target_path), verbose = FALSE)
}

era5land_normalize_remote_status <- function(status) {
  value <- tolower(trimws(as.character(status %||% "")))
  if (value %in% c("queued", "running", "submitted", "accepted", "processing", "pending", "in_progress")) return("processing")
  if (value %in% c("successful", "success", "completed", "complete", "finished", "ready")) return("successful")
  if (value %in% c("failed", "failure", "error", "rejected", "cancelled", "canceled")) return("failed")
  if (value %in% c("expired", "deleted", "not_found", "gone")) return("expired")
  "unknown"
}

era5land_query_cds_job_status <- function(url, status_fun = NULL) {
  if (!is.null(status_fun)) {
    answer <- if (length(formals(status_fun)) >= 1L) status_fun(url) else status_fun()
    if (is.character(answer) && length(answer) == 1L) return(list(state = era5land_normalize_remote_status(answer), message = answer, raw = answer))
    state <- answer$state %||% answer$status %||% answer$job_status
    return(list(state = era5land_normalize_remote_status(state), message = as.character(answer$message %||% answer$error_message %||% state %||% ""), raw = answer))
  }
  if (!requireNamespace("ecmwfr", quietly = TRUE) || !requireNamespace("httr", quietly = TRUE)) stop("ecmwfr and httr are required for CDS job status inspection", call. = FALSE)
  key <- ecmwfr::wf_get_key(user = "ecmwfr", service = "cds")
  response <- httr::GET(url, httr::add_headers("PRIVATE-TOKEN" = key), encode = "json")
  body <- tryCatch(httr::content(response), error = function(e) list())
  if (httr::status_code(response) %in% c(404L, 410L)) return(list(state = "expired", message = paste0("CDS job endpoint returned HTTP ", httr::status_code(response)), raw = body))
  if (httr::http_error(response)) stop("CDS job status query returned HTTP ", httr::status_code(response), call. = FALSE)
  state <- body$status %||% body$state %||% body$job_status
  list(state = era5land_normalize_remote_status(state), message = as.character(body$message %||% body$error_message %||% state %||% ""), raw = body)
}

era5land_retrieval_class <- function(error_message = "") {
  message <- trimws(as.character(error_message %||% ""))
  if (identical(message, "Your requested file is unavailable - check url") || grepl("Your requested file is unavailable[[:space:]]*-[[:space:]]*check url", message, ignore.case = TRUE)) return("processing")
  if (grepl("expired|deleted from queue|previously deleted|job[^.]*not found|job[^.]*does not exist|request[^.]*gone", message, ignore.case = TRUE)) return("expired")
  if (grepl("(job|request)[^.]*failed|(job|request)[^.]*rejected|permanent[^.]*error|terminal[^.]*fail|server[- ]side[^.]*fail", message, ignore.case = TRUE)) return("failed")
  if (grepl("queued|processing|submitted|in progress|not ready|still running|pending|available later|timed out|timeout|connection reset|temporarily|temporary|unavailable", message, ignore.case = TRUE)) return("processing")
  "processing"
}

era5land_retrieve_requests <- function(requests, registry, paths, config, transfer_fun = NULL, status_fun = NULL) {
  registry <- era5land_migrate_legacy_unavailable_rows(registry, requests, paths, persist = FALSE)
  retrieved <- 0L; processing <- 0L; expired <- 0L; failed <- 0L
  for (request in requests) {
    idx <- era5land_registry_row_index(registry, request)
    if (!length(idx)) next
    row <- registry[idx[[1L]], , drop = FALSE]
    local <- era5land_local_archive(request, paths)
    if (!is.null(local)) {
      row$request_status <- "retrieved"; row$local_raw_path <- local; row$local_bytes <- as.character(file.info(local)$size); row$local_checksum <- raw_checksum(local); if (!era5land_has_value(row$retrieved_at)) row$retrieved_at <- format(Sys.time(), tz = "UTC", usetz = TRUE)
      registry <- era5land_registry_upsert(registry, row); next
    }
    if (!era5land_has_value(row$cds_job_url) || identical(row$request_status, "expired")) next
    status_probe <- tryCatch(era5land_query_cds_job_status(row$cds_job_url, status_fun = status_fun), error = function(e) structure(list(error = e), class = "cds_status_query_error"))
    row$last_checked_at <- format(Sys.time(), tz = "UTC", usetz = TRUE)
    if (!inherits(status_probe, "cds_status_query_error")) {
      if (status_probe$state == "processing") {
        row$request_status <- "processing"; row$error_class <- "remote_status_processing"; row$error_message <- status_probe$message %||% "CDS job is not ready"; processing <- processing + 1L
        registry <- era5land_registry_upsert(registry, row); era5land_write_request_registry(registry, paths); next
      }
      if (status_probe$state == "failed") {
        row$request_status <- "failed"; row$error_class <- "remote_status_failed"; row$error_message <- status_probe$message %||% "CDS job reported failed"; failed <- failed + 1L
        registry <- era5land_registry_upsert(registry, row); era5land_write_request_registry(registry, paths); next
      }
      if (status_probe$state == "expired") {
        row$request_status <- "expired"; row$error_class <- "remote_status_expired"; row$error_message <- status_probe$message %||% "CDS job expired"; expired <- expired + 1L
        registry <- era5land_registry_upsert(registry, row); era5land_write_request_registry(registry, paths); next
      }
    }
    tmpdir <- file.path(paths$raw_dir, ".partial"); fs::dir_create(tmpdir, recurse = TRUE); tmp <- file.path(tmpdir, paste0(basename(request$target), ".part")); if (file.exists(tmp)) unlink(tmp)
    transfer <- transfer_fun %||% era5land_perform_cds_transfer
    answer <- tryCatch(if (length(formals(transfer)) >= 2L) transfer(row$cds_job_url, tmp) else transfer(row$cds_job_url), error = function(e) e)
    if (inherits(answer, "error")) {
      classification <- era5land_retrieval_class(conditionMessage(answer)); row$error_class <- paste(class(answer), collapse = ";"); row$error_message <- conditionMessage(answer)
      row$request_status <- classification; if (classification == "processing") processing <- processing + 1L else if (classification == "expired") expired <- expired + 1L else failed <- failed + 1L
      registry <- era5land_registry_upsert(registry, row); era5land_write_request_registry(registry, paths); next
    }
    candidate <- if (is.character(answer) && length(answer) == 1L && file.exists(answer)) answer else if (file.exists(tmp)) tmp else NULL
    if (is.null(candidate)) {
      row$request_status <- "processing"; row$error_class <- NA_character_; row$error_message <- NA_character_; processing <- processing + 1L
      registry <- era5land_registry_upsert(registry, row); era5land_write_request_registry(registry, paths); next
    }
    validation_request <- request; validation_request$target <- basename(tmp)
    validation <- era5land_validate_raw_archive(candidate, validation_request)
    if (!isTRUE(validation$valid)) {
      row$request_status <- "processing"; row$error_class <- "partial_transfer"; row$error_message <- validation$reason; processing <- processing + 1L
      registry <- era5land_registry_upsert(registry, row); era5land_write_request_registry(registry, paths); next
    }
    finalized <- tryCatch(finalize_raw_artifact(candidate, request, paths, partial_candidates = candidate), error = function(e) e)
    if (inherits(finalized, "error")) {
      row$request_status <- "processing"; row$error_class <- paste(class(finalized), collapse = ";"); row$error_message <- conditionMessage(finalized); failed <- failed + 1L
    } else {
      row$request_status <- "retrieved"; row$local_raw_path <- finalized$final_raw_path; row$local_bytes <- as.character(finalized$file_size); row$local_checksum <- finalized$sha256; row$retrieved_at <- format(Sys.time(), tz = "UTC", usetz = TRUE); row$error_class <- NA_character_; row$error_message <- NA_character_; retrieved <- retrieved + 1L
    }
    registry <- era5land_registry_upsert(registry, row); era5land_write_request_registry(registry, paths)
  }
  list(registry = registry, retrieved = retrieved, processing = processing, expired = expired, failed = failed)
}

CDS_AVAILABILITY_SCHEMA_VERSION <- 1L
CDS_AVAILABILITY_CATALOGUE_BASE <- "https://cds.climate.copernicus.eu/api/catalogue/v1/collections"

.cds_availability_date <- function(x) {
  if (is.null(x) || !length(x) || is.na(x[[1L]])) return(as.Date(NA))
  value <- tryCatch(as.Date(substr(as.character(x[[1L]]), 1L, 10L)), error = function(e) as.Date(NA))
  if (length(value) != 1L) as.Date(NA) else value
}
.cds_availability_iso <- function(x) if (length(x) != 1L || is.na(x)) NULL else format(as.Date(x), "%Y-%m-%d")
.cds_availability_safe_error <- function(e) {
  message <- conditionMessage(e)
  code <- regmatches(message, regexpr("HTTP[[:space:]:]+[0-9]{3}", message, ignore.case = TRUE))
  if (length(code) && nzchar(code)) return(gsub("[[:space:]]+", " ", code))
  if (grepl("timeout|timed out|connection reset|temporary DNS|could not resolve host", message, ignore.case = TRUE)) return("Transient CDS transport failure")
  "CDS metadata or retrieval operation failed; details withheld"
}
cds_availability_fetch_json <- function(url, timeout_seconds = 30) {
  if (!requireNamespace("httr", quietly = TRUE)) stop("The httr package is required for CDS metadata discovery", call. = FALSE)
  response <- httr::GET(url, httr::timeout(timeout_seconds), httr::user_agent("cdsdatagrab-availability-audit/1"))
  status <- httr::status_code(response)
  if (status < 200L || status >= 300L) stop("CDS metadata HTTP ", status, call. = FALSE)
  jsonlite::fromJSON(httr::content(response, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
}
.cds_availability_link <- function(collection, relation) {
  for (link in (collection$links %||% list())) if (identical(as.character(link$rel %||% ""), relation)) return(as.character(link$href %||% NA_character_))
  NA_character_
}
.cds_availability_constraint_values <- function(constraints, field) {
  node <- constraints$properties[[field]] %||% constraints[[field]]
  if (is.null(node)) return(NULL)
  values <- node$enum %||% node$items$enum
  if (is.null(values)) return(NULL)
  as.character(unlist(values, recursive = TRUE, use.names = FALSE))
}
.cds_availability_check_constraints <- function(source, constraints, candidate) {
  if (is.null(constraints)) return(list(status = "UNKNOWN", fields = list(), date_fields = list(), candidate_date_admissible = NA, reason = "No machine-readable request constraints were retrieved"))
  fields <- list()
  for (field in names(source$request_definition)) {
    allowed <- .cds_availability_constraint_values(constraints, field)
    requested <- as.character(unlist(source$request_definition[[field]], recursive = TRUE, use.names = FALSE))
    fields[[field]] <- if (is.null(allowed)) "NOT_ENUMERATED" else if (all(requested %in% allowed)) "ALLOWED" else "REJECTED"
  }
  date_values <- list(year = format(candidate, "%Y"), month = format(candidate, "%m"), day = format(candidate, "%d"))
  date_fields <- lapply(names(date_values), function(field) {
    allowed <- .cds_availability_constraint_values(constraints, field)
    if (is.null(allowed)) "NOT_ENUMERATED" else if (date_values[[field]] %in% allowed) "ALLOWED" else "REJECTED"
  })
  names(date_fields) <- names(date_values)
  rejected <- any(unlist(fields, use.names = FALSE) == "REJECTED") || any(unlist(date_fields, use.names = FALSE) == "REJECTED")
  full_date <- all(unlist(date_fields, use.names = FALSE) == "ALLOWED")
  list(status = if (rejected) "INCOMPATIBLE" else if (full_date) "SELECTIONS_ALLOWED" else "SELECTIONS_PARTIALLY_ENUMERATED",
    fields = fields, date_fields = date_fields,
    candidate_date_admissible = if (rejected) FALSE else if (full_date) TRUE else NA,
    reason = if (rejected) "Configured selection is absent from published request options" else
      if (full_date) "Selections and calendar fields appear in published options; this is not a retrieval test" else
        "Static selections appear compatible, but request constraints do not enumerate every date field")
}

cds_availability_source_definitions <- function(repo_root = getwd()) {
  repo_root <- normalizePath(repo_root, winslash = "/", mustWork = TRUE)
  definition <- yaml::read_yaml(file.path(repo_root, "config", "production_portfolio.yml"))
  workflows <- definition$source_workflows
  if (length(workflows) != 5L) stop("Expected exactly five configured CDS source workflows", call. = FALSE)
  lapply(workflows, function(workflow) {
    config_path <- file.path(repo_root, workflow$config)
    config <- read_pipeline_config(config_path)
    products <- as.character(workflow$products)
    specs <- lapply(products, get_variable_spec)
    dataset <- as.character(config$cds$dataset_short_name)
    variables <- if (identical(workflow$id, "era5land_daily_mean_utc06")) vapply(specs, function(x) x[["cds_variable"]], character(1)) else as.character(config$cds$variable)
    agera5 <- identical(workflow$id, "agera5_relhum_min")
    lai <- identical(workflow$id, "era5_lai_low")
    request <- if (agera5) {
      list(variable = variables, statistic = list(as.character(specs[[1L]]$daily_statistic)), version = as.character(config$cds$dataset_version))
    } else {
      value <- list(product_type = as.character(config$cds$product_type %||% "reanalysis"), variable = variables)
      if (lai) value$time <- "00:00" else {
        value$daily_statistic <- as.character(config$cds$daily_statistic)
        value$time_zone <- as.character(config$cds$time_zone)
        value$frequency <- as.character(config$cds$frequency)
      }
      value$data_format <- as.character(config$cds$data_format %||% "netcdf")
      value$download_format <- as.character(config$cds$download_format %||% "unarchived")
      value
    }
    hard_end <- config$temporal$configured_end_date %||% config$temporal$future_end_date %||% NA_character_
    config_hash <- digest::digest(file = config_path, algo = "sha256")
    fingerprint <- digest::digest(list(source = workflow$id, dataset = dataset, request = request,
      dataset_version = config$cds$dataset_version %||% NULL,
      source_grid_degrees = config$spatial$source_grid_degrees %||% NULL,
      align_to_source_grid = config$spatial$align_request_to_source_grid %||% NULL,
      bbox_buffer = config$spatial$api_bbox_buffer_degrees %||% NULL, config_sha256 = config_hash), algo = "sha256")
    list(
      source_workflow = as.character(workflow$id), products = products,
      config_path = normalizePath(config_path, winslash = "/", mustWork = TRUE), config_sha256 = config_hash,
      dataset_id = dataset, dataset_version = as.character(config$cds$dataset_version %||% NA_character_),
      requested_variables = variables,
      temporal_aggregation = if (lai) "00:00 UTC instantaneous calendar-date label" else as.character(config$cds$daily_statistic),
      time_zone = as.character(config$cds$time_zone %||% NA_character_),
      frequency = as.character(config$cds$frequency %||% NA_character_),
      product_type = as.character(config$cds$product_type %||% NA_character_),
      area_definition = list(source = "diagnose_spatial_domain() from configured template and bbox",
        template_path = as.character(config$spatial$template_path), bbox_path = as.character(config$spatial$bbox_path),
        request_extent_source = as.character(config$spatial$request_extent_source %||% "template_bbox_union"),
        source_grid_degrees = as.numeric(config$spatial$source_grid_degrees %||% NA_real_),
        align_request_to_source_grid = isTRUE(config$spatial$align_request_to_source_grid),
        api_bbox_buffer_degrees = as.numeric(config$spatial$api_bbox_buffer_degrees %||% NA_real_)),
      configured_observed_end = as.character(config$temporal$observed_end %||% NA_character_),
      configured_hard_end = as.character(hard_end),
      temporal_character = if (lai) "monthly climatology; daily labels do not imply new interannual source information" else NA_character_,
      finality_note = if (grepl("era5-single-levels", dataset, fixed = TRUE)) "ERA5 may expose ERA5T preliminary data; collection metadata does not classify finality per date" else "Retrieved collection metadata does not expose per-date preliminary/final status",
      request_definition = request, request_fingerprint = fingerprint,
      catalogue_href = paste0(CDS_AVAILABILITY_CATALOGUE_BASE, "/", dataset)
    )
  })
}
.cds_availability_metadata <- function(dataset_id, fetch_json) {
  href <- paste0(CDS_AVAILABILITY_CATALOGUE_BASE, "/", dataset_id)
  collection <- fetch_json(href)
  constraints_href <- .cds_availability_link(collection, "constraints")
  constraints <- if (!is.na(constraints_href) && nzchar(constraints_href)) fetch_json(constraints_href) else NULL
  interval <- collection$extent$temporal$interval %||% list()
  bounds <- if (length(interval)) interval[[1L]] else NULL
  list(catalogue_href = href, constraints_href = constraints_href,
    temporal_start = if (length(bounds) >= 1L) as.character(bounds[[1L]]) else NA_character_,
    latest_advertised = if (length(bounds) >= 2L) .cds_availability_iso(.cds_availability_date(bounds[[2L]])) else NULL,
    published = as.character(collection$published %||% NA_character_), updated = as.character(collection$updated %||% NA_character_),
    title = as.character(collection$title %||% NA_character_), doi = as.character(collection[["sci:doi"]] %||% NA_character_),
    collection_description = as.character(collection$description %||% NA_character_),
    cads_sanity_check = collection[["cads:sanity_check"]] %||% NULL,
    cads_update_frequency = as.character(collection[["cads:update_frequency"]] %||% NA_character_),
    cads_fair = collection[["cads:fair"]] %||% NULL, constraints = constraints)
}
.cds_availability_credential_present <- function() nzchar(Sys.getenv("ecmwfr_PAT", unset = "")) || file.exists(path.expand("~/.cdsapirc"))

.cds_availability_probe_once <- function(source, date, probe_fn, max_attempts = 3L, sleep_fn = Sys.sleep) {
  for (attempt in seq_len(max_attempts)) {
    result <- tryCatch(probe_fn(source, date), error = function(e) {
      message <- conditionMessage(e)
      code <- suppressWarnings(as.integer(sub(".*HTTP[[:space:]:]+([0-9]{3}).*", "\\1", message, ignore.case = TRUE)))
      retry_after <- suppressWarnings(as.numeric(sub("(?is).*retry[- _]after[[:space:]:=]+([0-9]+).*", "\\1", message, perl = TRUE)))
      if (!is.finite(retry_after)) retry_after <- NA_real_
      list(status = "ERROR", http_status = code,
        retry_after_seconds = retry_after,
        retryable = grepl("429|500|502|503|504|timeout|timed out|connection reset|temporary DNS", message, ignore.case = TRUE))
    })
    code <- suppressWarnings(as.integer(result$http_status %||% NA_integer_))
    retryable <- isTRUE(result$retryable) || (!is.na(code) && (code == 429L || code %in% c(500L, 502L, 503L, 504L)))
    if (!retryable || attempt >= max_attempts) {
      if (retryable) {
        result$status <- "ERROR"
        result$error_summary <- "Transient CDS retrieval failed after bounded retries; details withheld"
      }
      result$attempt_count <- attempt
      return(result)
    }
    retry_after <- suppressWarnings(as.numeric(result$retry_after_seconds %||% NA_real_))
    sleep_fn(if (is.finite(retry_after) && retry_after >= 0) retry_after else min(120, 30 * 2^(attempt - 1L)))
  }
  list(status = "ERROR", attempt_count = max_attempts, error_summary = "CDS retrieval attempts exhausted")
}
.cds_availability_classify_probe <- function(source, requested_date, result) {
  if (identical(result$status, "ERROR")) return(list(status = "ERROR", reason = result$error_summary %||% "CDS retrieval failed"))
  if (identical(result$status, "UNAVAILABLE")) return(list(status = "UNAVAILABLE", reason = result$reason %||% "Candidate date returned no complete source data"))
  expected_version <- source$dataset_version
  returned_version <- as.character(result$dataset_version %||% NA_character_)
  if (!is.na(expected_version) && !is.na(returned_version) && nzchar(returned_version) &&
      !identical(gsub("\\.", "_", expected_version), gsub("\\.", "_", returned_version))) {
    return(list(status = "UNAVAILABLE", reason = "Retrieved source version differs from configured version", compatibility_status = "INCOMPATIBLE"))
  }
  observed_dates <- substr(as.character(unlist(result$observed_dates %||% character(), use.names = FALSE)), 1L, 10L)
  expected_variables <- as.character(source$requested_variables)
  returned_variables <- as.character(unlist(result$received_variables %||% character(), use.names = FALSE))
  date_ok <- as.character(requested_date) %in% observed_dates
  variables_ok <- all(expected_variables %in% returned_variables)
  if (identical(result$status, "VERIFIED") && date_ok && variables_ok) {
    return(list(status = "VERIFIED", reason = "Retrieved artifact contains the requested date and every configured variable",
      observed_dates = observed_dates, received_variables = returned_variables, dataset_version = returned_version,
      finality = as.character(result$finality %||% "UNSPECIFIED"), artifact_sha256 = as.character(result$artifact_sha256 %||% NA_character_),
      attempt_count = as.integer(result$attempt_count %||% 1L)))
  }
  list(status = "UNAVAILABLE",
    reason = if (!date_ok) "Retrieved artifact did not contain the requested temporal coordinate" else
      if (!variables_ok) "Retrieved artifact did not contain complete configured variable coverage" else
        "Request acceptance was not accompanied by complete retrieval evidence",
    observed_dates = observed_dates, received_variables = returned_variables,
    dataset_version = returned_version, finality = as.character(result$finality %||% "UNSPECIFIED"),
    attempt_count = as.integer(result$attempt_count %||% 1L))
}
.cds_availability_live_probe <- function(source, date, repo_root) {
  if (!requireNamespace("ecmwfr", quietly = TRUE)) stop("The ecmwfr package is required for bounded retrieval probes", call. = FALSE)
  config <- read_pipeline_config(source$config_path)
  scratch_root <- tempfile("cds-availability-probe-")
  dir.create(scratch_root, recursive = TRUE)
  on.exit(unlink(scratch_root, recursive = TRUE, force = TRUE), add = TRUE)
  writeLines('{"application":"cds-datagrab","schema_version":1}', file.path(scratch_root, ".cds-datagrab-root"), useBytes = TRUE)
  config <- resolve_config_paths(config, repo_root, output_root = scratch_root, create = FALSE)
  domain <- diagnose_spatial_domain(config$spatial$template_path, config$spatial$bbox_path, config)
  requests <- if (identical(source$source_workflow, "era5land_daily_mean_utc06")) {
    build_era5land_daily_mean_requests(as.Date(date), domain$final_cds_area, config, source$products)
  } else {
    build_variable_requests(as.Date(date), domain$final_cds_area, config, get_variable_spec(source$products[[1L]], config))
  }
  if (length(requests) != 1L) stop("A one-date discovery probe must build exactly one request", call. = FALSE)
  paths <- resolve_source_storage_paths(config, repo_root, output_root = scratch_root, create = TRUE)
  transfer <- function(dataset, payload, target)
    ecmwfr::wf_request(request = c(list(dataset_short_name = dataset), payload), transfer = TRUE, path = dirname(target))
  request <- requests[[1L]]
  download <- download_cds_requests(requests, paths = paths, config = config, dry_run = FALSE, overwrite = TRUE, transfer_fun = transfer)
  if (!nrow(download) || !isTRUE(download$valid[[1L]])) {
    summary <- .cds_availability_safe_error(simpleError(as.character(download$failure_reason[[1L]] %||% "CDS response failed validation")))
    return(list(status = "UNAVAILABLE", accepted_request = TRUE, reason = summary, attempt_count = 1L))
  }
  target <- as.character(download$resolved_target_path[[1L]])
  if (identical(source$source_workflow, "agera5_relhum_min")) {
    spec <- get_variable_spec(source$products[[1L]], config)
    extracted <- extract_agera5_archive(target, file.path(scratch_root, "verified-members"), request$request_hash, spec)
    members <- select_agera5_archive_members(extracted, as.Date(date))
    if (nrow(members) != 1L) return(list(status = "UNAVAILABLE", accepted_request = TRUE, reason = "AgERA5 archive lacks exactly one requested date member"))
    read_agera5_daily_member(members$extracted_path[[1L]], as.Date(date), spec, fallback_date = as.Date(date))
    return(list(status = "VERIFIED", accepted_request = TRUE, observed_dates = as.character(date),
      received_variables = source$requested_variables, dataset_version = source$dataset_version,
      finality = "UNSPECIFIED", artifact_sha256 = digest::digest(file = target, algo = "sha256")))
  }
  metadata <- inspect_netcdf_ncdf4(target)
  returned_names <- names(metadata$variables)
  observed_variables <- vapply(source$products, function(product_id) {
    spec <- get_variable_spec(product_id, config)
    if (length(intersect(spec$netcdf_variable_names, returned_names))) spec$cds_variable else NA_character_
  }, character(1))
  observed_variables <- observed_variables[!is.na(observed_variables)]
  list(status = "VERIFIED", accepted_request = TRUE,
    observed_dates = as.character(normalize_date_vector(metadata$decoded_dates, "probe temporal coordinates")),
    received_variables = observed_variables, dataset_version = source$dataset_version,
    finality = "UNSPECIFIED", artifact_sha256 = digest::digest(file = target, algo = "sha256"))
}
.cds_availability_cache_key <- function(source, candidate) digest::digest(list(source$source_workflow, source$dataset_id, source$request_fingerprint, as.character(candidate)), algo = "sha256")

discover_cds_availability <- function(repo_root = getwd(), sources = NULL, fetch_json = cds_availability_fetch_json,
  probe = FALSE, credential_present = .cds_availability_credential_present(), probe_fn = NULL,
  max_backtrack_days = 3L, max_probe_attempts = 3L, sleep_fn = Sys.sleep, cache = NULL, audit_time = Sys.time()) {
  repo_root <- normalizePath(repo_root, winslash = "/", mustWork = TRUE)
  if (is.null(sources)) sources <- cds_availability_source_definitions(repo_root)
  if (length(sources) != 5L) stop("Exactly five source workflows are required", call. = FALSE)
  metadata_cache <- new.env(parent = emptyenv())
  probe_cache <- list()
  results <- lapply(sources, function(source) {
    dataset_id <- source$dataset_id
    if (!exists(dataset_id, envir = metadata_cache, inherits = FALSE)) {
      metadata <- tryCatch(.cds_availability_metadata(dataset_id, fetch_json), error = function(e)
        list(error = .cds_availability_safe_error(e), catalogue_href = paste0(CDS_AVAILABILITY_CATALOGUE_BASE, "/", dataset_id)))
      assign(dataset_id, metadata, envir = metadata_cache)
    }
    metadata <- get(dataset_id, envir = metadata_cache, inherits = FALSE)
    candidate <- .cds_availability_date(metadata$latest_advertised %||% NULL)
    constraint <- if (!is.null(metadata$error)) list(status = "ERROR", fields = list(), candidate_date_admissible = NA, reason = metadata$error) else
      if (is.na(candidate)) list(status = "UNKNOWN", fields = list(), candidate_date_admissible = NA, reason = "Catalogue has no parseable temporal end") else
        .cds_availability_check_constraints(source, metadata$constraints, candidate)
    row <- c(source[setdiff(names(source), "request_definition")], metadata[setdiff(names(metadata), "constraints")])
    row$request_definition <- source$request_definition
    row$request_constraints <- constraint
    row$latest_request_constraints_date <- if (isTRUE(constraint$candidate_date_admissible)) as.character(candidate) else NULL
    row$latest_accepted_request <- NULL
    row$latest_verified <- NULL
    row$verification_status <- if (!is.null(metadata$error)) "ERROR" else if (is.na(candidate)) "UNKNOWN" else "METADATA_ONLY"
    row$verification_reason <- if (!is.null(metadata$error)) metadata$error else if (is.na(candidate)) "Catalogue temporal end is unknown" else "Catalogue extent and request options do not prove that a complete retrieval exists"
    row$compatibility_status <- if (identical(constraint$status, "INCOMPATIBLE")) "INCOMPATIBLE" else "UNRESOLVED"
    row$probe_attempts <- list()
    row$cache_key <- if (!is.na(candidate)) .cds_availability_cache_key(source, candidate) else NULL
    if (identical(constraint$status, "INCOMPATIBLE")) {
      row$verification_status <- "UNKNOWN"
      row$verification_reason <- "Configured request conflicts with published request constraints"
      row$compatibility_status <- "INCOMPATIBLE"
    } else if (isTRUE(probe) && !is.na(candidate)) {
      cached <- if (!is.null(cache)) cache$probe_cache[[row$cache_key]] else NULL
      if (!is.null(cached) && identical(cached$status, "VERIFIED") &&
          identical(as.character(cached$request_fingerprint), source$request_fingerprint) &&
          identical(as.character(cached$candidate_date), as.character(candidate))) {
        row$verification_status <- "VERIFIED"
        row$latest_verified <- as.character(cached$latest_verified)
        row$verification_reason <- "Reused matching prior verified retrieval evidence"
        row$compatibility_status <- "COMPATIBLE"
        row$probe_attempts <- cached$probe_attempts %||% list()
        row$finality <- as.character(cached$finality %||% "UNSPECIFIED")
        probe_cache[[row$cache_key]] <<- cached
      } else if (!isTRUE(credential_present)) {
        row$verification_status <- "METADATA_ONLY"
        row$verification_reason <- "CDS credentials are not configured; no retrieval probe was attempted"
      } else {
        active_probe <- probe_fn
        if (is.null(active_probe)) active_probe <- function(s, d) .cds_availability_live_probe(s, d, repo_root)
        row$compatibility_status <- "COMPATIBLE"
        dates <- seq(candidate, candidate - as.integer(max_backtrack_days), by = "-1 day")
        for (probe_date in format(dates, "%Y-%m-%d")) {
          raw <- .cds_availability_probe_once(source, probe_date, active_probe, max_attempts = max_probe_attempts, sleep_fn = sleep_fn)
          classified <- .cds_availability_classify_probe(source, probe_date, raw)
          if (isTRUE(raw$accepted_request) && is.null(row$latest_accepted_request)) row$latest_accepted_request <- as.character(probe_date)
          row$probe_attempts[[length(row$probe_attempts) + 1L]] <- list(date = as.character(probe_date), status = classified$status,
            reason = classified$reason, attempt_count = classified$attempt_count %||% raw$attempt_count %||% 1L,
            accepted_request = isTRUE(raw$accepted_request))
          if (identical(classified$status, "VERIFIED")) {
            row$verification_status <- "VERIFIED"
            row$latest_verified <- as.character(probe_date)

            row$verification_reason <- classified$reason
            row$compatibility_status <- "COMPATIBLE"
            row$finality <- classified$finality
            probe_cache[[row$cache_key]] <<- list(status = "VERIFIED", latest_verified = as.character(probe_date),
              candidate_date = as.character(candidate), request_fingerprint = source$request_fingerprint,
              probe_attempts = row$probe_attempts, finality = classified$finality,
              evidence_recorded_utc = format(as.POSIXct(audit_time, tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))
            break
          }
          if (identical(classified$status, "ERROR")) {
            row$verification_status <- "ERROR"
            row$verification_reason <- classified$reason
            break
          }
          if (identical(classified$compatibility_status, "INCOMPATIBLE")) {
            row$verification_status <- "UNKNOWN"
            row$verification_reason <- classified$reason
            row$compatibility_status <- "INCOMPATIBLE"
            break
          }
          row$verification_status <- "UNAVAILABLE"
          row$verification_reason <- classified$reason
        }
      }
    } else if (isTRUE(probe)) {
      row$verification_status <- "UNKNOWN"
      row$verification_reason <- "No catalog date is available to probe"
    }
    row
  })
  statuses <- vapply(results, function(x) as.character(x$verification_status), character(1))
  endpoints <- vapply(results, function(x) if (is.null(x$latest_verified)) NA_character_ else as.character(x$latest_verified), character(1))
  combine <- all(statuses == "VERIFIED") && all(vapply(results, function(x) identical(x$compatibility_status, "COMPATIBLE"), logical(1)))
  advertised <- vapply(results, function(x) if (is.null(x$latest_advertised)) NA_character_ else as.character(x$latest_advertised), character(1))
  advertised <- advertised[!is.na(advertised) & nzchar(advertised)]
  list(schema_version = CDS_AVAILABILITY_SCHEMA_VERSION,
    audit_timestamp_utc = format(as.POSIXct(audit_time, tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    repository_sha = tryCatch(system2("git", c("-c", paste0("safe.directory=", gsub("\\\\", "/", repo_root)), "-C", repo_root, "rev-parse", "HEAD"), stdout = TRUE, stderr = FALSE)[[1L]], error = function(e) NA_character_),
    sources = results, probe_cache = probe_cache,
    portfolio = list(source_workflow_ids = vapply(results, function(x) x$source_workflow, character(1)),
      verified_common_endpoint = if (combine) as.character(min(as.Date(endpoints))) else NULL,
      metadata_conditional_common_endpoint = if (length(advertised)) as.character(min(as.Date(advertised))) else NULL,
      common_endpoint_status = if (combine) "VERIFIED" else "UNVERIFIED",
      hard_temporal_horizon = "2026-12-31",
      blocker = if (combine) NULL else "At least one source lacks complete verified retrieval evidence or version compatibility"))
}

.cds_availability_sunday <- function(date) as.Date(date) - as.POSIXlt(as.Date(date))$wday
.cds_availability_monday <- function(date) as.Date(date) + ((8L - as.POSIXlt(as.Date(date))$wday) %% 7L)
.cds_availability_week_ids <- function(start, end) {
  if (is.na(start) || is.na(end) || start > end) return(character())
  first_monday <- .cds_availability_monday(start)
  last_sunday <- .cds_availability_sunday(end)
  last_monday <- last_sunday - 6L
  if (first_monday > last_monday) return(character())
  mondays <- seq(first_monday, last_monday, by = "7 days")
  substr(ISOweek::ISOweek(mondays), 1L, 8L)
}
.cds_availability_week_end <- function(ids) {
  ids <- as.character(ids)
  parsed <- lapply(ids, function(id) tryCatch(ISOweek::ISOweek2date(paste0(id, "-7")), error = function(e) as.Date(NA)))
  dates <- as.Date(unlist(parsed, use.names = FALSE), origin = "1970-01-01")
  dates[!is.na(dates)]
}
cds_availability_plan_product <- function(source, product_id, inventory = list(), hard_horizon = "2026-12-31") {
  production_latest <- .cds_availability_date(inventory$latest_validated_daily %||% NULL)
  verified <- .cds_availability_date(source$latest_verified %||% NULL)
  advertised <- .cds_availability_date(source$latest_advertised %||% NULL)
  horizon <- .cds_availability_date(hard_horizon)
  target <- if (!is.na(verified)) min(verified, horizon) else as.Date(NA)
  conditional <- if (!is.na(advertised)) min(advertised, horizon) else as.Date(NA)
  existing_dates <- as.Date(unlist(inventory$daily_dates %||% character(), use.names = FALSE))
  start <- .cds_availability_date(inventory$coverage_start %||% NULL)
  if (is.na(start) && length(existing_dates) && !all(is.na(existing_dates))) start <- min(existing_dates, na.rm = TRUE)
  missing_for <- function(end) {
    if (is.na(end) || is.na(start) || start > end) return(character())
    setdiff(as.character(seq(start, end, by = "day")), as.character(existing_dates))
  }
  verified_missing <- missing_for(target)
  conditional_missing <- missing_for(conditional)
  week_end <- function(end) if (is.na(end)) NULL else as.character(.cds_availability_sunday(end))
  weekly_ids <- as.character(unlist(inventory$weekly_ids %||% character(), use.names = FALSE))
  incremental_start <- if (!is.na(production_latest) && !is.na(start)) max(start, production_latest + 1L) else start
  verified_week_ids <- .cds_availability_week_ids(incremental_start, target)
  conditional_week_ids <- .cds_availability_week_ids(incremental_start, conditional)
  latest_week_end <- .cds_availability_date(inventory$latest_validated_weekly %||% NULL)
  if (is.na(latest_week_end)) {
    existing_week_ends <- .cds_availability_week_end(weekly_ids)
    if (length(existing_week_ends)) latest_week_end <- max(existing_week_ends)
  }
  verified_missing_weeks <- setdiff(verified_week_ids, weekly_ids)
  conditional_missing_weeks <- setdiff(conditional_week_ids, weekly_ids)
  verified_additional_weeks <- if (is.na(latest_week_end)) verified_week_ids else
    verified_week_ids[.cds_availability_week_end(verified_week_ids) > latest_week_end]
  conditional_additional_weeks <- if (is.na(latest_week_end)) conditional_week_ids else
    conditional_week_ids[.cds_availability_week_end(conditional_week_ids) > latest_week_end]
  list(product_id = product_id, source_workflow = source$source_workflow, cds_dataset = source$dataset_id,
    dataset_version = source$dataset_version, cds_latest_advertised = source$latest_advertised,
    cds_latest_verified = source$latest_verified, production_latest = if (is.na(production_latest)) NULL else as.character(production_latest),
    missing_days = if (is.na(target) || is.na(start)) NULL else length(verified_missing), missing_dates = verified_missing,
    catalog_conditional_missing_days = if (is.na(conditional) || is.na(start)) NULL else length(conditional_missing),
    catalog_conditional_missing_dates = conditional_missing, complete_week_endpoint = week_end(target),
    catalog_conditional_complete_week_endpoint = week_end(conditional),
    missing_week_ids = verified_missing_weeks, catalog_conditional_missing_week_ids = conditional_missing_weeks,
    additional_complete_weeks = length(verified_additional_weeks),
    catalog_conditional_additional_complete_weeks = length(conditional_additional_weeks),
    finality = source$finality %||% "NOT_EXPOSED",
    availability_confidence = source$verification_status,
    existing_weekly_count = length(weekly_ids), upstream_beyond_hard_horizon = !is.na(advertised) && advertised > horizon,
    recommended_action = if (identical(source$compatibility_status, "INCOMPATIBLE")) "investigate version compatibility" else
      if (identical(source$verification_status, "VERIFIED") && length(verified_missing)) "update through verified endpoint" else
        if (identical(source$verification_status, "VERIFIED")) "no new verified observations" else "hold update and obtain complete retrieval evidence")
}
cds_availability_update_plan <- function(audit, production_inventory = list(), hard_horizon = "2026-12-31") {
  out <- list()
  for (source in audit$sources) for (product_id in source$products) {
    out[[length(out) + 1L]] <- cds_availability_plan_product(source, product_id, production_inventory[[product_id]] %||% list(), hard_horizon)
  }
  out
}
cds_availability_markdown <- function(audit, update_plan = NULL) {
  lines <- c("# CDS availability discovery", "", paste0("Audit timestamp (UTC): ", audit$audit_timestamp_utc),
    paste0("Repository SHA: ", audit$repository_sha %||% "unknown"), "", "## Portfolio endpoint", "",
    paste0("Verified common endpoint: ", audit$portfolio$verified_common_endpoint %||% "not established"),
    paste0("Metadata-only conditional endpoint: ", audit$portfolio$metadata_conditional_common_endpoint %||% "not established"),
    paste0("Hard temporal horizon: ", audit$portfolio$hard_temporal_horizon),
    paste0("Status: ", audit$portfolio$common_endpoint_status), "", "## Source workflows", "",
    "| Workflow | Dataset | Version | Advertised | Constraint date | Accepted request | Verified | Finality | Status | Catalogue updated |",
    "|---|---|---|---|---|---|---|---|---|---|")
  for (source in audit$sources) lines <- c(lines, paste0("| ", source$source_workflow, " | ", source$dataset_id, " | ",
    source$dataset_version %||% "not configured", " | ", source$latest_advertised %||% "unknown", " | ", source$latest_request_constraints_date %||% "not enumerated", " | ", source$latest_accepted_request %||% "unknown", " | ",
    source$latest_verified %||% "unknown", " | ", source$finality %||% "not exposed", " | ", source$verification_status, " | ", source$updated %||% "unknown", " |"))
  lines <- c(lines, "", "A catalogue temporal extent, sanity-check status, or accepted request does not prove a complete artifact was retrieved. VERIFIED requires the requested time coordinate and every configured variable in the downloaded artifact.")
  if (!is.null(update_plan)) {
    lines <- c(lines, "", "## Product update plan", "",
      "| Product | Source | Production latest | Verified missing days | Catalog-conditional missing days | Complete week endpoint | Additional complete weeks | Missing weekly outputs | Finality | Confidence | Action |",
      "|---|---|---:|---:|---:|---|---:|---|---|---|---|")
    for (row in update_plan) lines <- c(lines, paste0("| ", row$product_id, " | ", row$source_workflow, " | ",
      row$production_latest %||% "unknown", " | ", row$missing_days %||% "unknown", " | ",
      row$catalog_conditional_missing_days %||% "unknown", " | ", row$complete_week_endpoint %||% "unknown",
      " | ", row$catalog_conditional_additional_complete_weeks, " | ", if (length(row$missing_week_ids)) paste(row$missing_week_ids, collapse = ", ") else "none", " | ", row$finality, " | ", row$availability_confidence, " | ", row$recommended_action, " |"))
  }
  paste(lines, collapse = "\n")
}
write_cds_availability_outputs <- function(audit, output_dir, production_inventory = list()) {
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  plan <- cds_availability_update_plan(audit, production_inventory)
  plan_rows <- lapply(plan, function(row) {
    scalar <- function(value, default = NA_character_) if (is.null(value) || !length(value)) default else value[[1L]]
    data.frame(
    product_id = row$product_id, source_workflow = row$source_workflow, cds_dataset = row$cds_dataset,
    dataset_version = scalar(row$dataset_version), cds_latest_advertised = scalar(row$cds_latest_advertised),
    cds_latest_verified = scalar(row$cds_latest_verified), production_latest = scalar(row$production_latest),
    missing_days = scalar(row$missing_days, NA_integer_), missing_dates = paste(row$missing_dates, collapse = ";"),
    catalog_conditional_missing_days = scalar(row$catalog_conditional_missing_days, NA_integer_),
    catalog_conditional_missing_dates = paste(row$catalog_conditional_missing_dates, collapse = ";"),
    complete_week_endpoint = scalar(row$complete_week_endpoint),
    catalog_conditional_complete_week_endpoint = scalar(row$catalog_conditional_complete_week_endpoint),
    missing_week_ids = paste(row$missing_week_ids, collapse = ";"),
    catalog_conditional_missing_week_ids = paste(row$catalog_conditional_missing_week_ids, collapse = ";"),
    additional_complete_weeks = scalar(row$additional_complete_weeks, NA_integer_),
    catalog_conditional_additional_complete_weeks = scalar(row$catalog_conditional_additional_complete_weeks, NA_integer_),
    finality = row$finality,
    availability_confidence = row$availability_confidence, recommended_action = row$recommended_action,
    stringsAsFactors = FALSE)
  })
  json_path <- file.path(output_dir, "cds_availability.json")
  report_path <- file.path(output_dir, "cds_availability_report.md")
  csv_path <- file.path(output_dir, "cds_update_plan.csv")
  jsonlite::write_json(audit, json_path, pretty = TRUE, auto_unbox = TRUE, null = "null", na = "null", digits = NA)
  utils::write.csv(do.call(rbind, plan_rows), csv_path, row.names = FALSE, na = "")
  writeLines(cds_availability_markdown(audit, plan), report_path, useBytes = TRUE)
  invisible(list(json = json_path, report = report_path, update_plan = csv_path))
}

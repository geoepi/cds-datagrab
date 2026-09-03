.portfolio_null_coalesce <- function(x, y) if (is.null(x)) y else x

.portfolio_iso_date <- function(x, field = "date") {
  if (inherits(x, "Date") && length(x) == 1L && !is.na(x)) x <- format(x, "%Y-%m-%d")
  if (length(x) != 1L || is.na(x) || !is.character(x) ||
      !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", x)) {
    stop(field, " must be an ISO YYYY-MM-DD date", call. = FALSE)
  }
  value <- as.Date(x, format = "%Y-%m-%d")
  if (is.na(value) || !identical(format(value, "%Y-%m-%d"), x)) {
    stop(field, " must be an ISO YYYY-MM-DD date", call. = FALSE)
  }
  value
}

.portfolio_availability_field <- function(availability, field) {
  if (is.data.frame(availability)) return(as.character(availability[[field]]))
  rows <- availability %||% list()
  if (!length(rows)) return(character())
  vapply(rows, function(row) {
    value <- row[[field]]
    if (is.null(value) || !length(value) || is.na(value[[1L]])) NA_character_ else as.character(value[[1L]])
  }, character(1))
}

.portfolio_availability_names <- function(availability) {
  if (is.data.frame(availability)) return(as.character(availability$source_workflow))
  rows <- availability %||% list()
  vapply(rows, function(row) as.character(row$source_workflow[[1L]]), character(1))
}

portfolio_source_workflow_ids <- function() c(
  "era5_mintemp", "era5_soilmoist", "era5_lai_low",
  "agera5_relhum_min", "era5land_daily_mean_utc06"
)

portfolio_product_ids <- function() c(
  "era5_mintemp", "era5_soilmoist", "era5_lai_low", "agera5_relhum_min",
  "era5land_tmean", "era5land_soiltemp_l1_mean", "era5land_soiltemp_l2_mean",
  "era5land_soilwater_l1_mean", "era5land_soilwater_l2_mean",
  "era5land_surface_pressure_mean", "era5land_lai_high_mean", "era5land_lai_low_mean"
)

portfolio_read_definition <- function(path = "config/production_portfolio.yml") {
  if (!requireNamespace("yaml", quietly = TRUE)) stop("yaml is required to read the production portfolio definition", call. = FALSE)
  definition <- yaml::read_yaml(path)
  workflows <- definition$source_workflows %||% list()
  if (length(workflows) != 5L) stop("Production portfolio must contain exactly five source workflows", call. = FALSE)
  ids <- vapply(workflows, function(x) as.character(x$id %||% ""), character(1))
  if (!identical(ids, portfolio_source_workflow_ids())) stop("Production portfolio source workflow identifiers are incomplete or out of order", call. = FALSE)
  products <- unlist(lapply(workflows, function(x) as.character(x$products %||% character())), use.names = FALSE)
  if (length(products) != 12L || !identical(products, portfolio_product_ids())) stop("Production portfolio must contain exactly twelve products", call. = FALSE)
  family <- workflows[[5L]]$products
  if (length(family) != 8L) stop("ERA5-Land source family must expand to exactly eight products", call. = FALSE)
  definition$source_workflows <- workflows
  definition$source_workflow_ids <- ids
  definition$product_ids <- products
  definition
}

portfolio_read_source_availability <- function(definition, repo_root = dirname(dirname(attr(definition, "config_path") %||% "config/production_portfolio.yml"))) {
  rows <- lapply(definition$source_workflows, function(workflow) {
    path <- workflow$config
    if (!grepl("^([A-Za-z]:[\\\\/]|/)", path)) path <- file.path(repo_root, path)
    cfg <- tryCatch(yaml::read_yaml(path), error = function(e) NULL)
    temporal <- cfg$temporal %||% list()
    # observed_end records the latest known/validated endpoint in local
    # production provenance; it is not an absolute source-availability limit.
    observed <- temporal$observed_end %||% NA_character_
    known <- !is.null(observed) && length(observed) == 1L && !is.na(observed) && !identical(tolower(as.character(observed)), "auto")
    date <- if (known) tryCatch(as.Date(as.character(observed)), error = function(e) as.Date(NA)) else as.Date(NA)
    if (length(date) != 1L || is.na(date)) known <- FALSE
    configured_start <- tryCatch(as.Date(temporal$configured_start_date %||% temporal$initial_start_date), error = function(e) as.Date(NA))
    configured_end <- tryCatch(as.Date(temporal$configured_end_date %||% temporal$future_end_date %||% temporal$observed_end), error = function(e) as.Date(NA))
    data.frame(source_workflow = workflow$id, config = path,
      known_observed_end = if (known) as.character(date) else NA_character_,
      configured_start = if (!is.na(configured_start)) as.character(configured_start) else NA_character_,
      configured_end = if (!is.na(configured_end)) as.character(configured_end) else NA_character_,
      hard_temporal_end = if (!is.na(configured_end)) as.character(configured_end) else NA_character_,
      available_through = if (known) as.character(date) else NA_character_,
      availability_known = known,
      requested_end = NA_character_, effective_requested_end = NA_character_,
      availability_status = if (known) "known configured observed endpoint" else "unverified (no local endpoint metadata)",
      availability_source = if (known) "configured temporal observed_end" else "uncertain (no local endpoint metadata)",
      stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}

portfolio_complete_iso_weeks <- function(start_date, end_date) {
  dates <- safe_date_sequence(as.Date(start_date), as.Date(end_date))
  if (!length(dates)) return(character())
  groups <- split(dates, format(dates, "%G-W%V"))
  names(groups)[vapply(groups, function(x) length(x) == 7L && min(x) >= as.Date(start_date) && max(x) <= as.Date(end_date), logical(1))]
}

portfolio_configured_inventory_start <- function(definition,
                                                  repo_root = dirname(dirname(attr(definition, "config_path") %||% "config/production_portfolio.yml"))) {
  starts <- vapply(definition$source_workflows, function(workflow) {
    path <- workflow$config
    if (!grepl("^([A-Za-z]:[\\\\/]|/)", path)) path <- file.path(repo_root, path)
    cfg <- yaml::read_yaml(path)
    as.character(as.Date(cfg$temporal$configured_start_date %||% cfg$temporal$initial_start_date))
  }, character(1))
  starts <- as.Date(starts)
  if (anyNA(starts)) stop("Every portfolio source workflow must define a configured production start", call. = FALSE)
  max(starts)
}

portfolio_daily_files <- function(root, profile, product, prefix) {
  directory <- file.path(root, "data", profile, product, "daily")
  if (!dir.exists(directory)) return(list(dates = as.Date(character()), paths = character(), records = data.frame()))
  records <- inventory_grid_directory(directory, prefix, "daily", include_estimated = FALSE)
  records <- records[records$valid & !is.na(records$date), , drop = FALSE]
  list(dates = sort(unique(as.Date(records$date))), paths = records$path, records = records)
}

portfolio_weekly_files <- function(root, profile, product, prefix) {
  directory <- file.path(root, "data", profile, product, "weekly")
  if (!dir.exists(directory)) return(list(weeks = character(), paths = character(), records = data.frame()))
  records <- inventory_grid_directory(directory, prefix, "weekly", include_estimated = FALSE)
  records <- records[records$valid & !is.na(records$iso_year) & !is.na(records$iso_week), , drop = FALSE]
  list(weeks = sort(unique(sprintf("%04d-W%02d", records$iso_year, records$iso_week))), paths = records$path, records = records)
}

portfolio_sidecar_diagnostics <- function(expected_paths) {
  expected_paths <- unique(as.character(expected_paths))
  if (!length(expected_paths)) {
    return(list(expected = character(), present = character(), missing = character(), invalid = character(), valid = TRUE))
  }
  sidecar_paths <- paste0(expected_paths, ".json")
  present <- file.exists(sidecar_paths)
  valid_json <- logical(length(sidecar_paths))
  valid_json[present] <- vapply(sidecar_paths[present], function(path) {
    !is.null(tryCatch(jsonlite::read_json(path, simplifyVector = FALSE), error = function(e) NULL))
  }, logical(1))
  list(
    expected = sidecar_paths,
    present = sidecar_paths[present],
    missing = sidecar_paths[!present],
    invalid = sidecar_paths[present & !valid_json],
    valid = all(present & valid_json)
  )
}

portfolio_resolve_common_start <- function(definition, common_end, output_root = NULL, repo_root = dirname(dirname(attr(definition, "config_path") %||% "config/production_portfolio.yml"))) {
  common_end <- as.Date(common_end)
  starts <- vapply(definition$source_workflows, function(x) {
    path <- x$config; if (!grepl("^([A-Za-z]:[\\\\/]|/)", path)) path <- file.path(repo_root, path)
    cfg <- yaml::read_yaml(path); as.character(as.Date(cfg$temporal$initial_start_date %||% cfg$temporal$configured_start_date))
  }, character(1))
  initial <- max(as.Date(starts))
  if (is.null(output_root) || !nzchar(output_root)) return(initial)
  missing_starts <- as.Date(character())
  for (workflow in definition$source_workflows) for (product in workflow$products) {
    path <- workflow$config; if (!grepl("^([A-Za-z]:[\\\\/]|/)", path)) path <- file.path(repo_root, path)
    cfg <- yaml::read_yaml(path); spec <- get_variable_spec(product)
    inv <- portfolio_daily_files(output_root, as.character(cfg$project$profile %||% "production"), product, spec$daily_filename_prefix)
    expected <- safe_date_sequence(initial, common_end)
    missing <- setdiff(expected, inv$dates)
    if (length(missing)) missing_starts <- c(missing_starts, min(missing))
  }
  if (length(missing_starts)) min(missing_starts) else common_end
}

portfolio_resolve_plan <- function(definition, through = c("latest-common", "explicit"), explicit_end = NULL,
                                   output_root = NULL, repo_root = dirname(dirname(attr(definition, "config_path") %||% "config/production_portfolio.yml"))) {
  through <- match.arg(through)
  availability <- portfolio_read_source_availability(definition, repo_root)
  if (through == "explicit") {
    end <- .portfolio_iso_date(explicit_end, "Explicit portfolio endpoint")
    outside_horizon <- availability$source_workflow[
      is.na(availability$configured_start) |
        is.na(availability$hard_temporal_end) |
        end < as.Date(availability$configured_start) |
        end > as.Date(availability$hard_temporal_end)
    ]
    if (length(outside_horizon)) {
      details <- vapply(outside_horizon, function(source) {
        row <- availability[availability$source_workflow == source, , drop = FALSE]
        horizon <- if (is.na(row$hard_temporal_end[[1L]])) "unknown" else row$hard_temporal_end[[1L]]
        paste0(source, " (hard horizon through ", horizon, ")")
      }, character(1))
      stop("Requested endpoint is outside the configured hard temporal horizon for source workflow(s): ",
        paste(details, collapse = ", "), call. = FALSE)
    }
    availability$availability_status <- ifelse(
      availability$availability_known & as.Date(availability$known_observed_end) >= end,
      "known configured endpoint covers explicit target",
      "unverified explicit target")
  } else {
    if (any(!availability$availability_known)) stop("latest-common cannot be resolved conservatively; availability is uncertain for: ", paste(availability$source_workflow[!availability$availability_known], collapse = ", "), call. = FALSE)
    end <- min(as.Date(availability$available_through))
    availability$availability_status <- "known configured observed endpoint"
  }
  availability$requested_end <- as.character(end)
  availability$effective_requested_end <- as.character(end)
  start <- portfolio_resolve_common_start(definition, end, output_root, repo_root)
  if (start > end) start <- end
  inventory_start <- portfolio_configured_inventory_start(definition, repo_root)
  if (inventory_start > end) inventory_start <- end
  incremental_weeks <- portfolio_complete_iso_weeks(start, end)
  cumulative_weeks <- portfolio_complete_iso_weeks(inventory_start, end)
  products <- lapply(definition$source_workflows, function(workflow) lapply(workflow$products, function(product) {
    path <- workflow$config; if (!grepl("^([A-Za-z]:[\\\\/]|/)", path)) path <- file.path(repo_root, path)
    cfg <- yaml::read_yaml(path); spec <- get_variable_spec(product)
    daily <- if (is.null(output_root)) list(dates = as.Date(character())) else portfolio_daily_files(output_root, cfg$project$profile %||% "production", product, spec$daily_filename_prefix)
    weekly <- if (is.null(output_root)) list(weeks = character()) else portfolio_weekly_files(output_root, cfg$project$profile %||% "production", product, spec$weekly_filename_prefix)
    list(product_id = product, source_workflow = workflow$id, config = path,
      daily_expected = length(safe_date_sequence(start, end)), daily_present = sum(daily$dates >= start & daily$dates <= end),
      weekly_expected = length(incremental_weeks), weekly_present = sum(weekly$weeks %in% incremental_weeks),
      incremental_daily_expected = length(safe_date_sequence(start, end)),
      incremental_daily_present = sum(daily$dates >= start & daily$dates <= end),
      incremental_weekly_expected = length(incremental_weeks),
      incremental_weekly_present = sum(weekly$weeks %in% incremental_weeks),
      portfolio_inventory_start = as.character(inventory_start),
      portfolio_inventory_end = as.character(end),
      cumulative_daily_expected = length(safe_date_sequence(inventory_start, end)),
      cumulative_daily_present = sum(daily$dates >= inventory_start & daily$dates <= end),
      cumulative_weekly_expected = length(cumulative_weeks),
      cumulative_weekly_present = sum(weekly$weeks %in% cumulative_weeks),
      daily_dates = as.character(daily$dates), weekly_ids = weekly$weeks)
  }))
  list(status = "planned", endpoint_policy = through,
    requested_through = if (through == "explicit") as.character(end) else "latest-common",
    requested_end = if (through == "explicit") as.character(end) else NULL,
    requested_explicit_end = if (through == "explicit") as.character(end) else NULL,
    effective_requested_end = as.character(end),
    common_start = as.character(start), common_end = as.character(end), complete_iso_weeks = incremental_weeks,
    incremental_work_start = as.character(start), incremental_work_end = as.character(end),
    incremental_complete_iso_week_count = length(incremental_weeks),
    portfolio_inventory_start = as.character(inventory_start), portfolio_inventory_end = as.character(end),
    cumulative_complete_iso_week_count = length(cumulative_weeks), cumulative_complete_iso_weeks = cumulative_weeks,
    availability = availability, products = unlist(products, recursive = FALSE), source_workflows = definition$source_workflows,
    source_workflow_ids = definition$source_workflow_ids, product_ids = definition$product_ids)
}

portfolio_validate_synchronization <- function(products, common_start, common_end,
                                               inventory_start = NULL, inventory_end = NULL) {
  inventory_start <- as.Date(inventory_start %||% common_start)
  inventory_end <- as.Date(inventory_end %||% common_end)
  expected_daily <- safe_date_sequence(inventory_start, inventory_end)
  expected_weekly <- portfolio_complete_iso_weeks(inventory_start, inventory_end)
  incremental_daily <- safe_date_sequence(as.Date(common_start), as.Date(common_end))
  incremental_weekly <- portfolio_complete_iso_weeks(common_start, common_end)
  rows <- lapply(products, function(product) {
    present_daily <- sort(unique(as.Date(product$daily_dates %||% character())))
    present_weekly <- sort(unique(as.character(product$weekly_ids %||% character())))
    missing_daily <- setdiff(expected_daily, present_daily); extra_daily <- setdiff(present_daily, expected_daily)
    missing_weekly <- setdiff(expected_weekly, present_weekly); extra_weekly <- setdiff(present_weekly, expected_weekly)
    ok <- sum(length(missing_daily), length(extra_daily), length(missing_weekly), length(extra_weekly)) == 0L && isTRUE(product$geometry_valid %||% TRUE) && isTRUE(product$sidecars_valid %||% TRUE) && isTRUE(product$value_validation_valid %||% TRUE)
    list(product_id = product$product_id,
      daily_expected = length(expected_daily), daily_present = sum(present_daily %in% expected_daily),
      daily_missing = as.character(missing_daily), daily_extra = as.character(extra_daily),
      weekly_expected = length(expected_weekly), weekly_present = sum(present_weekly %in% expected_weekly),
      weekly_missing = missing_weekly, weekly_extra = extra_weekly,
      incremental_daily_expected = length(incremental_daily),
      incremental_daily_present = sum(present_daily %in% incremental_daily),
      incremental_weekly_expected = length(incremental_weekly),
      incremental_weekly_present = sum(present_weekly %in% incremental_weekly),
      status = if (ok) "success" else "failed")
  })
  names(rows) <- vapply(products, function(x) x$product_id, character(1))
  list(common_daily_start = as.character(common_start), common_daily_end = as.character(common_end),
    incremental_work_start = as.character(common_start), incremental_work_end = as.character(common_end),
    portfolio_inventory_start = as.character(inventory_start), portfolio_inventory_end = as.character(inventory_end),
    complete_iso_week_count = length(expected_weekly),
    incremental_complete_iso_week_count = length(incremental_weekly),
    cumulative_complete_iso_week_count = length(expected_weekly),
    expected_daily_dates = as.character(expected_daily), expected_iso_weeks = expected_weekly,
    products = rows,
    status = if (all(vapply(rows, function(x) identical(x$status, "success"), logical(1)))) "success" else "failed")
}

portfolio_validate_output_root <- function(plan, output_root,
    repo_root = dirname(dirname(attr(plan, "config_path") %||% "config/production_portfolio.yml"))) {
  work_start <- as.Date(plan$incremental_work_start %||% plan$common_start)
  work_end <- as.Date(plan$incremental_work_end %||% plan$common_end)
  portfolio_inventory_start <- as.Date(plan$portfolio_inventory_start %||% plan$common_start)
  portfolio_inventory_end <- as.Date(plan$portfolio_inventory_end %||% plan$common_end)
  records <- lapply(plan$products, function(product) {
    cfg <- yaml::read_yaml(product$config)
    cfg$project$dataset_id <- product$product_id
    spec <- get_variable_spec(product$product_id, cfg)
    template_path <- cfg$spatial$template_path
    if (!grepl("^([A-Za-z]:[\\\\/]|/)", template_path)) template_path <- file.path(repo_root, template_path)
    cfg$spatial$template_path <- normalizePath(template_path, winslash = "/", mustWork = FALSE)
    if (!is.null(cfg$spatial$bbox_path) && !grepl("^([A-Za-z]:[\\\\/]|/)", cfg$spatial$bbox_path)) cfg$spatial$bbox_path <- file.path(repo_root, cfg$spatial$bbox_path)
    if (!is.null(cfg$coverage)) for (field in c("support_mask", "unsupported_cells_audit")) if (!is.null(cfg$coverage[[field]]) && !grepl("^([A-Za-z]:[\\\\/]|/)", cfg$coverage[[field]])) cfg$coverage[[field]] <- file.path(repo_root, cfg$coverage[[field]])
    profile <- as.character(cfg$project$profile %||% "production")
    daily <- portfolio_daily_files(output_root, profile, product$product_id, spec$daily_filename_prefix)
    weekly <- portfolio_weekly_files(output_root, profile, product$product_id, spec$weekly_filename_prefix)
    expected_daily <- safe_date_sequence(portfolio_inventory_start, portfolio_inventory_end)
    expected_weeks <- plan$cumulative_complete_iso_weeks %||% portfolio_complete_iso_weeks(portfolio_inventory_start, portfolio_inventory_end)
    daily_dir <- file.path(output_root, "data", profile, product$product_id, "daily")
    weekly_dir <- file.path(output_root, "data", profile, product$product_id, "weekly")
    expected_daily_paths <- file.path(daily_dir, vapply(expected_daily, function(date) daily_output_filename(spec, date), character(1)))
    expected_weekly_paths <- if (length(expected_weeks)) {
      file.path(weekly_dir, vapply(expected_weeks, function(week_id) {
        parts <- strsplit(week_id, "-W", fixed = TRUE)[[1L]]
        weekly_output_filename(spec, as.integer(parts[[1L]]), as.integer(parts[[2L]]))
      }, character(1)))
    } else character()
    daily_sidecars <- portfolio_sidecar_diagnostics(expected_daily_paths)
    weekly_sidecars <- portfolio_sidecar_diagnostics(expected_weekly_paths)
    daily_in_range <- daily$records[daily$records$date >= min(portfolio_inventory_start) & daily$records$date <= max(portfolio_inventory_end), , drop = FALSE]
    weekly_in_range <- weekly$records[weekly$weeks %in% expected_weeks, , drop = FALSE]
    sidecars_valid <- isTRUE(daily_sidecars$valid) && isTRUE(weekly_sidecars$valid)
    geometry_valid <- FALSE
    value_valid <- FALSE
    weekly_valid <- TRUE
    if (requireNamespace("terra", quietly = TRUE) && file.exists(cfg$spatial$template_path)) {
      inv <- tryCatch(inventory_daily_products(file.path(output_root, "data", profile, product$product_id, "daily"), spec$daily_filename_prefix, cfg$spatial$template_path, TRUE, cfg), error = function(e) NULL)
      if (!is.null(inv)) {
        target <- inv[inv$date %in% expected_daily & !inv$estimated, , drop = FALSE]
        geometry_valid <- nrow(target) == length(expected_daily) && all(target$geometry_valid %in% TRUE) && all(target$crs_valid %in% TRUE) && all(target$template_coverage_complete %in% TRUE)
        value_valid <- nrow(target) == length(expected_daily) && all(target$value_range_valid %in% TRUE) && all(target$observed_valid %in% TRUE)
      }
      template <- tryCatch(terra::rast(cfg$spatial$template_path), error = function(e) NULL)
      if (!is.null(template)) for (i in seq_len(nrow(weekly_in_range))) {
        w <- weekly_in_range[i, ]
        check <- tryCatch(validate_weekly_output(w$path, w$iso_year, w$iso_week, template, cfg, spec), error = function(e) list(valid = FALSE))
        weekly_valid <- weekly_valid && isTRUE(check$valid)
      }
    }
    list(product_id = product$product_id,
      daily_dates = as.character(if (geometry_valid && value_valid) daily$dates else daily$dates),
      weekly_ids = if (weekly_valid) weekly$weeks else weekly$weeks,
      geometry_valid = geometry_valid, sidecars_valid = sidecars_valid,
      value_validation_valid = value_valid, weekly_validation_valid = weekly_valid,
      daily_sidecars_expected = daily_sidecars$expected,
      daily_sidecars_present = daily_sidecars$present,
      daily_sidecars_missing = daily_sidecars$missing,
      daily_sidecars_invalid = daily_sidecars$invalid,
      weekly_sidecars_expected = weekly_sidecars$expected,
      weekly_sidecars_present = weekly_sidecars$present,
      weekly_sidecars_missing = weekly_sidecars$missing,
      weekly_sidecars_invalid = weekly_sidecars$invalid)
  })
  validation <- portfolio_validate_synchronization(records, work_start, work_end, portfolio_inventory_start, portfolio_inventory_end)
  for (i in seq_along(validation$products)) {
    validation$products[[i]]$geometry_valid <- records[[i]]$geometry_valid
    validation$products[[i]]$sidecars_valid <- records[[i]]$sidecars_valid
    validation$products[[i]]$value_validation_valid <- records[[i]]$value_validation_valid
    validation$products[[i]]$weekly_validation_valid <- records[[i]]$weekly_validation_valid
    for (field in c("daily_sidecars_expected", "daily_sidecars_present", "daily_sidecars_missing", "daily_sidecars_invalid",
                    "weekly_sidecars_expected", "weekly_sidecars_present", "weekly_sidecars_missing", "weekly_sidecars_invalid")) {
      validation$products[[i]][[field]] <- records[[i]][[field]]
    }
    if (!isTRUE(records[[i]]$weekly_validation_valid)) validation$products[[i]]$status <- "failed"
  }
  validation$status <- if (all(vapply(validation$products, function(x) identical(x$status, "success"), logical(1)))) "success" else "failed"
  validation
}

portfolio_manifest_path <- function(output_root, run_id) file.path(output_root, "runs", "production", "_portfolio", run_id, "portfolio_manifest.json")

portfolio_validate_chime_execution_id <- function(value = Sys.getenv("CHIME_EXECUTION_ID", unset = "")) {
  if (length(value) != 1L || is.na(value) || !nzchar(value)) return(NULL)
  value <- as.character(value)
  if (nchar(value, type = "bytes") > 128L || !grepl("^[A-Za-z0-9_.:-]+$", value, perl = TRUE)) {
    stop("CHIME_EXECUTION_ID must be a non-empty identifier of at most 128 safe characters", call. = FALSE)
  }
  value
}

portfolio_new_manifest <- function(plan, output_root, run_id = NULL, source_commit = "unavailable", installed_commit = "unavailable") {
  if (is.null(run_id)) run_id <- paste0(format(Sys.time(), "%Y%m%dT%H%M%SZ", tz = "UTC"), "_portfolio")
  chime_execution_id <- portfolio_validate_chime_execution_id()
  availability_names <- .portfolio_availability_names(plan$availability)
  known_observed_end <- .portfolio_availability_field(plan$availability, "known_observed_end")
  availability_status <- .portfolio_availability_field(plan$availability, "availability_status")
  list(run_id = run_id, started_at = format(Sys.time(), tz = "UTC", usetz = TRUE), completed_at = NULL,
    chime_execution_id = chime_execution_id,
    source_git_commit = source_commit, installed_git_commit = installed_commit, profile = "production", output_root = output_root,
    endpoint_policy = plan$endpoint_policy, requested_through = plan$requested_through,
    requested_end = plan$requested_end, requested_explicit_end = plan$requested_explicit_end,
    effective_requested_end = plan$effective_requested_end,
    known_observed_end = setNames(as.list(known_observed_end), availability_names),
    availability_status = setNames(as.list(availability_status), availability_names),
    common_daily_start = plan$common_start, common_daily_end = plan$common_end,
    incremental_work_start = plan$incremental_work_start %||% plan$common_start,
    incremental_work_end = plan$incremental_work_end %||% plan$common_end,
    incremental_complete_iso_week_count = plan$incremental_complete_iso_week_count %||% length(plan$complete_iso_weeks),
    portfolio_inventory_start = plan$portfolio_inventory_start %||% plan$common_start,
    portfolio_inventory_end = plan$portfolio_inventory_end %||% plan$common_end,
    cumulative_complete_iso_week_count = plan$cumulative_complete_iso_week_count %||% length(plan$complete_iso_weeks),
    complete_iso_week_count = plan$cumulative_complete_iso_week_count %||% length(plan$complete_iso_weeks),
    source_workflow_ids = plan$source_workflow_ids, product_ids = plan$product_ids, source_workflows = plan$source_workflows,
    products = plan$products, manifest_directory = file.path(output_root, "runs", "production", "_portfolio", run_id), source_job_ids = list(), aggregation_job_ids = list(), validation_job_id = NULL,
    source_job_outcomes = list(), dependencies = list(), status = "planned", failure_stage = NULL, failure_message = NULL, plan = plan)
}

portfolio_write_manifest <- function(manifest, path = file.path(manifest$manifest_directory, "portfolio_manifest.json")) {
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("jsonlite is required to write a portfolio manifest", call. = FALSE)
  safe <- function(x) { if (inherits(x, "Date")) return(as.character(x)); if (is.list(x)) return(lapply(x, safe)); x }
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(safe(manifest), path, pretty = TRUE, auto_unbox = TRUE, null = "null")
  invisible(path)
}

portfolio_classify_job_state <- function(state) {
  if (is.null(state) || !length(state) || is.na(state[[1L]]) || !nzchar(as.character(state[[1L]]))) return("unknown")
  state <- toupper(trimws(as.character(state[[1L]])))
  state <- sub("[+].*$", "", state)
  if (state == "COMPLETED") return("success")
  if (state %in% c("RUNNING", "COMPLETING", "CONFIGURING", "SUSPENDED", "SIGNALING", "STAGE_OUT", "RESIZING")) return("running")
  if (state %in% c("PENDING", "REQUEUED", "REQUEUE_FED", "RESV_DEL_HOLD")) return("submitted")
  if (state %in% c("CANCELLED", "DEPENDENCY_NEVER_SATISFIED", "REVOKED")) return("cancelled")
  if (state %in% c("FAILED", "TIMEOUT", "OUT_OF_MEMORY", "NODE_FAIL", "PREEMPTED", "BOOT_FAIL", "DEADLINE", "LAUNCH_FAILED", "SPECIAL_EXIT")) return("failed")
  "unknown"
}

portfolio_manifest_job_ids <- function(manifest) {
  ids <- c(unlist(manifest$source_job_ids %||% list(), use.names = FALSE),
    unlist(manifest$aggregation_job_ids %||% list(), use.names = FALSE),
    manifest$validation_job_id %||% character())
  ids <- as.character(ids)
  unique(ids[nzchar(ids) & !is.na(ids)])
}

portfolio_reconcile_manifest <- function(manifest, job_states) {
  if (!is.list(manifest)) stop("manifest must be a list", call. = FALSE)
  job_state_names <- names(job_states)
  job_states <- as.character(job_states)
  names(job_states) <- job_state_names
  if (!length(job_states) || is.null(names(job_states))) stop("job_states must be a named vector", call. = FALSE)
  job_states <- job_states[!is.na(names(job_states)) & nzchar(names(job_states))]
  state_class <- vapply(job_states, portfolio_classify_job_state, character(1))
  scheduler_states <- setNames(lapply(names(job_states), function(id) {
    list(raw_state = unname(job_states[[id]]), state_class = state_class[[id]])
  }), names(job_states))
  manifest$scheduler_states <- scheduler_states

  current <- as.character(manifest$status %||% "unknown")
  if (current %in% c("success", "failed", "cancelled")) {
    return(list(manifest = manifest, changed = FALSE, reason = "manifest already terminal", state_class = current))
  }
  lookup <- function(id) {
    if (is.null(id) || !length(id) || is.na(id[[1L]]) || !nzchar(as.character(id[[1L]]))) return(list(raw = NA_character_, class = "unknown"))
    key <- as.character(id[[1L]])
    if (!key %in% names(job_states)) return(list(raw = NA_character_, class = "unknown"))
    list(raw = unname(job_states[[key]]), class = unname(state_class[[key]]))
  }
  role_states <- function(ids) {
    if (!length(ids)) return(list())
    setNames(lapply(ids, lookup), names(ids))
  }
  source_states <- role_states(manifest$source_job_ids %||% list())
  aggregation_states <- role_states(manifest$aggregation_job_ids %||% list())
  validation <- lookup(manifest$validation_job_id)
  bad <- function(states) length(states) && any(vapply(states, function(x) x$class %in% c("failed", "cancelled"), logical(1)))
  describe <- function(role, states) {
    if (!length(states)) return(character())
    ids <- names(states)[vapply(states, function(x) x$class %in% c("failed", "cancelled"), logical(1))]
    if (!length(ids)) return(character())
    paste0(role, " ", ids, " (", vapply(states[ids], function(x) x$raw %||% "unknown", character(1)), ")")
  }
  upstream <- c(describe("source job", source_states), describe("aggregation job", aggregation_states))
  changed <- FALSE
  reason <- "no terminal lifecycle change"
  if (validation$class == "running" && current == "validation_submitted") {
    manifest$status <- "validation_running"
    changed <- TRUE
    reason <- "validation job is running"
  } else if (validation$class == "cancelled") {
    manifest$status <- "cancelled"
    manifest$failure_stage <- if (length(upstream)) if (bad(source_states)) "source" else "aggregation" else "validation"
    manifest$failure_message <- paste("Validation job", manifest$validation_job_id, "was cancelled before portfolio validation completed.",
      if (length(upstream)) paste("Upstream terminal states:", paste(upstream, collapse = "; ")) else "Inspect the Slurm reason and dependency chain.")
    manifest$completed_at <- format(Sys.time(), tz = "UTC", usetz = TRUE)
    changed <- TRUE
    reason <- "validation job was cancelled"
  } else if (validation$class == "failed") {
    manifest$status <- "failed"
    manifest$failure_stage <- if (length(upstream)) if (bad(source_states)) "source" else "aggregation" else "validation"
    manifest$failure_message <- paste("Portfolio validation job", manifest$validation_job_id, "did not complete successfully.",
      if (length(upstream)) paste("Upstream terminal states:", paste(upstream, collapse = "; ")) else "Inspect the validation Slurm log.")
    manifest$completed_at <- format(Sys.time(), tz = "UTC", usetz = TRUE)
    changed <- TRUE
    reason <- "validation job failed"
  } else if (bad(source_states) || bad(aggregation_states)) {
    manifest$status <- if (bad(source_states) && any(vapply(source_states, function(x) x$class == "cancelled", logical(1)))) "cancelled" else "failed"
    manifest$failure_stage <- if (bad(source_states)) "source" else "aggregation"
    manifest$failure_message <- paste("Portfolio dependency chain has terminal upstream states:", paste(upstream, collapse = "; "))
    manifest$completed_at <- format(Sys.time(), tz = "UTC", usetz = TRUE)
    changed <- TRUE
    reason <- "upstream dependency failed or was cancelled"
  }
  list(manifest = manifest, changed = changed, reason = reason, state_class = manifest$status)
}

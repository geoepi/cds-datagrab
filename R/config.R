`%||%` <- function(x, y) if (is.null(x)) y else x

resolve_project_root <- function(start = getwd()) {
  p <- normalizePath(start, winslash = "/", mustWork = TRUE)
  while (!file.exists(file.path(p, "DESCRIPTION")) && dirname(p) != p) p <- dirname(p)
  if (!file.exists(file.path(p, "DESCRIPTION"))) stop("Could not locate project root from ", start)
  p
}

expand_config_environment <- function(config) {
  walk <- function(x) if (is.list(x)) lapply(x, walk) else if (is.character(x)) {
    vapply(x, function(z) {
      m <- regmatches(z, gregexpr("\\$\\{[A-Za-z_][A-Za-z0-9_]*\\}", z))[[1]]
      for (a in m) z <- sub(a, Sys.getenv(substr(a, 3, nchar(a) - 1), a), z, fixed = TRUE)
      z
    }, character(1))
  } else x
  walk(config)
}

read_pipeline_config <- function(path) {
  if (!requireNamespace("yaml", quietly = TRUE)) stop("Package 'yaml' is required")
  if (!file.exists(path)) stop("Configuration does not exist: ", path)
  cfg <- expand_config_environment(yaml::read_yaml(path))
  cfg$config_path <- normalizePath(path, winslash = "/", mustWork = TRUE)
  cfg
}

.normal_path <- function(x, project_root) {
  if (!is.character(x) || length(x) != 1L || !nzchar(x)) stop("Output root must not be empty", call. = FALSE)
  if (grepl("(^|[/\\\\])\\.\\.([/\\\\]|$)", x)) stop("Output root must not contain path traversal components", call. = FALSE)
  if (!grepl("^(?:[A-Za-z]:|/|\\\\)", x)) x <- file.path(project_root, x)
  normalizePath(x, winslash = "/", mustWork = FALSE)
}
.descendant <- function(path, root) {
  p <- normalizePath(path, winslash = "/", mustWork = FALSE)
  r <- normalizePath(root, winslash = "/", mustWork = FALSE)
  identical(tolower(p), tolower(r)) || startsWith(tolower(p), paste0(tolower(r), "/"))
}
.reject_root <- function(root, project_root, explicit = TRUE) {
  if (!nzchar(root) || root %in% c("/", "\\")) stop("Output root is invalid", call. = FALSE)
  home <- normalizePath(path.expand("~"), winslash = "/", mustWork = FALSE)
  old <- "/project/disease_ecology/NWScrewworm"
  legacy <- c(
    "/project/disease_ecology/cds-datagrab-production-output",
    "/project/disease_ecology/cds-datagrab-soilmoist-production-output",
    "/project/disease_ecology/cds-datagrab-lai-low-production-output",
    "/project/disease_ecology/cds-datagrab-relhum-min-production-output"
  )
  if (identical(tolower(root), tolower(home))) stop("User home directory cannot be the output root", call. = FALSE)
  if (identical(tolower(root), tolower(normalizePath(project_root, winslash = "/", mustWork = TRUE)))) stop("Repository root cannot be the output root", call. = FALSE)
  if (isTRUE(explicit) && .descendant(root, project_root)) stop("CDS_DATAGRAB_ROOT must be outside the repository checkout", call. = FALSE)
  if (grepl("NWScrewworm", root, ignore.case=TRUE) || identical(tolower(root), tolower(old)) || startsWith(tolower(root), paste0(tolower(old), "/"))) stop("The old NWScrewworm data root is not permitted", call. = FALSE)
  if (isTRUE(explicit) && (any(tolower(root) == tolower(legacy)) || grepl("cds-datagrab-(production|soilmoist-production|lai-low-production|relhum-min-production)-output", root, ignore.case=TRUE))) warning("CDS_DATAGRAB_ROOT explicitly names a retired product-specific root; use the consolidated root instead.", call.=FALSE)
}

resolve_output_root <- function(profile, project_root, output_root = NULL) {
  if (!profile %in% c("production", "smoke")) stop("profile must be production or smoke", call.=FALSE)
  explicit <- if (!is.null(output_root) && nzchar(output_root)) output_root else Sys.getenv("CDS_DATAGRAB_ROOT", "")
  if (nzchar(explicit)) return(list(value=.normal_path(explicit, project_root), source=if (!is.null(output_root) && nzchar(output_root)) "argument" else "CDS_DATAGRAB_ROOT"))
  profile_var <- if (profile == "production") "CDS_DATAGRAB_PRODUCTION_ROOT" else "CDS_DATAGRAB_SMOKE_ROOT"
  profile_root <- Sys.getenv(profile_var, "")
  if (nzchar(profile_root)) return(list(value=.normal_path(profile_root, project_root), source=profile_var))
  list(value=.normal_path(file.path("runtime", "cds-datagrab"), project_root), source="portable_default")
}

resolve_storage_paths <- function(config, project_root, output_root = NULL, create = FALSE) {
  profile <- as.character(config$project$profile %||% "")
  dataset <- as.character(config$project$dataset_id %||% "")
  if (length(profile) != 1L || !profile %in% c("smoke", "production")) stop("project.profile must be 'smoke' or 'production'", call. = FALSE)
  if (length(dataset) != 1L || !nzchar(dataset) || grepl("[/\\\\]", dataset) || grepl("\\.\\.", dataset)) stop("project.dataset_id is invalid", call. = FALSE)
  obsolete <- Sys.getenv("CDS_DATAGRAB_DATA_ROOT", "")
  if (nzchar(obsolete)) warning("CDS_DATAGRAB_DATA_ROOT is obsolete and is ignored.\nSet CDS_DATAGRAB_ROOT instead.", call. = FALSE)
  configured <- config$paths$root %||% ""
  resolved <- if (nzchar(configured) && is.null(output_root) && !nzchar(Sys.getenv("CDS_DATAGRAB_ROOT", ""))) list(value=.normal_path(configured, project_root), source="configuration") else resolve_output_root(profile, project_root, output_root)
  root <- resolved$value; .reject_root(root, project_root, !identical(resolved$source, "portable_default"))
  if (file.exists(file.path(root, ".cds-datagrab-root"))) { marker <- tryCatch(jsonlite::read_json(file.path(root, ".cds-datagrab-root"), simplifyVector=TRUE), error=function(e)NULL); if (!is.null(marker) && !identical(marker$application, "cds-datagrab")) stop("Existing storage root marker is not owned by cds-datagrab", call.=FALSE) }
  dataset_root <- file.path(root, "data", profile, dataset)
  run_root <- file.path(root, "runs", profile, dataset)
  p <- list(root = root, root_source = resolved$source, profile = profile, dataset_id = dataset, dataset_root = dataset_root,
            raw_dir = file.path(dataset_root, "raw"), raw_quarantine_dir = file.path(dataset_root, "quarantine", "raw"), quarantine_dir = file.path(dataset_root, "quarantine"), extracted_dir = file.path(dataset_root, "extracted"),
            daily_dir = file.path(dataset_root, "daily"), weekly_dir = file.path(dataset_root, "weekly"),
            temp_dir = file.path(dataset_root, "temp"), cache_dir = file.path(dataset_root, "cache"),
            runs_root = run_root, run_dir = NULL,
            pipeline_log_dir = file.path(root, "logs", "pipeline", profile, dataset),
            slurm_log_dir = file.path(root, "logs", "slurm", profile),
            root_marker = file.path(root, ".cds-datagrab-root"))
  path_names <- c("root", "dataset_root", "raw_dir", "raw_quarantine_dir", "quarantine_dir", "extracted_dir", "daily_dir", "weekly_dir", "temp_dir", "cache_dir", "runs_root", "pipeline_log_dir", "slurm_log_dir", "root_marker")
  all_paths <- unname(unlist(p[path_names], use.names = FALSE)); if (any(!vapply(all_paths, .descendant, logical(1), root = root))) stop("Resolved path escaped output root", call. = FALSE)
  if (create) {
    fs::dir_create(root, recurse = TRUE)
    if (file.exists(p$root_marker)) { marker <- tryCatch(jsonlite::read_json(p$root_marker, simplifyVector=TRUE), error=function(e)NULL); if (is.null(marker) || !identical(marker$application, "cds-datagrab")) stop("Existing storage root marker is not owned by cds-datagrab", call.=FALSE) } else jsonlite::write_json(list(application = "cds-datagrab", schema_version = 3L, profiles = c("production", "smoke"), created_utc = format(Sys.time(), tz = "UTC"), created_by = Sys.info()[["user"]]), p$root_marker, auto_unbox = TRUE, pretty = TRUE)
    fs::dir_create(unname(unlist(p[c("raw_dir", "raw_quarantine_dir", "quarantine_dir", "extracted_dir", "daily_dir", "weekly_dir", "temp_dir", "cache_dir", "runs_root", "pipeline_log_dir", "slurm_log_dir")], use.names=FALSE)), recurse = TRUE)
  }
  p
}

resolve_config_paths <- function(config, project_root, output_root = NULL, create = FALSE) {
  config$project_root <- normalizePath(project_root, winslash = "/", mustWork = TRUE)
  config$paths <- config$paths %||% list(root = NULL)
  p <- resolve_storage_paths(config, project_root, output_root, create)
  for (n in names(p)) config$paths[[n]] <- p[[n]]
  config$spatial$template_path <- .normal_path(config$spatial$template_path, project_root)
  config$spatial$bbox_path <- .normal_path(config$spatial$bbox_path, project_root)
  if (!is.null(config$coverage)) {
    if (!is.null(config$coverage$support_mask)) config$coverage$support_mask <- .normal_path(config$coverage$support_mask, project_root)
    if (!is.null(config$coverage$unsupported_cells_audit)) config$coverage$unsupported_cells_audit <- .normal_path(config$coverage$unsupported_cells_audit, project_root)
  }
  config
}

resolve_source_storage_paths <- function(config, project_root, output_root = NULL, create = FALSE) {
  profile <- as.character(config$project$profile %||% "")
  family <- as.character(config$project$source_family_id %||% config$source_family_id %||% "")
  if (!profile %in% c("production", "smoke")) stop("project.profile must be smoke or production", call.=FALSE)
  if (!nzchar(family) || grepl("[/\\\\]", family) || grepl("\\.\\.", family)) stop("source_family_id is invalid", call.=FALSE)
  root_info <- resolve_output_root(profile, project_root, output_root); root <- root_info$value; .reject_root(root, project_root, !identical(root_info$source, "portable_default"))
  source_root <- file.path(root, "data", profile, "_sources", family)
  p <- list(root=root, root_source=root_info$source, profile=profile, source_family_id=family, source_root=source_root, dataset_root=source_root, requests_dir=file.path(source_root,"requests"), request_registry=file.path(source_root,"requests","request_registry.csv"), runs_root=file.path(root,"runs",profile,"_sources",family), pipeline_log_dir=file.path(root,"logs","pipeline",profile,"_sources",family), slurm_log_dir=file.path(root,"logs","slurm",profile),
    raw_dir=file.path(source_root,"raw"), raw_quarantine_dir=file.path(source_root,"quarantine","raw"), extracted_dir=file.path(source_root,"extracted"), cache_dir=file.path(source_root,"cache"), root_marker=file.path(root,".cds-datagrab-root"))
  if (any(!vapply(p[c("source_root","raw_dir","extracted_dir","cache_dir")], .descendant, logical(1), root=root))) stop("Resolved source path escaped output root", call.=FALSE)
  if (create) { fs::dir_create(root, recurse=TRUE); if (!file.exists(p$root_marker)) jsonlite::write_json(list(application="cds-datagrab",schema_version=3L,profiles=c("production","smoke"),created_utc=format(Sys.time(),tz="UTC")),p$root_marker,auto_unbox=TRUE,pretty=TRUE); fs::dir_create(unname(unlist(p[c("requests_dir","raw_dir","raw_quarantine_dir","extracted_dir","cache_dir","runs_root","pipeline_log_dir","slurm_log_dir")],use.names=FALSE)),recurse=TRUE) }
  p
}

validate_pipeline_config <- function(config) {
  req <- c("project", "spatial", "paths", "temporal", "cds", "processing", "weekly", "future", "validation")
  miss <- req[!vapply(req, function(x) !is.null(config[[x]]), logical(1))]
  if (length(miss)) stop("Missing configuration sections: ", paste(miss, collapse = ", "))
  if (!is.null(config$project$profile) && !config$project$profile %in% c("smoke", "production")) stop("project.profile must be smoke or production")
  if (!file.exists(config$spatial$template_path)) stop("Template raster is missing: ", config$spatial$template_path)
  if (!file.exists(config$spatial$bbox_path)) stop("Bounding-box file is missing: ", config$spatial$bbox_path)
  if (!config$weekly$aggregation %in% c("min","mean")) stop("weekly.aggregation must be 'min' or 'mean'")
  config$temporal$initial_start_date <- as.Date(config$temporal$initial_start_date)
  config$temporal$future_end_date <- as.Date(config$temporal$future_end_date)
  if (is.character(config$temporal$observed_end) && config$temporal$observed_end == "auto") config$temporal$observed_end <- Sys.Date() - as.integer(config$temporal$source_lag_days) else config$temporal$observed_end <- as.Date(config$temporal$observed_end)
  if (anyNA(c(config$temporal$initial_start_date, config$temporal$observed_end, config$temporal$future_end_date))) stop("Invalid configured date")
  spec <- get_variable_spec(config$project$dataset_id, config)
  if (config$cds$variable != spec$cds_variable || config$cds$daily_statistic != spec$daily_statistic) stop("Configuration does not match variable specification")
  if (identical(as.character(spec$source_family_id %||% ""), "era5land_daily_mean_utc06")) {
    if (is.null(config$coverage)) stop("ERA5-Land coverage.support_mask and coverage.unsupported_cells_audit are required")
    if (is.null(config$coverage$support_mask) || is.null(config$coverage$unsupported_cells_audit)) stop("ERA5-Land coverage.support_mask and coverage.unsupported_cells_audit are required")
    if (!file.exists(config$coverage$support_mask) || !file.exists(config$coverage$unsupported_cells_audit)) stop("Configured ERA5-Land support-mask files are missing")
    if (!is.null(config$coverage$local_target_radius_cells) && as.integer(config$coverage$local_target_radius_cells) != 2L) stop("ERA5-Land local_target_radius_cells must remain 2")
    if (!is.null(config$coverage$source_buffer_max_km) && as.numeric(config$coverage$source_buffer_max_km) > 35) stop("ERA5-Land source_buffer_max_km must not exceed 35 km")
  }
  if (!is.null(config$spatial$expected_crs) && requireNamespace("terra", quietly = TRUE)) { validate_template_crs(terra::rast(config$spatial$template_path), config$spatial$expected_crs, config$spatial$geometry_tolerance %||% 0.001); validate_template_geometry(terra::rast(config$spatial$template_path), list(rows=config$spatial$expected_dimensions$rows, columns=config$spatial$expected_dimensions$columns, layers=config$spatial$expected_dimensions$layers, resolution=config$spatial$expected_resolution, extent=config$spatial$expected_extent), config$spatial$geometry_tolerance %||% 0.001) }
  config
}

resolve_pipeline_date_window <- function(config, start_date=NULL, end_date=NULL, dry_run=FALSE) {
  temporal <- config$temporal
  configured_start <- as.Date(temporal$configured_start_date %||% temporal$initial_start_date)
  configured_end <- as.Date(temporal$configured_end_date %||% temporal$future_end_date %||% temporal$observed_end)
  observed_end <- if (identical(temporal$observed_end, "auto")) Sys.Date() - as.integer(temporal$source_lag_days %||% 0L) else as.Date(temporal$observed_end)
  requested_start <- as.Date(start_date %||% configured_start)
  requested_end <- as.Date(end_date %||% configured_end)
  if (anyNA(c(configured_start, configured_end, observed_end, requested_start, requested_end))) stop("Invalid production date window", call.=FALSE)
  if (requested_start > requested_end) stop("Effective date window start must not be after end", call.=FALSE)
  if (requested_start < configured_start || requested_end > configured_end) stop("Date override must remain within configured production window ", format(configured_start), " through ", format(configured_end), call.=FALSE)
  if (!isTRUE(dry_run) && identical(unname(as.character(config$project$profile)), "production") && requested_start <= observed_end) effective_end <- min(requested_end, observed_end) else effective_end <- requested_end
  effective_start <- requested_start
  future_start <- if (requested_end > observed_end) max(requested_start, observed_end + 1L) else as.Date(NA)
  list(configured_start=configured_start, configured_end=configured_end, requested_start=requested_start, requested_end=requested_end, effective_start=effective_start, effective_end=effective_end, observed_start=configured_start, observed_end=observed_end, future_start=future_start, future_end=if (requested_end > observed_end) requested_end else as.Date(NA), date_override_source=if (!is.null(start_date) || !is.null(end_date)) "explicit_override" else "configured")
}

validate_plan <- function(plan, requests, window, config, spatial_diagnostics=NULL) {
  dates <- sort(unique(as.Date(plan$date)))
  expected <- if (length(requests)) safe_date_sequence(window$effective_start, window$effective_end) else dates
  if (length(dates) != length(plan$date) || anyDuplicated(dates)) stop("Plan validation failed: planned dates are not unique", call.=FALSE)
  if (length(dates) && (!all(dates >= window$effective_start) || !all(dates <= window$effective_end))) stop("Plan validation failed: planned dates are outside the requested window", call.=FALSE)
  if (!identical(as.character(dates), as.character(expected))) stop("Plan validation failed: planned dates do not cover the effective window", call.=FALSE)
  targets <- if (length(requests)) vapply(requests, function(x) as.character(x$target), character(1)) else character()
  hashes <- if (length(requests)) vapply(requests, function(x) as.character(x$request_hash), character(1)) else character()
  if (anyDuplicated(targets) || anyDuplicated(hashes)) stop("Plan validation failed: request targets and hashes must be unique", call.=FALSE)
  covered <- if (length(requests)) sort(unique(as.Date(unlist(lapply(requests, function(x) x$raw_request_dates))))) else as.Date(character())
  if (!identical(as.character(covered), as.character(expected))) stop("Plan validation failed: request rows do not cover all planned dates", call.=FALSE)
  if (length(requests)) for (request in requests) if (length(unique(format(as.Date(request$raw_request_dates), "%Y-%m"))) != 1L) stop("Plan validation failed: request row crosses a month", call.=FALSE)
  list(status="success", planned_dates=length(dates), request_rows=length(requests), uncovered_dates=length(setdiff(expected, covered)), duplicate_dates=length(plan$date)-length(dates), duplicate_request_targets=sum(duplicated(targets)), duplicate_request_hashes=sum(duplicated(hashes)), template_sha256=spatial_diagnostics$template_file_sha256 %||% NA_character_)
}

ensure_pipeline_directories <- function(config, output_root = NULL) { validate_pipeline_config(config); resolve_storage_paths(config, config$project_root %||% resolve_project_root(), output_root, create = TRUE) }

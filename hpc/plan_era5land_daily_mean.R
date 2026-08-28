#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)

value <- function(flag, default = NULL, required = FALSE) {
  i <- match(flag, args)
  if (is.na(i)) {
    if (required) stop("Missing required argument: ", flag, call. = FALSE)
    return(default)
  }
  if (i == length(args) || startsWith(args[[i + 1L]], "--")) {
    stop("Missing value for ", flag, call. = FALSE)
  }
  args[[i + 1L]]
}

config <- value("--config", required = TRUE)
output_root <- value("--output-root", required = TRUE)
products <- value("--products", required = TRUE)
start_date <- value("--start-date")
end_date <- value("--end-date")

library(cdsdatagrab)

or_null <- function(x, fallback) if (is.null(x)) fallback else x

cfg <- read_pipeline_config(config)
project_root <- resolve_project_root(dirname(config))
cfg <- resolve_config_paths(cfg, project_root, output_root, FALSE)
cfg <- validate_pipeline_config(cfg)
ids <- strsplit(products, ",", fixed = TRUE)[[1L]]
ids <- trimws(ids)
if (!length(ids) || any(!nzchar(ids))) {
  stop("--products must contain at least one non-empty product id", call. = FALSE)
}

dates <- era5land_expected_dates(
  cfg,
  start_date = if (is.null(start_date) || !nzchar(start_date)) NULL else start_date,
  end_date = if (is.null(end_date) || !nzchar(end_date)) NULL else end_date,
  dry_run = FALSE
)
diagnostics <- diagnose_spatial_domain(
  cfg$spatial$template_path,
  cfg$spatial$bbox_path,
  cfg
)
requests <- build_era5land_daily_mean_requests(
  dates,
  diagnostics$final_cds_area,
  cfg,
  ids
)

week_ids <- if (length(dates)) format(as.Date(dates), "%G-W%V") else character()
complete_weeks <- unique(week_ids[vapply(
  unique(week_ids),
  function(week) sum(week_ids == week) == 7L,
  logical(1)
)])

emit <- function(name, value) {
  cat(name, "=", value, "\n", sep = "")
}

emit("CONFIG", normalizePath(config, mustWork = FALSE))
profile <- if (!is.null(cfg$project) && !is.null(cfg$project$profile)) cfg$project$profile else cfg$profile
emit("PROFILE", or_null(profile, "unknown"))
emit("OUTPUT_ROOT", normalizePath(output_root, mustWork = FALSE))
emit("START_DATE", if (length(dates)) as.character(min(dates)) else "")
emit("END_DATE", if (length(dates)) as.character(max(dates)) else "")
emit("PRODUCT_COUNT", length(ids))
emit("PRODUCTS", paste(ids, collapse = ","))
emit("DAILY_EXPECTED", length(dates) * length(ids))
emit("COMPLETE_WEEKS", length(complete_weeks))
emit("WEEKLY_EXPECTED", length(complete_weeks) * length(ids))
emit("SOURCE_REQUEST_COUNT", length(requests))
emit("REQUEST_HASHES", paste(vapply(requests, function(x) or_null(x$request_hash, ""), character(1)), collapse = ","))
if (length(requests)) {
  for (i in seq_along(requests)) {
    request <- requests[[i]]
    emit(
      paste0("REQUEST_", i),
      paste0(
        "hash=", request$request_hash,
        ";start=", request$request_start,
        ";end=", request$request_end,
        ";days=", paste(request$raw_request_dates, collapse = ",")
      )
    )
  }
}

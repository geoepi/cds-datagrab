#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
value <- function(flag, default = NULL, required = FALSE) {
  i <- match(flag, args)
  if (is.na(i)) { if (required) stop("Missing required argument: ", flag, call. = FALSE); return(default) }
  if (i == length(args) || startsWith(args[[i + 1L]], "--")) stop(flag, " requires a value", call. = FALSE)
  args[[i + 1L]]
}

manifest_path <- value("--manifest", required = TRUE)
library(cdsdatagrab)
manifest <- jsonlite::read_json(manifest_path, simplifyVector = FALSE)
plan <- manifest$plan
repo_root <- getwd()
if (length(plan$source_workflows) && !is.null(plan$source_workflows[[1L]]$config)) {
  repo_root <- normalizePath(file.path(dirname(plan$source_workflows[[1L]]$config), ".."), winslash = "/", mustWork = FALSE)
}
result <- tryCatch(
  portfolio_validate_output_root(plan, manifest$output_root, repo_root = repo_root),
  error = function(e) list(status = "failed", failure_message = conditionMessage(e), products = list())
)
manifest$validation <- result
manifest$common_daily_start <- if (is.null(result$common_daily_start)) manifest$common_daily_start else result$common_daily_start
manifest$common_daily_end <- if (is.null(result$common_daily_end)) manifest$common_daily_end else result$common_daily_end
manifest$complete_iso_week_count <- if (is.null(result$complete_iso_week_count)) manifest$complete_iso_week_count else result$complete_iso_week_count
manifest$products <- if (is.null(result$products)) manifest$products else result$products
manifest$status <- if (identical(result$status, "success")) "success" else "failed"
if (identical(manifest$status, "failed")) {
  manifest$failure_stage <- "validation"
  manifest$failure_message <- if (is.null(result$failure_message)) "Portfolio synchronization validation failed" else result$failure_message
}
manifest$completed_at <- format(Sys.time(), tz = "UTC", usetz = TRUE)
portfolio_write_manifest(manifest, manifest_path)
cat(sprintf("Portfolio validation: %s\nCommon daily window: %s through %s\nComplete ISO weeks: %s\n",
  manifest$status, manifest$common_daily_start, manifest$common_daily_end, manifest$complete_iso_week_count))
if (!identical(manifest$status, "success")) quit(save = "no", status = 1L, runLast = FALSE)

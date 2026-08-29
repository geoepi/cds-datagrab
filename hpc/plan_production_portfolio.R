#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
value <- function(flag, default = NULL, required = FALSE) {
  i <- match(flag, args)
  if (is.na(i)) { if (required) stop("Missing required argument: ", flag, call. = FALSE); return(default) }
  if (i == length(args) || startsWith(args[[i + 1L]], "--")) stop(flag, " requires a value", call. = FALSE)
  args[[i + 1L]]
}

config_path <- value("--config", "config/production_portfolio.yml")
output_root <- value("--output-root", required = TRUE)
plan_json <- value("--plan-json")
through <- value("--through", "latest-common")
explicit <- through != "latest-common"
if (!explicit && !identical(through, "latest-common")) stop("--through must be latest-common or YYYY-MM-DD", call. = FALSE)
if (explicit && !grepl("^\\d{4}-\\d{2}-\\d{2}$", through)) stop("--through must be latest-common or YYYY-MM-DD", call. = FALSE)

library(cdsdatagrab)
repo_root <- normalizePath(file.path(dirname(config_path), ".."), winslash = "/", mustWork = FALSE)
definition <- portfolio_read_definition(config_path)
attr(definition, "config_path") <- normalizePath(config_path, winslash = "/", mustWork = FALSE)
plan <- portfolio_resolve_plan(definition, through = if (explicit) "explicit" else "latest-common",
  explicit_end = if (explicit) through else NULL, output_root = output_root, repo_root = repo_root)
if (!is.null(plan_json)) jsonlite::write_json(plan, plan_json, pretty = TRUE, auto_unbox = TRUE, null = "null")

cat("PLAN_STATUS=planned\n")
cat("PORTFOLIO=production\n")
cat("PRODUCT_COUNT=", length(plan$product_ids), "\n", sep = "")
cat("SOURCE_WORKFLOW_COUNT=", length(plan$source_workflow_ids), "\n", sep = "")
cat("REQUESTED_THROUGH=", plan$requested_through, "\n", sep = "")
cat("COMMON_START=", plan$common_start, "\n", sep = "")
cat("COMMON_END=", plan$common_end, "\n", sep = "")
cat("COMPLETE_ISO_WEEK_COUNT=", length(plan$complete_iso_weeks), "\n", sep = "")
cat("COMPLETE_ISO_WEEKS=", paste(plan$complete_iso_weeks, collapse = ","), "\n", sep = "")
for (i in seq_len(nrow(plan$availability))) {
  row <- plan$availability[i, ]
  cat("AVAILABILITY|", row$source_workflow, "|", if (is.na(row$available_through)) "uncertain" else row$available_through,
    "|", row$availability_source, "\n", sep = "")
}
for (source in plan$source_workflows) {
  source_config <- if (grepl("^([A-Za-z]:[\\\\/]|/)", source$config)) source$config else file.path(repo_root, source$config)
  source_wrapper <- if (grepl("^([A-Za-z]:[\\\\/]|/)", source$wrapper)) source$wrapper else file.path(repo_root, source$wrapper)
  cat("SOURCE|", source$id, "|", normalizePath(source_config, winslash = "/", mustWork = FALSE), "|", normalizePath(source_wrapper, winslash = "/", mustWork = FALSE),
    "|", paste(source$products, collapse = ","), "\n", sep = "")
}
for (product in plan$products) {
  cat("PRODUCT|", product$product_id, "|", product$source_workflow, "|", product$daily_expected, "|", product$daily_present,
    "|", product$weekly_expected, "|", product$weekly_present, "\n", sep = "")
}

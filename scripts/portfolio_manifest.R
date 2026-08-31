#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
value <- function(flag, default = NULL, required = FALSE) {
  i <- match(flag, args)
  if (is.na(i)) { if (required) stop("Missing required argument: ", flag, call. = FALSE); return(default) }
  if (i == length(args) || startsWith(args[[i + 1L]], "--")) stop(flag, " requires a value", call. = FALSE)
  args[[i + 1L]]
}
parse_jobs <- function(x) {
  if (is.null(x) || !nzchar(x)) return(list())
  parts <- strsplit(x, ",", fixed = TRUE)[[1L]]
  out <- lapply(parts, function(part) {
    z <- strsplit(part, "=", fixed = TRUE)[[1L]]
    if (length(z) != 2L || !nzchar(z[[1L]]) || !nzchar(z[[2L]])) stop("Job mapping must be name=id", call. = FALSE)
    z[[2L]]
  })
  names(out) <- vapply(parts, function(part) strsplit(part, "=", fixed = TRUE)[[1L]][[1L]], character(1))
  out
}

operation <- value("--operation", required = TRUE)
manifest_path <- value("--manifest", required = TRUE)
library(cdsdatagrab)

if (operation == "create") {
  plan_path <- value("--plan-json", required = TRUE)
  output_root <- value("--output-root", required = TRUE)
  plan <- jsonlite::read_json(plan_path, simplifyVector = FALSE)
  manifest <- portfolio_new_manifest(plan, output_root, run_id = value("--run-id"),
    source_commit = value("--source-commit", "unavailable"), installed_commit = value("--installed-commit", "unavailable"))
  portfolio_write_manifest(manifest, manifest_path)
  cat(manifest_path, "\n")
  quit(save = "no", status = 0L, runLast = FALSE)
}

if (operation != "update") stop("--operation must be create or update", call. = FALSE)
manifest <- jsonlite::read_json(manifest_path, simplifyVector = FALSE)
status <- value("--status")
source_jobs <- parse_jobs(value("--source-jobs"))
aggregation_jobs <- parse_jobs(value("--aggregation-jobs"))
validation_job <- value("--validation-job")
if (length(source_jobs)) manifest$source_job_ids <- source_jobs
if (length(aggregation_jobs)) manifest$aggregation_job_ids <- aggregation_jobs
if (!is.null(validation_job)) manifest$validation_job_id <- validation_job
if (length(source_jobs)) {
  manifest$source_job_outcomes <- setNames(lapply(names(source_jobs), function(name) {
    list(job_id = unname(source_jobs[[name]]), status = "submitted")
  }), names(source_jobs))
  manifest$dependencies$aggregation <- paste0("afterok:", paste(unlist(source_jobs, use.names = FALSE), collapse = ":"))
  manifest$status <- if (is.null(status)) "source_running" else status
}
if (length(aggregation_jobs)) {
  manifest$dependencies$validation <- paste0("afterok:", paste(unlist(aggregation_jobs, use.names = FALSE), collapse = ":"))
  manifest$status <- if (is.null(status)) "aggregation_running" else status
}
if (!is.null(validation_job)) { manifest$dependencies$validation_job <- "afterok:aggregation_jobs"; manifest$status <- if (is.null(status)) "validation_submitted" else status }
if (!is.null(status)) manifest$status <- status
failure_stage <- value("--failure-stage")
failure_message <- value("--failure-message")
if (!is.null(failure_stage)) manifest$failure_stage <- failure_stage
if (!is.null(failure_message)) manifest$failure_message <- failure_message
if (manifest$status %in% c("success", "failed")) manifest$completed_at <- format(Sys.time(), tz = "UTC", usetz = TRUE)
portfolio_write_manifest(manifest, manifest_path)

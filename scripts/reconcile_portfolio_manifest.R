#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
value <- function(flag, default = NULL, required = FALSE) {
  i <- match(flag, args)
  if (is.na(i)) {
    if (required) stop("Missing required argument: ", flag, call. = FALSE)
    return(default)
  }
  if (i == length(args) || startsWith(args[[i + 1L]], "--")) stop(flag, " requires a value", call. = FALSE)
  args[[i + 1L]]
}
if ("--help" %in% args) {
  cat("Usage: Rscript scripts/reconcile_portfolio_manifest.R --manifest PATH [--apply]\n")
  cat("Queries recorded Slurm job states. Without --apply it is read-only; --apply records only lifecycle reconciliation.\n")
  quit(save = "no", status = 0L, runLast = FALSE)
}

manifest_path <- value("--manifest", required = TRUE)
if (!file.exists(manifest_path)) stop("Manifest does not exist: ", manifest_path, call. = FALSE)
library(cdsdatagrab)
manifest <- jsonlite::read_json(manifest_path, simplifyVector = FALSE)
job_ids <- portfolio_manifest_job_ids(manifest)
if (!length(job_ids)) stop("Manifest contains no recorded Slurm job IDs", call. = FALSE)

query_state <- function(job_id) {
  output <- tryCatch(
    system2("sacct", c("-X", "-n", "-P", "-o", "JobIDRaw,State", "-j", job_id), stdout = TRUE, stderr = TRUE),
    error = function(e) structure(character(), status = 1L, error = conditionMessage(e)))
  if (!is.null(attr(output, "status")) && attr(output, "status") != 0L) {
    stop("sacct failed for job ", job_id, ": ", paste(output, collapse = " "), call. = FALSE)
  }
  rows <- strsplit(output[nzchar(output)], "|", fixed = TRUE)
  matches <- rows[vapply(rows, function(row) length(row) >= 2L && identical(row[[1L]], job_id), logical(1))]
  if (!length(matches)) return(NA_character_)
  trimws(matches[[length(matches)]][[2L]])
}

job_states <- vapply(job_ids, query_state, character(1))
names(job_states) <- job_ids
result <- portfolio_reconcile_manifest(manifest, job_states)
cat("Manifest:", manifest_path, "\n", sep = " ")
cat("Recorded status:", manifest$status, "\n")
for (job_id in job_ids) cat("JOB|", job_id, "|", if (is.na(job_states[[job_id]])) "unknown" else job_states[[job_id]], "|", portfolio_classify_job_state(job_states[[job_id]]), "\n", sep = "")
cat("Reconciled status:", result$manifest$status, "\n")
cat("Reason:", result$reason, "\n")
if ("--apply" %in% args) {
  portfolio_write_manifest(result$manifest, manifest_path)
  cat("Manifest updated: true\n")
} else {
  cat("Manifest updated: false (use --apply to record reconciliation)\n")
}

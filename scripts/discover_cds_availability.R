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
flag <- function(name) name %in% args
or_null <- function(x, fallback) if (is.null(x)) fallback else x
if (flag("--help")) {
  cat("Usage: Rscript scripts/discover_cds_availability.R [--probe] [--max-backtrack-days 0..7] [--output-dir PATH] [--reuse-json PATH] [--inventory-json PATH]", intToUtf8(10),
    "Without --probe, the command reads public catalogue metadata only. Retrieval probes use bounded requests in a temporary scratch root.", intToUtf8(10), sep = "")
  quit(save = "no", status = 0L, runLast = FALSE)
}
script_arg <- grep("^--file=", commandArgs(), value = TRUE)
script_path <- normalizePath(sub("^--file=", "", script_arg[[1L]]), winslash = "/", mustWork = TRUE)
repo_root <- normalizePath(file.path(dirname(script_path), ".."), winslash = "/", mustWork = TRUE)
library(cdsdatagrab)
max_backtrack <- suppressWarnings(as.integer(value("--max-backtrack-days", "3")))
if (is.na(max_backtrack) || max_backtrack < 0L || max_backtrack > 7L) stop("--max-backtrack-days must be from 0 through 7", call. = FALSE)
output_dir <- value("--output-dir", file.path(repo_root, "docs"))
if (!(grepl("^[A-Za-z]:", output_dir) || startsWith(output_dir, "/") || startsWith(output_dir, intToUtf8(92)))) output_dir <- file.path(repo_root, output_dir)
cache <- NULL
reuse_json <- value("--reuse-json")
if (!is.null(reuse_json)) {
  if (!file.exists(reuse_json)) stop("--reuse-json file does not exist", call. = FALSE)
  cache <- jsonlite::read_json(reuse_json, simplifyVector = FALSE)
}
inventory <- list()
inventory_json <- value("--inventory-json")
if (!is.null(inventory_json)) {
  if (!file.exists(inventory_json)) stop("--inventory-json file does not exist", call. = FALSE)
  inventory <- jsonlite::read_json(inventory_json, simplifyVector = FALSE)
}
audit <- discover_cds_availability(repo_root = repo_root, probe = flag("--probe"),
  max_backtrack_days = max_backtrack, cache = cache)
write_cds_availability_outputs(audit, output_dir, production_inventory = inventory)
cat("CDS availability audit:", audit$audit_timestamp_utc, "UTC", intToUtf8(10))
cat("Portfolio:", audit$portfolio$common_endpoint_status, "verified common endpoint:",
  or_null(audit$portfolio$verified_common_endpoint, "not established"), intToUtf8(10))
for (source in audit$sources) cat(source$source_workflow, source$verification_status,
  "advertised", or_null(source$latest_advertised, "unknown"),
  "verified", or_null(source$latest_verified, "unknown"), intToUtf8(10))
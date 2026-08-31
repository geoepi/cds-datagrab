#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
value <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i)) return(default)
  if (i == length(args) || startsWith(args[[i + 1L]], "--")) stop(flag, " requires a value", call. = FALSE)
  args[[i + 1L]]
}
if ("--help" %in% args) {
  cat("Usage: Rscript scripts/backfill_daily_sidecars.R --config PATH --output-root PATH [--product-id ID] [--start-date YYYY-MM-DD] [--end-date YYYY-MM-DD] [--apply]\n")
  quit(save = "no", status = 0L, runLast = FALSE)
}
config_path <- value("--config", "config/era5_mintemp_production.yml")
output_root <- value("--output-root")
if (is.null(output_root) || !nzchar(output_root)) stop("--output-root is required", call. = FALSE)
project_root <- normalizePath(getwd(), winslash = "/", mustWork = TRUE)
while (!file.exists(file.path(project_root, "DESCRIPTION")) && dirname(project_root) != project_root) project_root <- dirname(project_root)
invisible(lapply(list.files(file.path(project_root, "R"), pattern = "[.]R$", full.names = TRUE), source, local = FALSE))
config_path <- if (grepl("^(?:[A-Za-z]:|/|\\\\)", config_path)) config_path else file.path(project_root, config_path)
result <- backfill_daily_sidecars(config_path, output_root, product_id = value("--product-id"),
  start_date = value("--start-date"), end_date = value("--end-date"), apply = "--apply" %in% args)
cat(sprintf("apply=%s product=%s written=%d planned=%d reused=%d failed=%d\n",
  "--apply" %in% args, result$product_id, result$written, result$planned, result$reused, result$failed))
if (result$failed > 0L) quit(save = "no", status = 1L, runLast = FALSE)

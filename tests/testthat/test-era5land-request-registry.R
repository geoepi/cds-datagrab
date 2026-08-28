local_registry_paths <- function(label) {
  root <- tempfile(paste0("era5land-registry-", label, "-"), tmpdir = package_root())
  source_root <- file.path(root, "data", "smoke", "_sources", "era5land_daily_mean_utc06")
  paths <- list(root = root, source_root = source_root, requests_dir = file.path(source_root, "requests"), request_registry = file.path(source_root, "requests", "request_registry.csv"), raw_dir = file.path(source_root, "raw"), raw_quarantine_dir = file.path(source_root, "quarantine", "raw"), extracted_dir = file.path(source_root, "extracted"), root_marker = file.path(root, ".cds-datagrab-root"))
  dir.create(paths$raw_dir, recursive = TRUE); dir.create(paths$requests_dir, recursive = TRUE); writeLines("marker", paths$root_marker)
  withr::defer(unlink(root, recursive = TRUE, force = TRUE), envir = testthat::teardown_env())
  paths
}

registry_request_fixture <- function() {
  cfg <- read_pipeline_config(package_file("config", "era5land_daily_mean_utc06_smoke.yml"))
  build_era5land_daily_mean_requests(as.Date("2026-02-01") + 0:2, c(43, -127, 42, -125), cfg)[[1L]]
}

make_registry_zip <- function(path, members = paste0("member", seq_len(8), ".nc")) {
  source_dir <- tempfile("registry-zip-members-", tmpdir = package_root()); dir.create(source_dir)
  withr::defer(unlink(source_dir, recursive = TRUE, force = TRUE), envir = testthat::teardown_env())
  files <- file.path(source_dir, members); invisible(lapply(files, function(file) writeLines("fixture", file)))
  old <- getwd(); on.exit(setwd(old), add = TRUE); setwd(source_dir); utils::zip(path, members, flags = "-q")
  path
}

test_that("valid local archive is retrieved state and never staged", {
  paths <- local_registry_paths("local"); request <- registry_request_fixture(); archive <- file.path(paths$raw_dir, sub("[.]nc$", ".zip", request$target)); make_registry_zip(archive)
  cfg <- read_pipeline_config(package_file("config", "era5land_daily_mean_utc06_smoke.yml")); registry <- era5land_registry_reconcile(list(request), era5land_empty_registry(), paths, cfg, persist = TRUE)
  calls <- 0L
  staged <- era5land_stage_requests(list(request), registry, paths, cfg, stage_fun = function(...) { calls <<- calls + 1L; list(job_url = "https://cds/jobs/duplicate") })
  expect_equal(calls, 0L)
  expect_identical(staged$registry$request_status[[1L]], "retrieved")
  expect_equal(era5land_request_inventory(list(request), staged$registry, paths)$new_cds_requests_required, 0L)
})

test_that("staging persists a job immediately and restart does not duplicate it", {
  paths <- local_registry_paths("stage"); request <- registry_request_fixture(); cfg <- read_pipeline_config(package_file("config", "era5land_daily_mean_utc06_smoke.yml")); calls <- 0L
  stage <- function(...) { calls <<- calls + 1L; list(job_id = "job-123", job_url = "https://cds/jobs/job-123") }
  first <- era5land_stage_requests(list(request), era5land_empty_registry(), paths, cfg, stage_fun = stage)
  expect_equal(calls, 1L); expect_identical(first$registry$request_status[[1L]], "submitted"); expect_identical(first$registry$cds_job_id[[1L]], "job-123"); expect_true(file.exists(paths$request_registry))
  second <- era5land_stage_requests(list(request), era5land_read_request_registry(paths), paths, cfg, stage_fun = stage)
  expect_equal(calls, 1L); expect_identical(second$registry$cds_job_url[[1L]], "https://cds/jobs/job-123")
})

test_that("pending retrieval is represented as processing and completed retrieval finalizes atomically", {
  paths <- local_registry_paths("retrieve"); request <- registry_request_fixture(); cfg <- read_pipeline_config(package_file("config", "era5land_daily_mean_utc06_smoke.yml")); stage <- era5land_stage_requests(list(request), era5land_empty_registry(), paths, cfg, stage_fun = function(...) list(job_url = "https://cds/jobs/job-456"))
  pending <- era5land_retrieve_requests(list(request), stage$registry, paths, cfg, transfer_fun = function(...) stop("request is still processing"))
  expect_equal(pending$processing, 1L); expect_identical(pending$registry$request_status[[1L]], "processing")
  completed <- era5land_retrieve_requests(list(request), pending$registry, paths, cfg, transfer_fun = function(url, target) { make_registry_zip(target); target })
  expect_equal(completed$retrieved, 1L); expect_identical(completed$registry$request_status[[1L]], "retrieved"); expect_true(file.exists(completed$registry$local_raw_path[[1L]])); expect_true(grepl("[.]zip$", completed$registry$local_raw_path[[1L]]))
})

test_that("structured queued status avoids transfer and unavailable-file errors remain nonterminal", {
  paths <- local_registry_paths("status"); request <- registry_request_fixture(); cfg <- read_pipeline_config(package_file("config", "era5land_daily_mean_utc06_smoke.yml")); stage <- era5land_stage_requests(list(request), era5land_empty_registry(), paths, cfg, stage_fun = function(...) list(job_id = "job-queued", job_url = "https://cds/jobs/job-queued"))
  transfer_calls <- 0L
  queued <- era5land_retrieve_requests(list(request), stage$registry, paths, cfg, status_fun = function(url) "queued", transfer_fun = function(...) { transfer_calls <<- transfer_calls + 1L; stop("transfer should not be called") })
  expect_equal(queued$processing, 1L); expect_equal(transfer_calls, 0L); expect_identical(queued$registry$request_status[[1L]], "processing"); expect_identical(queued$registry$cds_job_id[[1L]], "job-queued")
  unavailable <- era5land_retrieve_requests(list(request), queued$registry, paths, cfg, status_fun = function(url) "unknown", transfer_fun = function(...) stop("Your requested file is unavailable - check url"))
  expect_equal(unavailable$processing, 1L); expect_equal(unavailable$failed, 0L); expect_identical(unavailable$registry$request_status[[1L]], "processing"); expect_identical(unavailable$registry$cds_job_url[[1L]], "https://cds/jobs/job-queued")
})

test_that("multiple queued jobs remain pending and the pass is nonterminal", {
  paths <- local_registry_paths("multiple-pending"); cfg <- read_pipeline_config(package_file("config", "era5land_daily_mean_utc06_smoke.yml")); dates <- seq(as.Date("2026-02-01"), as.Date("2026-04-02"), by = "day"); requests <- build_era5land_daily_mean_requests(dates, c(43, -127, 42, -125), cfg)
  stage <- era5land_stage_requests(requests, era5land_empty_registry(), paths, cfg, stage_fun = function(request, payload) list(job_url = paste0("https://cds/jobs/", request$request_hash)))
  transfer_calls <- 0L; pending <- era5land_retrieve_requests(requests, stage$registry, paths, cfg, status_fun = function(url) "running", transfer_fun = function(...) { transfer_calls <<- transfer_calls + 1L; stop("transfer should not be called") })
  expect_equal(length(requests), 3L); expect_equal(pending$processing, 3L); expect_equal(pending$failed, 0L); expect_equal(transfer_calls, 0L); expect_true(all(pending$registry$request_status == "processing"))
})

test_that("legacy unavailable-file failures migrate idempotently before staging decisions", {
  paths <- local_registry_paths("migration"); request <- registry_request_fixture(); cfg <- read_pipeline_config(package_file("config", "era5land_daily_mean_utc06_smoke.yml")); staged <- era5land_stage_requests(list(request), era5land_empty_registry(), paths, cfg, stage_fun = function(...) list(job_id = "job-legacy", job_url = "https://cds/jobs/job-legacy"))
  legacy <- staged$registry; legacy$request_status <- "failed"; legacy$error_class <- "simpleError;error;condition"; legacy$error_message <- "Your requested file is unavailable - check url"; era5land_write_request_registry(legacy, paths)
  migrated <- era5land_migrate_legacy_unavailable_rows(legacy, list(request), paths, persist = TRUE)
  expect_identical(migrated$request_status[[1L]], "processing"); expect_identical(migrated$cds_job_id[[1L]], "job-legacy"); expect_identical(migrated$cds_job_url[[1L]], "https://cds/jobs/job-legacy"); expect_identical(migrated$submitted_at[[1L]], legacy$submitted_at[[1L]])
  again <- era5land_migrate_legacy_unavailable_rows(migrated, list(request), paths, persist = TRUE); expect_identical(again$request_status[[1L]], "processing"); expect_identical(again$error_message[[1L]], "Your requested file is unavailable - check url")
})

test_that("explicit remote terminal states remain distinct from pending", {
  paths <- local_registry_paths("terminal"); request <- registry_request_fixture(); cfg <- read_pipeline_config(package_file("config", "era5land_daily_mean_utc06_smoke.yml")); stage <- era5land_stage_requests(list(request), era5land_empty_registry(), paths, cfg, stage_fun = function(...) list(job_url = "https://cds/jobs/job-terminal"))
  failed <- era5land_retrieve_requests(list(request), stage$registry, paths, cfg, status_fun = function(url) list(status = "failed", message = "CDS job failed permanently"), transfer_fun = function(...) stop("transfer should not be called"))
  expect_equal(failed$failed, 1L); expect_identical(failed$registry$request_status[[1L]], "failed")
  stage$registry$request_status <- "processing"
  expired <- era5land_retrieve_requests(list(request), stage$registry, paths, cfg, status_fun = function(url) list(status = "expired", message = "job expired"), transfer_fun = function(...) stop("transfer should not be called"))
  expect_equal(expired$expired, 1L); expect_identical(expired$registry$request_status[[1L]], "expired")
})

test_that("mixed retrieval reports retrieved, processing, and failed independently", {
  paths <- local_registry_paths("mixed"); cfg <- read_pipeline_config(package_file("config", "era5land_daily_mean_utc06_smoke.yml")); requests <- build_era5land_daily_mean_requests(seq(as.Date("2026-02-01"), as.Date("2026-04-02"), by = "day"), c(43, -127, 42, -125), cfg); stage <- era5land_stage_requests(requests, era5land_empty_registry(), paths, cfg, stage_fun = function(request, payload) list(job_url = paste0("https://cds/jobs/", request$request_hash)))
  states <- c(successful = "successful", processing = "running", failed = "failed"); status_fun <- function(url) states[[if (grepl(requests[[1L]]$request_hash, url, fixed = TRUE)) "successful" else if (grepl(requests[[2L]]$request_hash, url, fixed = TRUE)) "processing" else "failed"]]
  mixed <- era5land_retrieve_requests(requests, stage$registry, paths, cfg, status_fun = status_fun, transfer_fun = function(url, target) { make_registry_zip(target); target })
  expect_equal(mixed$retrieved, 1L); expect_equal(mixed$processing, 1L); expect_equal(mixed$failed, 1L); expect_identical(mixed$registry$request_status[[1L]], "retrieved"); expect_identical(mixed$registry$request_status[[2L]], "processing"); expect_identical(mixed$registry$request_status[[3L]], "failed")
})

test_that("expired jobs retain provenance and partial archives remain retryable", {
  paths <- local_registry_paths("failure"); request <- registry_request_fixture(); cfg <- read_pipeline_config(package_file("config", "era5land_daily_mean_utc06_smoke.yml")); stage <- era5land_stage_requests(list(request), era5land_empty_registry(), paths, cfg, stage_fun = function(...) list(job_id = "job-expired", job_url = "https://cds/jobs/job-expired"))
  expired <- era5land_retrieve_requests(list(request), stage$registry, paths, cfg, transfer_fun = function(...) stop("404 request expired"))
  expect_identical(expired$registry$request_status[[1L]], "expired"); expect_identical(expired$registry$cds_job_id[[1L]], "job-expired")
  stage2 <- stage$registry; stage2$request_status <- "submitted"
  partial <- era5land_retrieve_requests(list(request), stage2, paths, cfg, transfer_fun = function(url, target) { make_registry_zip(target, "only.nc"); target })
  expect_equal(partial$processing, 1L); expect_false(identical(partial$registry$request_status[[1L]], "retrieved")); expect_true(is.na(partial$registry$local_raw_path[[1L]]) || !nzchar(partial$registry$local_raw_path[[1L]]))
})

test_that("current production-shaped inventory recognizes thirteen cached months", {
  paths <- local_registry_paths("production"); cfg <- read_pipeline_config(package_file("config", "era5land_daily_mean_utc06_production.yml")); dates <- era5land_expected_dates(cfg, dry_run = FALSE); requests <- build_era5land_daily_mean_requests(dates, c(43, -127, 42, -125), cfg)
  expect_equal(length(requests), 55L)
  for (request in requests[seq_len(13L)]) make_registry_zip(file.path(paths$raw_dir, sub("[.]nc$", ".zip", request$target)))
  registry <- era5land_registry_reconcile(requests, era5land_empty_registry(), paths, cfg, persist = FALSE); inventory <- era5land_request_inventory(requests, registry, paths)
  expect_equal(inventory$source_requests_planned, 55L); expect_equal(inventory$raw_archives_valid, 13L); expect_equal(inventory$new_cds_requests_required, 42L); expect_equal(inventory$registered_pending_cds_jobs, 0L)
})

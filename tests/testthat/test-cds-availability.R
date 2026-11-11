availability_fake_sources <- function(dates = rep("2026-11-03", 5L),
                                      dataset_ids = c("daily", "daily", "hourly", "agera5", "land")) {
  workflow_ids <- c("era5_mintemp", "era5_soilmoist", "era5_lai_low", "agera5_relhum_min", "era5land_daily_mean_utc06")
  product_sets <- list("era5_mintemp", "era5_soilmoist", "era5_lai_low", "agera5_relhum_min",
    paste0("era5land_", 1:8))
  lapply(seq_along(workflow_ids), function(i) {
    variable <- paste0("variable_", i)
    list(source_workflow = workflow_ids[[i]], products = product_sets[[i]],
      dataset_id = dataset_ids[[i]], dataset_version = if (i == 4L) "2_0" else NA_character_,
      requested_variables = if (i == 5L) paste0("land_", 1:8) else variable,
      request_definition = list(variable = if (i == 5L) paste0("land_", 1:8) else variable,
        daily_statistic = "daily_mean", product_type = "reanalysis"),
      request_fingerprint = paste0("fingerprint_", i), latest_advertised_fixture = dates[[i]])
  })
}
availability_fake_fetcher <- function(sources) {
  calls <- new.env(parent = emptyenv())
  calls$count <- 0L
  fetch <- function(url) {
    calls$count <- calls$count + 1L
    constraint <- endsWith(url, "/constraints")
    dataset <- sub("^.*/collections/", "", sub("/constraints$", "", url))
    matches <- which(vapply(sources, function(x) identical(x$dataset_id, dataset), logical(1)))
    date <- sources[[matches[[1L]]]]$latest_advertised_fixture
    if (constraint) {
      fields <- list(variable = unique(unlist(lapply(sources[matches], function(x) x$request_definition$variable))),
        daily_statistic = "daily_mean", product_type = "reanalysis",
        year = format(as.Date(date), "%Y"), month = format(as.Date(date), "%m"), day = format(as.Date(date), "%d"))
      return(list(properties = lapply(fields, function(value) list(enum = as.list(value)))))
    }
    list(title = dataset, published = "2024-01-01T00:00:00Z", updated = "2026-11-10T00:00:00Z",
      extent = list(temporal = list(interval = list(c("2022-01-01T00:00:00Z", paste0(date, "T00:00:00Z"))))),
      links = list(list(rel = "constraints", href = paste0(url, "/constraints"))))
  }
  list(fetch = fetch, calls = calls)
}
availability_verified_probe <- function(source, date, finality = "UNSPECIFIED") {
  list(status = "VERIFIED", accepted_request = TRUE, observed_dates = as.character(date),
    received_variables = source$requested_variables, dataset_version = source$dataset_version,
    finality = finality)
}
availability_discover <- function(sources, probe_fn, probe = TRUE, credential_present = TRUE,
                                   max_backtrack_days = 3L, cache = NULL, sleep_fn = function(x) NULL) {
  fake <- availability_fake_fetcher(sources)
  audit <- discover_cds_availability(sources = sources, fetch_json = fake$fetch, probe = probe,
    credential_present = credential_present, probe_fn = probe_fn, max_backtrack_days = max_backtrack_days,
    cache = cache, sleep_fn = sleep_fn, audit_time = as.POSIXct("2026-11-11 15:31:58", tz = "UTC"))
  list(audit = audit, fetch_calls = fake$calls$count)
}

test_that("configured source definitions preserve five workflows and twelve products", {
  repo_root <- dirname(dirname(package_file("config", "production_portfolio.yml"))); sources <- cds_availability_source_definitions(repo_root)
  expect_length(sources, 5L)
  expect_equal(sum(vapply(sources, function(x) length(x$products), integer(1))), 12L)
  expect_equal(sources[[4]]$dataset_version, "2_0")
  expect_true("2m_relative_humidity_derived" %in% sources[[4]]$requested_variables)
  expect_length(sources[[5]]$requested_variables, 8L)
  expect_equal(sources[[5]]$time_zone, "utc-06:00")
  expect_match(sources[[3]]$temporal_character, "monthly climatology")
})

test_that("different source dates produce a conservative common endpoint and deduplicate metadata", {
  sources <- availability_fake_sources(c("2026-11-03", "2026-11-03", "2026-11-05", "2026-11-04", "2026-11-05"))
  result <- availability_discover(sources, availability_verified_probe)
  expect_equal(result$fetch_calls, 8L)
  expect_equal(result$audit$portfolio$verified_common_endpoint, "2026-11-03")
  expect_equal(vapply(result$audit$sources, function(x) x$latest_verified, character(1)),
    c("2026-11-03", "2026-11-03", "2026-11-05", "2026-11-04", "2026-11-05"))
})

test_that("an advertised date without data is backtracked and accepted dates remain distinct", {
  sources <- availability_fake_sources()
  probe <- function(source, date) {
    if (as.character(date) == "2026-11-03") return(list(status = "UNAVAILABLE", accepted_request = TRUE, reason = "no complete observation"))
    availability_verified_probe(source, date)
  }
  audit <- availability_discover(sources, probe)$audit
  expect_equal(audit$sources[[1]]$latest_accepted_request, "2026-11-03")
  expect_equal(audit$sources[[1]]$latest_verified, "2026-11-02")
  expect_equal(audit$sources[[1]]$verification_status, "VERIFIED")
})

test_that("incomplete variable coverage cannot be verified", {
  sources <- availability_fake_sources()
  probe <- function(source, date) {
    result <- availability_verified_probe(source, date)
    result$received_variables <- head(source$requested_variables, -1L)
    result
  }
  audit <- availability_discover(sources, probe, max_backtrack_days = 0L)$audit
  expect_equal(audit$sources[[5]]$verification_status, "UNAVAILABLE")
  expect_null(audit$sources[[5]]$latest_verified)
  expect_null(audit$portfolio$verified_common_endpoint)
})

test_that("credential loader falls back to YAML only when the environment token is absent", {
  secret_path <- tempfile(fileext = ".yaml")
  withr::defer(unlink(secret_path, force = TRUE), envir = testthat::teardown_env())
  withr::local_envvar(c(ecmwfr_PAT = NA_character_))

  writeLines("ecmwfr_PAT: dummy-test-token", secret_path)
  expect_true(.cds_availability_load_credentials(secret_path))
  expect_identical(Sys.getenv("ecmwfr_PAT"), "dummy-test-token")

  Sys.setenv(ecmwfr_PAT = "dummy-environment-token")
  writeLines("not_valid_yaml: [", secret_path)
  expect_true(.cds_availability_load_credentials(secret_path))
  expect_identical(Sys.getenv("ecmwfr_PAT"), "dummy-environment-token")
})

test_that("credential loader rejects missing or malformed fallback YAML", {
  secret_path <- tempfile(fileext = ".yaml")
  withr::defer(unlink(secret_path, force = TRUE), envir = testthat::teardown_env())
  withr::local_envvar(c(ecmwfr_PAT = NA_character_))

  expect_false(.cds_availability_load_credentials(secret_path))
  writeLines("other_key: value", secret_path)
  expect_false(.cds_availability_load_credentials(secret_path))
  expect_false(nzchar(Sys.getenv("ecmwfr_PAT", unset = "")))
})
test_that("bounded discovery transfer delegates to the production transfer and records its entry", {
  called <- NULL
  attempted <- FALSE
  local_mocked_bindings(perform_cds_transfer = function(dataset, payload, target) {
    called <<- list(dataset = dataset, payload = payload, target = target)
    "production-transfer-result"
  }, .package = "cdsdatagrab")

  result <- .cds_availability_production_transfer("dataset-id", list(variable = "configured_variable"),
    "/scratch/request.nc", on_submission_attempt = function() attempted <<- TRUE)

  expect_true(attempted)
  expect_identical(result, "production-transfer-result")
  expect_identical(called, list(dataset = "dataset-id", payload = list(variable = "configured_variable"),
    target = "/scratch/request.nc"))
})
test_that("standalone probes use product storage while ERA5-Land keeps family storage", {
  sources <- availability_fake_sources()
  calls <- character()
  local_mocked_bindings(
    resolve_storage_paths = function(...) { calls <<- c(calls, "product"); list(kind = "product") },
    resolve_source_storage_paths = function(...) { calls <<- c(calls, "family"); list(kind = "family") },
    .package = "cdsdatagrab"
  )

  paths <- lapply(sources, .cds_availability_probe_storage_paths, config = list(),
    repo_root = "/repo", scratch_root = "/scratch")

  expect_identical(calls, c(rep("product", 4L), "family"))
  expect_identical(vapply(paths, `[[`, character(1), "kind"), c(rep("product", 4L), "family"))
})
test_that("bounded probe errors retain sanitized stage, class, and request status", {
  withr::local_envvar(c(ecmwfr_PAT = "dummy-cds-token"))
  source <- availability_fake_sources()[[1L]]
  result <- .cds_availability_probe_once(source, "2026-11-03", function(...) {
    stop(simpleError("HTTP 503 Authorization: Bearer dummy-cds-token; ecmwfr_PAT=dummy-cds-token"))
  }, max_attempts = 1L)

  expect_identical(result$status, "ERROR")
  expect_identical(result$error_stage, "probe_invocation")
  expect_match(result$error_class, "simpleError")
  expect_identical(result$http_status, 503L)
  expect_true(grepl("\\[REDACTED\\]", result$error_message))
  expect_false(grepl("dummy-cds-token", result$error_message, fixed = TRUE))
  expect_false(result$request_constructed)
  expect_false(result$submission_attempted)
  expect_false(result$accepted_request)
  expect_true(length(result$error_traceback) > 0L)
})
test_that("CDS authentication rejection is classified without exposing an endpoint identifier", {
  error <- simpleError(paste("permission denied Authentication failed401 operation not allowed",
    "https://cds.climate.copernicus.eu/api/retrieve/v1/processes/example/execute-123456"))
  result <- .cds_availability_error_details(error, "cds_submission", request_constructed = TRUE,
    submission_attempted = TRUE, traceback = c("perform_cds_transfer", "wf_request"))

  expect_identical(result$http_status, 401L)
  expect_false(result$accepted_request)
  expect_true(result$submission_attempted)
  expect_match(result$error_message, "HTTP 401", fixed = TRUE)
  expect_false(grepl("execute-123456", result$error_message, fixed = TRUE))
})
test_that("discovery uses the repo-root credential fallback for bounded probes", {
  repo_root <- tempfile("cds-availability-credentials-")
  dir.create(repo_root)
  withr::defer(unlink(repo_root, recursive = TRUE, force = TRUE), envir = testthat::teardown_env())
  withr::local_envvar(c(ecmwfr_PAT = NA_character_))
  writeLines("ecmwfr_PAT: dummy-discovery-token", file.path(repo_root, "secrets.yaml"))

  sources <- availability_fake_sources()
  fake <- availability_fake_fetcher(sources)
  # This temporary fixture is not a Git checkout; suppress its expected repository-SHA lookup warning.
  audit <- suppressWarnings(discover_cds_availability(repo_root = repo_root, sources = sources,
    fetch_json = fake$fetch, probe = TRUE, probe_fn = availability_verified_probe,
    max_backtrack_days = 0L, audit_time = as.POSIXct("2026-11-11 15:31:58", tz = "UTC")))

  expect_true(nzchar(Sys.getenv("ecmwfr_PAT", unset = "")))
  expect_true(all(vapply(audit$sources, function(x) x$verification_status == "VERIFIED", logical(1))))
  expect_equal(audit$portfolio$verified_common_endpoint, "2026-11-03")
})
test_that("missing credentials prevent retrieval probes", {
  sources <- availability_fake_sources()
  called <- FALSE
  audit <- availability_discover(sources, function(...) { called <<- TRUE }, credential_present = FALSE)$audit
  expect_false(called)
  expect_true(all(vapply(audit$sources, function(x) x$verification_status == "METADATA_ONLY", logical(1))))
})

test_that("429 retry honors Retry-After and transient failure stops after bounded attempts", {
  sources <- availability_fake_sources()
  calls <- 0L
  delays <- numeric()
  probe <- function(source, date) {
    calls <<- calls + 1L
    if (calls == 1L) return(list(status = "ERROR", http_status = 429L, retryable = TRUE, retry_after_seconds = 7))
    availability_verified_probe(source, date)
  }
  result <- availability_discover(sources, probe, sleep_fn = function(x) delays <<- c(delays, x))
  expect_equal(calls, 6L)
  expect_equal(delays, 7)
  calls <- 0L
  delays <- numeric()
  probe <- function(source, date) {
    calls <<- calls + 1L
    if (source$source_workflow == "era5_mintemp") return(list(status = "ERROR", http_status = 503L, retryable = TRUE))
    availability_verified_probe(source, date)
  }
  audit <- availability_discover(sources, probe, sleep_fn = function(x) delays <<- c(delays, x))$audit
  expect_equal(audit$sources[[1]]$verification_status, "ERROR")
  expect_equal(calls, 7L)
  expect_equal(delays, c(30, 60))
})

test_that("AgERA5 configured version incompatibility blocks a common endpoint", {
  sources <- availability_fake_sources()
  probe <- function(source, date) {
    result <- availability_verified_probe(source, date)
    if (source$source_workflow == "agera5_relhum_min") result$dataset_version <- "1_1"
    result
  }
  audit <- availability_discover(sources, probe)$audit
  expect_equal(audit$sources[[4]]$compatibility_status, "INCOMPATIBLE")
  expect_equal(audit$sources[[4]]$verification_status, "UNKNOWN")
  expect_null(audit$portfolio$verified_common_endpoint)
})

test_that("preliminary and final evidence labels remain explicit", {
  sources <- availability_fake_sources()
  probe <- function(source, date) availability_verified_probe(source, date,
    if (source$source_workflow == "era5_mintemp") "PRELIMINARY" else "FINAL")
  audit <- availability_discover(sources, probe)$audit
  expect_equal(audit$sources[[1]]$finality, "PRELIMINARY")
  expect_equal(audit$sources[[2]]$finality, "FINAL")
  expect_equal(audit$portfolio$common_endpoint_status, "VERIFIED")
})

test_that("Tuesday availability yields the prior Sunday complete week", {
  sources <- availability_fake_sources()
  audit <- availability_discover(sources, availability_verified_probe)$audit
  start <- as.Date("2022-01-01")
  daily_dates <- as.character(seq(start, as.Date("2026-10-01"), by = "day"))
  week_starts <- seq(as.Date("2022-01-03"), as.Date("2026-09-21"), by = "7 days")
  weekly_ids <- substr(ISOweek::ISOweek(week_starts), 1L, 8L)
  inventory <- list(coverage_start = as.character(start), latest_validated_daily = "2026-10-01",
    daily_dates = daily_dates, weekly_ids = weekly_ids, latest_validated_weekly = "2026-09-27")
  row <- cds_availability_plan_product(audit$sources[[1]], "era5_mintemp", inventory)
  expect_equal(row$complete_week_endpoint, "2026-11-01")
  expect_equal(row$catalog_conditional_additional_complete_weeks, 4L)
})

test_that("no new observations, inventory gaps, and hard horizon are reported", {
  sources <- availability_fake_sources(rep("2026-10-01", 5L))
  audit <- availability_discover(sources, availability_verified_probe)$audit
  start <- as.Date("2022-01-01")
  daily_dates <- as.character(seq(start, as.Date("2026-10-01"), by = "day"))
  week_starts <- seq(as.Date("2022-01-03"), as.Date("2026-09-21"), by = "7 days")
  weekly_ids <- substr(ISOweek::ISOweek(week_starts), 1L, 8L)
  inventory <- list(coverage_start = as.character(start), latest_validated_daily = "2026-10-01",
    daily_dates = daily_dates, weekly_ids = weekly_ids, latest_validated_weekly = "2026-09-27")
  no_new <- cds_availability_plan_product(audit$sources[[1]], "era5_mintemp", inventory)
  expect_equal(no_new$missing_days, 0L)
  expect_equal(no_new$recommended_action, "no new verified observations")
  inventory$daily_dates <- setdiff(inventory$daily_dates, "2024-01-15")
  gap <- cds_availability_plan_product(audit$sources[[1]], "era5_mintemp", inventory)
  expect_true("2024-01-15" %in% gap$missing_dates)
  beyond <- audit$sources[[1]]
  beyond$latest_advertised <- "2027-01-05"
  beyond$latest_verified <- "2027-01-05"
  capped <- cds_availability_plan_product(beyond, "era5_mintemp", inventory)
  expect_true(capped$upstream_beyond_hard_horizon)
  expect_equal(capped$complete_week_endpoint, "2026-12-27")
})

test_that("matching cached evidence avoids a repeated retrieval probe", {
  sources <- availability_fake_sources()
  first <- availability_discover(sources, availability_verified_probe)$audit
  called <- FALSE
  second <- availability_discover(sources, function(...) { called <<- TRUE },
    cache = list(probe_cache = first$probe_cache))$audit
  expect_false(called)
  expect_true(all(vapply(second$sources, function(x) x$verification_status == "VERIFIED", logical(1))))
})
test_that("audit writer emits JSON, Markdown, and a twelve-product CSV", {
  sources <- availability_fake_sources()
  audit <- availability_discover(sources, availability_verified_probe)$audit
  output_dir <- withr::local_tempdir()
  paths <- write_cds_availability_outputs(audit, output_dir)
  expect_true(file.exists(paths$json))
  expect_true(file.exists(paths$report))
  expect_true(file.exists(paths$update_plan))
  expect_equal(length(jsonlite::read_json(paths$json, simplifyVector = FALSE)$sources), 5L)
  expect_equal(nrow(utils::read.csv(paths$update_plan)), 12L)
})

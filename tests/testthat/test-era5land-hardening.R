test_that("ERA5-Land product date outcomes are canonical and deterministic", {
  make_result <- function(date, status) list(date = date, status = status, output_path = paste0(date, ".tif"))
  jan <- as.Date("2022-01-01") + 0:30
  expected <- cdsdatagrab:::canonical_iso_dates(jan, "expected")
  success <- list(date_results = lapply(expected, make_result, status = "success"), processing_failures = list())
  out <- cdsdatagrab:::era5land_product_date_outcomes(jan, success)
  expect_identical(out$expected_dates, expected)
  expect_identical(out$successful_dates, expected)
  expect_length(out$failed_dates, 0L)

  mixed <- list(date_results = list(make_result(expected[[1L]], "success"), make_result(expected[[2L]], "reused"), make_result(expected[[3L]], "failed")), processing_failures = list())
  mixed_out <- cdsdatagrab:::era5land_product_date_outcomes(expected[1:3], mixed)
  expect_identical(mixed_out$successful_dates, expected[1:2])
  expect_identical(mixed_out$failed_dates, expected[[3L]])
  expect_length(mixed_out$missing_date_results, 0L)

  missing <- list(date_results = list(make_result(expected[[1L]], "success")), processing_failures = list())
  expect_identical(cdsdatagrab:::era5land_product_date_outcomes(expected[1:2], missing)$missing_date_results, expected[[2L]])
  expect_error(cdsdatagrab:::era5land_product_date_outcomes(expected[1:2], list(date_results = c(missing$date_results, list(make_result(expected[[1L]], "reused"))))), "duplicate")
  expect_error(cdsdatagrab:::era5land_product_date_outcomes(expected[1:2], list(date_results = list(make_result("2022-02-01", "success")))), "unexpected")
  undated <- list(date_results = list(make_result(expected[[1L]], "success")), processing_failures = list(list(error_message = "month failed")))
  undated_out <- cdsdatagrab:::era5land_product_date_outcomes(expected[1:2], undated)
  expect_true(undated_out$undated_processing_failure)
  expect_length(undated_out$successful_dates, 0L)
  expect_error(cdsdatagrab:::era5land_product_date_outcomes(c("2022-01-01", "2022-1-02"), missing), "invalid ISO")
  expect_error(cdsdatagrab:::era5land_product_date_outcomes(as.Date(c("2022-01-01", NA)), missing), "missing")
})

test_that("complete product results use canonical ISO dates", {
  dates <- as.Date("2022-04-01") + 0:29
  process <- list(date_results = lapply(dates, function(d) list(date = d, status = "reused", output_path = "x.tif")), processing_failures = list(), written = character(), reused = rep("x.tif", 30), replaced = character())
  result <- cdsdatagrab:::era5land_product_result("era5land_tmean", dates, process, "success")
  expect_identical(result$requested_dates, format(dates, "%Y-%m-%d"))
  expect_identical(result$successful_dates, format(dates, "%Y-%m-%d"))
  expect_length(result$failed_dates, 0L)
  expect_false(any(grepl("charToDate", capture.output(str(result)), fixed = TRUE)))
})

test_that("ERA5-Land annotation is scoped to explicit outputs and idempotent", {
  dir <- file.path(getwd(), ".test-era5land-sidecars-hardening"); unlink(dir, recursive = TRUE, force = TRUE); dir.create(dir, recursive = TRUE)
  on.exit(unlink(dir, recursive = TRUE, force = TRUE), add = TRUE)
  spec <- cdsdatagrab::get_variable_spec("era5land_tmean")
  request <- list(source_family_id = "era5land_daily_mean_utc06", request_hash = "feb-hash", request_start = "2022-02-01", request_end = "2022-02-28", raw_request_dates = as.Date("2022-02-01") + 0:27, time_zone = "utc-06:00", frequency = "1_hourly", daily_statistic = "daily_mean")
  make_month <- function(month, n, hash) {
    paths <- file.path(dir, sprintf("era5land_tmean_2022-%02d-%02d.tif", month, seq_len(n)))
    for (path in paths) { file.create(path); jsonlite::write_json(list(request_hash = hash, keep = list(scientific = TRUE)), paste0(path, ".json"), auto_unbox = TRUE, pretty = TRUE) }
    paths
  }
  jan <- make_month(1, 3, "jan-hash"); feb <- make_month(2, 3, "old-feb"); mar <- make_month(3, 3, "mar-hash")
  unrelated <- file.path(dir, "unrelated.json"); jsonlite::write_json(list(keep = TRUE), unrelated, auto_unbox = TRUE)
  sha <- function(paths) vapply(paste0(paths, ".json"), function(path) digest::digest(file = path, algo = "sha256"), character(1))
  tif_sha <- function(paths) vapply(paths, function(path) digest::digest(file = path, algo = "sha256"), character(1))
  checks_before <- c(sha(c(jan, mar)), unrelated = digest::digest(file = unrelated, algo = "sha256"))
  tif_before <- tif_sha(feb)
  changed <- cdsdatagrab:::era5land_annotate_product_metadata(feb, spec, request, list(member_name = "feb.nc", environmental_variable_alias = "t2m", archive_path = "feb.zip", source_map_rows = 28L))
  expect_length(changed, 3L)
  expect_identical(sha(jan), checks_before[1:3])
  expect_identical(sha(mar), checks_before[4:6])
  expect_identical(digest::digest(file = unrelated, algo = "sha256"), checks_before[[7L]])
  expect_identical(tif_sha(feb), tif_before)
  feb_hash <- sha(feb)
  expect_identical(cdsdatagrab:::era5land_annotate_product_metadata(feb, spec, request, list(member_name = "feb.nc", environmental_variable_alias = "t2m", archive_path = "feb.zip", source_map_rows = 28L)), character())
  expect_identical(sha(feb), feb_hash)
  expect_true(all(vapply(feb, function(path) identical(jsonlite::read_json(paste0(path, ".json"), simplifyVector = TRUE)$request_hash, "feb-hash"), logical(1))))
})

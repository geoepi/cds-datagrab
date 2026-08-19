era5land_read_failure_fixture <- function(label) {
  skip_if_not_installed("terra")
  root <- file.path(getwd(), paste0(".test-era5land-read-failure-", label))
  unlink(root, recursive = TRUE, force = TRUE)
  dir.create(root, recursive = TRUE)
  withr::defer(unlink(root, recursive = TRUE, force = TRUE), envir = testthat::teardown_env())
  template <- terra::rast(nrows = 2L, ncols = 2L, xmin = -126, xmax = -125.8, ymin = 42.7, ymax = 42.9, crs = "EPSG:4326")
  terra::values(template) <- 1
  template_path <- file.path(root, "template.tif")
  terra::writeRaster(template, template_path, overwrite = TRUE)
  raw_path <- file.path(root, "era5land-march.nc")
  file.create(raw_path)
  spec <- get_variable_spec("era5land_soilwater_l1_mean")
  config <- list(
    project = list(dataset_id = spec$id),
    spatial = list(mask_to_boundary = FALSE, mask_to_template = TRUE, require_complete_template_coverage = TRUE),
    processing = list(resampling_method = "bilinear", datatype = "FLT4S", naflag = -9999),
    validation = list(require_exact_template_geometry = TRUE)
  )
  list(root = root, raw_path = raw_path, daily_dir = file.path(root, "daily"), template_path = template_path, spec = spec, config = config)
}

test_that("NetCDF read errors return canonical failed date results without masking", {
  fixture <- era5land_read_failure_fixture("sentinel")
  expected <- c("2022-03-01", "2022-03-02", "2022-03-03")
  local_mocked_bindings(
    read_era5_daily_layers = function(...) stop("SENTINEL_NETCDF_READ_ERROR", call. = TRUE),
    .package = "cdsdatagrab"
  )

  result <- expect_no_error(process_downloaded_variable(
    fixture$raw_path,
    fixture$daily_dir,
    fixture$template_path,
    NA_character_,
    fixture$config,
    fixture$spec,
    expected_dates = expected,
    run_expected_dates = list(expected)
  ))

  expect_gt(length(result$processing_failures), 0L)
  failure <- result$processing_failures[[1L]]
  expect_identical(failure$stage, "netcdf_read")
  expect_identical(failure$condition_message, "SENTINEL_NETCDF_READ_ERROR")
  expect_true(length(failure$condition_class) > 0L)
  expect_true(!is.null(failure$condition_call))
  expect_true(nzchar(failure$traceback))
  expect_setequal(names(result$date_results), expected)
  expect_true(all(vapply(result$date_results, `[[`, character(1), "status") == "failed"))
  failed_dates <- vapply(result$date_results, `[[`, character(1), "date")
  expect_identical(unname(failed_dates), expected)
  expect_true(all(grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", failed_dates)))
  expect_false(any(grepl("charToDate", capture.output(str(result)), fixed = TRUE)))
  expect_length(list.files(fixture$daily_dir, pattern = "\\.tif$", recursive = TRUE), 0L)
})

test_that("secondary read-failure bookkeeping errors cannot replace the root error", {
  fixture <- era5land_read_failure_fixture("secondary")
  expected <- c("2022-03-01", "2022-03-02")
  local_mocked_bindings(
    read_era5_daily_layers = function(...) stop("SENTINEL_NETCDF_READ_ERROR", call. = TRUE),
    daily_output_filename = function(...) stop("SENTINEL_DIAGNOSTIC_RECORDING_ERROR", call. = TRUE),
    .package = "cdsdatagrab"
  )

  result <- expect_no_error(process_downloaded_variable(
    fixture$raw_path,
    fixture$daily_dir,
    fixture$template_path,
    NA_character_,
    fixture$config,
    fixture$spec,
    expected_dates = as.Date(expected),
    run_expected_dates = expected
  ))

  failure <- result$processing_failures[[1L]]
  expect_identical(failure$stage, "netcdf_read")
  expect_identical(failure$condition_message, "SENTINEL_NETCDF_READ_ERROR")
  expect_match(failure$diagnostic_recording_error$condition_message, "SENTINEL_DIAGNOSTIC_RECORDING_ERROR", fixed = TRUE)
  expect_false(grepl("SENTINEL_DIAGNOSTIC_RECORDING_ERROR", failure$condition_message, fixed = TRUE))
  expect_length(list.files(fixture$daily_dir, pattern = "\\.tif$", recursive = TRUE), 0L)
})

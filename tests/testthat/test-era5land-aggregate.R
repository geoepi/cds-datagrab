era5land_aggregate_fixture <- function(label, dates = as.Date("2021-12-27") + 0:6) {
  skip_if_not_installed("terra")
  root <- test_external_root(paste0("era5land-aggregate-", label))
  fixture_dir <- tempfile("era5land-aggregate-config-", tmpdir = package_root())
  dir.create(fixture_dir, recursive = TRUE)
  withr::defer(unlink(fixture_dir, recursive = TRUE, force = TRUE), envir = testthat::teardown_env())
  template <- terra::rast(nrows = 2, ncols = 2, xmin = 0, xmax = 2, ymin = 0, ymax = 2, crs = "EPSG:4326")
  terra::values(template) <- 1
  template_path <- file.path(fixture_dir, "template.tif")
  terra::writeRaster(template, template_path, overwrite = TRUE)
  support <- template
  terra::values(support) <- c(1, NA, 1, 1)
  support_path <- file.path(fixture_dir, "support.tif")
  terra::writeRaster(support, support_path, overwrite = TRUE)
  audit_path <- file.path(fixture_dir, "unsupported.csv")
  utils::write.csv(data.frame(cell = 2L, longitude = 0.5, latitude = 1.5,
    reason = "structural_era5land_source_absence", affected_products = "all",
    nearest_finite_source_distance_km = 40, source_request_hash = "fixture",
    representative_date = as.character(min(dates)), support_decision_method = "fixture"), audit_path, row.names = FALSE)
  cfg <- read_pipeline_config(package_file("config", "era5land_daily_mean_utc06_smoke.yml"))
  cfg$project$profile <- "smoke"
  cfg$paths$root <- NULL
  cfg$spatial$template_path <- template_path
  cfg$spatial$bbox_path <- package_file("spatial_domain", "study_bbox.gpkg")
  cfg$coverage$support_mask <- support_path
  cfg$coverage$unsupported_cells_audit <- audit_path
  cfg$temporal$initial_start_date <- as.character(min(dates))
  cfg$temporal$observed_end <- as.character(max(dates))
  cfg$temporal$configured_start_date <- as.character(min(dates))
  cfg$temporal$configured_end_date <- as.character(max(dates))
  cfg$temporal$future_end_date <- as.character(max(dates))
  config_path <- file.path(fixture_dir, "config.yml")
  yaml::write_yaml(cfg, config_path)
  for (id in era5land_family_product_ids()) {
    spec <- get_variable_spec(id)
    paths <- resolve_storage_paths(list(project = list(profile = "smoke", dataset_id = id), paths = list(root = NULL)), package_root(), root, create = TRUE)
    for (i in seq_along(dates)) {
      r <- template
      value <- switch(id,
        era5land_tmean = 10 + i,
        era5land_soiltemp_l1_mean = 12 + i,
        era5land_soiltemp_l2_mean = 14 + i,
        era5land_soilwater_l1_mean = 0.2 + i / 100,
        era5land_soilwater_l2_mean = 0.3 + i / 100,
        era5land_surface_pressure_mean = 100 + i / 10,
        era5land_lai_high_mean = 1 + i / 10,
        era5land_lai_low_mean = 2 + i / 10)
      terra::values(r) <- c(value, NA, value + 1, value + 2)
      path <- file.path(paths$daily_dir, daily_output_filename(spec, dates[[i]]))
      terra::writeRaster(r, path, overwrite = TRUE)
      jsonlite::write_json(list(source_family_id = "era5land_daily_mean_utc06",
        request_hash = if (dates[[i]] <= as.Date("2021-12-31")) "dec-hash" else "jan-hash",
        request_start = if (dates[[i]] <= as.Date("2021-12-31")) "2021-12-01" else "2022-01-01",
        request_end = if (dates[[i]] <= as.Date("2021-12-31")) "2021-12-31" else "2022-01-31"),
        paste0(path, ".json"), auto_unbox = TRUE)
    }
  }
  list(root = root, config = config_path, dates = dates, template = template_path)
}

test_that("ERA5-Land aggregate mode creates all products from daily TIFFs across a year boundary", {
  fixture <- era5land_aggregate_fixture("complete")
  first <- run_era5land_daily_mean_family(fixture$config, mode = "aggregate", dry_run = FALSE,
    output_root = fixture$root, start_date = min(fixture$dates), end_date = max(fixture$dates))
  expect_identical(first$status, "success")
  expect_equal(first$manifest$complete_iso_week_count, 1L)
  expect_equal(first$manifest$weekly_outputs_expected, 8L)
  expect_equal(first$manifest$weekly_outputs_written, 8L)
  expect_equal(first$manifest$weekly_outputs_reused, 0L)
  expect_false(isTRUE(first$source_diagnostic$cds_contacted))
  expect_false(isTRUE(first$source_diagnostic$raw_reused))
  tmean <- first$products[["era5land_tmean"]]
  weekly_path <- tmean$weekly$written[[1L]]
  expect_equal(as.numeric(terra::values(terra::rast(weekly_path), mat = FALSE)), c(14, NA, 15, 16))
  expect_equal(jsonlite::read_json(paste0(weekly_path, ".json"), simplifyVector = TRUE)$source_request_hashes, c("dec-hash", "jan-hash"))
  expect_equal(jsonlite::read_json(paste0(weekly_path, ".json"), simplifyVector = TRUE)$selected_daily_dates, as.character(fixture$dates))
  second <- run_era5land_daily_mean_family(fixture$config, mode = "aggregate", dry_run = FALSE,
    output_root = fixture$root, start_date = min(fixture$dates), end_date = max(fixture$dates))
  expect_identical(second$status, "success")
  expect_equal(second$manifest$weekly_outputs_written, 0L)
  expect_equal(second$manifest$weekly_outputs_reused, 8L)
})

test_that("ERA5-Land aggregate mode does not create a week when a daily date is missing", {
  fixture <- era5land_aggregate_fixture("missing")
  paths <- resolve_storage_paths(list(project = list(profile = "smoke", dataset_id = "era5land_tmean"), paths = list(root = NULL)), package_root(), fixture$root)
  unlink(file.path(paths$daily_dir, "era5land_tmean_2021-12-30.tif"))
  unlink(file.path(paths$daily_dir, "era5land_tmean_2021-12-30.tif.json"))
  result <- run_era5land_daily_mean_family(fixture$config, mode = "aggregate", dry_run = FALSE,
    output_root = fixture$root, start_date = min(fixture$dates), end_date = max(fixture$dates), product_ids = "era5land_tmean")
  expect_identical(result$status, "failed")
  expect_equal(result$manifest$weekly_outputs_written, 0L)
  expect_equal(result$manifest$weekly_outputs_reused, 0L)
  expect_true("era5land_tmean__2021-W52" %in% result$manifest$failed_product_weeks)
  expect_false(file.exists(file.path(paths$weekly_dir, "era5land_tmean_2021-W52.tif")))
})

test_that("weekly assessment with an explicit date window preserves ISO weeks across months and years", {
  dates <- as.Date(c("2021-12-27", "2021-12-28", "2021-12-29", "2021-12-30", "2021-12-31", "2022-01-01", "2022-01-02"))
  assessment <- assess_iso_week_completeness(dates, expected_dates = dates)
  expect_equal(assessment$week_id, "2021-W52")
  expect_true(assessment$complete)
  expect_equal(length(assessment$expected_dates[[1L]]), 7L)
})

test_that("aggregate failure accounting does not create dangling product-week IDs", {
  expect_identical(cdsdatagrab:::era5land_product_week_failure_ids("era5land_tmean", character()), character())
  expect_identical(cdsdatagrab:::era5land_product_week_failure_ids("era5land_tmean", "2022-W05"), "era5land_tmean__2022-W05")
})

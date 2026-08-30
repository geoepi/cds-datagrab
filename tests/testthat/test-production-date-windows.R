test_that("all environmental production configs use the 2022-2026 canonical range", {
  ids <- c("era5_mintemp", "era5_soilmoist", "era5_lai_low", "agera5_relhum_min")
  files <- file.path(package_root(), "config", paste0(c("era5_mintemp", "era5_soilmoist", "era5_lai_low", "agera5_relhum_min"), "_production.yml"))
  for (file in files) {
    cfg <- read_pipeline_config(file)
    expect_equal(as.character(cfg$temporal$initial_start_date), "2022-01-01")
    expect_equal(as.character(cfg$temporal$configured_start_date), "2022-01-01")
    expect_equal(as.character(cfg$temporal$configured_end_date), "2026-12-31")
    expect_equal(as.character(cfg$temporal$future_end_date), "2026-12-31")
  }
  expect_length(ids, 4)
})

test_that("annual windows have correct dates and twelve monthly requests", {
  cfg <- read_pipeline_config(package_file("config", "era5_lai_low_production.yml"))
  area <- c(43, -127, 42, -125)
  expected_days <- c(`2022`=365, `2023`=365, `2024`=366, `2025`=365, `2026`=365)
  for (year in names(expected_days)) {
    window <- resolve_pipeline_date_window(cfg, paste0(year, "-01-01"), paste0(year, "-12-31"), TRUE)
    dates <- safe_date_sequence(window$effective_start, window$effective_end)
    expect_length(dates, expected_days[[year]])
    expect_equal(length(build_variable_requests(dates, area, cfg, get_variable_spec("era5_lai_low"))), 12)
  }
})

test_that("full production dry planning validates 1826 dates and 60 monthly requests", {
  root <- test_external_root("production-full-plan")
  result <- run_environmental_pipeline(package_file("config", "era5_lai_low_production.yml"), mode="full", dry_run=TRUE, output_root=root)
  plan <- utils::read.csv(file.path(result$run_dir, "planned_dates.csv"), stringsAsFactors=FALSE)
  summary <- jsonlite::read_json(file.path(result$run_dir, "production_planning_summary.json"), simplifyVector=TRUE)
  expect_equal(nrow(plan), 1826)
  expect_equal(length(result$planned_request_hashes), 60)
  expect_equal(summary$plan_validation$status, "success")
  expect_equal(result$stage_results$final_validation$result$reason, "dry_run_plan_valid")
  expect_equal(result$pipeline_status, "success")
})

test_that("date overrides cannot expand the canonical range or execute across years by default", {
  cfg <- read_pipeline_config(package_file("config", "era5_lai_low_production.yml"))
  expect_error(resolve_pipeline_date_window(cfg, "2020-01-01", "2020-12-31", TRUE), "within configured production window")
  expect_error(resolve_pipeline_date_window(cfg, "2022-01-01", "2027-01-01", TRUE), "within configured production window")
  expect_error(resolve_pipeline_date_window(cfg, "2023-01-01", "2022-12-31", TRUE), "must not be after")
  old <- Sys.getenv("ALLOW_MULTIYEAR", unset=NA_character_)
  withr::defer(if (is.na(old)) Sys.unsetenv("ALLOW_MULTIYEAR") else Sys.setenv(ALLOW_MULTIYEAR=old))
  Sys.unsetenv("ALLOW_MULTIYEAR")
  expect_error(run_environmental_pipeline(package_file("config", "era5_lai_low_production.yml"), mode="full", dry_run=FALSE, start_date="2022-01-01", end_date="2023-12-31", output_root=test_external_root("multiyear-guard")), "production execution spans multiple calendar years")
})

test_that("explicit production date windows may advance beyond observed_end", {
  cfg <- read_pipeline_config(package_file("config", "era5_lai_low_production.yml"))
  window <- resolve_pipeline_date_window(cfg, "2026-07-01", "2026-07-26", FALSE)
  expect_identical(as.character(window$observed_end), "2026-07-12")
  expect_identical(as.character(window$effective_end), "2026-07-26")
  expect_identical(window$date_override_source, "explicit_override")
  expect_identical(as.character(cfg$temporal$observed_end), "2026-07-12")
})

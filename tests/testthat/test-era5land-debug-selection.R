test_that("debug selection uses the complete smoke family request", {
  cfg <- read_pipeline_config(package_file("config", "era5land_daily_mean_utc06_smoke.yml"))
  cfg <- resolve_config_paths(cfg, package_root(), tempfile("era5land-debug-root-"), FALSE)
  family_dates <- era5land_expected_dates(cfg, dry_run = FALSE)
  expect_equal(as.character(family_dates), as.character(as.Date("2026-02-01") + 0:2))
  diag <- diagnose_spatial_domain(cfg$spatial$template_path, cfg$spatial$bbox_path, cfg)
  requests <- build_era5land_daily_mean_requests(family_dates, diag$final_cds_area, cfg)
  request <- era5land_request_for_date(requests, as.Date("2026-02-01"))
  expect_equal(request$request_hash, "016f79fb")
  expect_equal(as.character(as.Date(request$raw_request_dates)), as.character(family_dates))
  expect_length(request$variable, 8L)
  expect_equal(length(request$raw_request_dates), 3L)
  one_day <- build_era5land_daily_mean_requests(as.Date("2026-02-01"), diag$final_cds_area, cfg)[[1L]]
  expect_equal(one_day$request_hash, "5516ed9e")
  expect_false(identical(one_day$request_hash, request$request_hash))
})

test_that("debug request selection chooses the containing month across multiple months", {
  cfg <- read_pipeline_config(package_file("config", "era5land_daily_mean_utc06_production.yml"))
  dates <- as.Date(c("2025-01-01", "2025-01-02", "2025-02-01"))
  requests <- build_era5land_daily_mean_requests(dates, c(43, -127, 42, -125), cfg)
  january <- era5land_request_for_date(requests, as.Date("2025-01-02"))
  february <- era5land_request_for_date(requests, as.Date("2025-02-01"))
  expect_equal(as.character(as.Date(january$raw_request_dates)), as.character(as.Date(c("2025-01-01", "2025-01-02"))))
  expect_equal(as.character(as.Date(february$raw_request_dates)), "2025-02-01")
  expect_false(identical(january$request_hash, february$request_hash))
  expect_error(era5land_request_for_date(requests, as.Date("2025-03-01")), "found 0")
})

test_that("debug date validation fails before request/cache selection", {
  cfg <- read_pipeline_config(package_file("config", "era5land_daily_mean_utc06_smoke.yml"))
  family_dates <- era5land_expected_dates(cfg, dry_run = FALSE)
  expect_false(as.Date("2026-01-31") %in% family_dates)
  expect_error(era5land_validate_debug_date(as.Date("2026-01-31"), family_dates), "Debug date 2026-01-31 is outside the configured ERA5-Land request period")
})

test_that("debug member map can retain raw coverage while selecting one processing date", {
  member <- list(extracted_path = "member.nc")
  request <- list(request_hash = "016f79fb", raw_request_dates = as.character(as.Date("2026-02-01") + 0:2))
  full_map <- era5land_member_date_map(member, request, request)
  selected_map <- full_map[as.Date(full_map$date) == as.Date("2026-02-01"), , drop = FALSE]
  expect_equal(nrow(full_map), 3L)
  expect_equal(nrow(selected_map), 1L)
  expect_equal(selected_map$date, "2026-02-01")
  expect_equal(as.character(as.Date(request$raw_request_dates)), as.character(as.Date("2026-02-01") + 0:2))
})

test_that("debug runner help exits successfully before configuration access", {
  rscript <- file.path(R.home("bin"), if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
  output <- system2(rscript, c(package_file("scripts", "debug_era5land_slice.R"), "--help"), stdout = TRUE, stderr = TRUE)
  expect_identical(attr(output, "status") %||% 0L, 0L)
  expect_true(any(grepl("Usage:.*debug_era5land_slice", output)))
  expect_true(any(grepl("--config PATH", output, fixed = TRUE)))
  expect_true(any(grepl("--output-root PATH", output, fixed = TRUE)))
})

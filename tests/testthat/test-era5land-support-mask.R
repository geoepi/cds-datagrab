test_that("ERA5-Land support mask is an auditable subset of the master template", {
  skip_if_not_installed("terra")
  cfg <- read_pipeline_config(package_file("config", "era5land_daily_mean_utc06_smoke.yml"))
  cfg <- resolve_config_paths(cfg, package_root(), tempfile("era5land-support-root-"), FALSE)
  template <- terra::rast(cfg$spatial$template_path)
  info <- era5land_support_mask_info(cfg, template, required = TRUE)
  expect_equal(info$master_template_cells, 16759)
  expect_equal(info$era5land_supported_cells, 16756)
  expect_equal(info$unsupported_cells, c(28012L, 35085L, 35964L))
  expect_equal(info$unsupported_count, 3L)
  expect_true(all(info$audit$reason == "structural_era5land_source_absence"))
  expect_equal(info$audit$representative_date, rep("2026-02-01", 3))
  expect_equal(info$audit$source_request_hash, rep("016f79fb", 3))
  expect_true(all(info$audit$nearest_finite_source_distance_km > 35))
  expect_equal(sum(is.na(terra::values(info$mask, mat = FALSE))), terra::ncell(template) - 16756L)
  provenance <- era5land_support_provenance(cfg)
  expect_equal(provenance$structurally_unsupported_cell_count, 3L)
  expect_equal(provenance$structurally_unsupported_cell_ids, c(28012L, 35085L, 35964L))
  expect_equal(provenance$support_distance_threshold_km, 35)
  expect_true(nzchar(provenance$master_template_sha256))
  expect_true(nzchar(provenance$era5land_support_mask_sha256))
  expect_true(nzchar(provenance$unsupported_cells_audit_sha256))
})

test_that("unknown ERA5-Land support gaps cannot be silently added", {
  skip_if_not_installed("terra")
  cfg <- read_pipeline_config(package_file("config", "era5land_daily_mean_utc06_smoke.yml"))
  cfg <- resolve_config_paths(cfg, package_root(), tempfile("era5land-support-root-"), FALSE)
  template <- terra::rast(cfg$spatial$template_path)
  info <- era5land_support_mask_info(cfg, template, required = TRUE)
  path <- tempfile("era5land-support-invalid-", tmpdir = package_root(), fileext = ".tif")
  on.exit(unlink(Sys.glob(paste0(path, "*"))), add = TRUE)
  invalid <- info$mask
  values <- terra::values(invalid, mat = FALSE)
  values[which(!is.na(values))[1L]] <- NA_real_
  terra::values(invalid) <- values
  terra::writeRaster(invalid, path, overwrite = TRUE)
  cfg$coverage$support_mask <- path
  expect_error(era5land_support_mask_info(cfg, template, required = TRUE), "mask and audit cell IDs disagree")
})

test_that("support-aware coverage distinguishes structural exclusion from repair gaps", {
  skip_if_not_installed("terra")
  make <- function() terra::rast(nrows = 3, ncols = 3, xmin = 0, xmax = 3, ymin = 0, ymax = 3, crs = "EPSG:4326")
  template <- make(); support <- make(); bilinear <- make(); nearest <- make(); source <- make()
  terra::values(template) <- 1; terra::values(support) <- 1; terra::values(bilinear) <- 1; terra::values(nearest) <- 1; terra::values(source) <- 1
  terra::values(support)[5L] <- NA_real_; terra::values(bilinear)[4L] <- NA_real_; terra::values(nearest)[4L] <- NA_real_
  result <- analyze_template_coverage(bilinear, nearest, source, template, support_mask = support, maximum_repair_fraction = 1)
  expect_equal(result$diagnostics$master_template_cells, 9)
  expect_equal(result$diagnostics$era5land_supported_cells, 8)
  expect_equal(result$diagnostics$structurally_unsupported_cells, 1)
  expect_equal(result$diagnostics$pre_repair_missing_cells, 2)
  expect_equal(result$diagnostics$pre_repair_missing_supported_cells, 1)
  expect_equal(result$diagnostics$post_repair_unexpected_missing_cells, 0)
  expect_equal(result$repair_count, 1)
  expect_true(is.na(terra::values(result$raster, mat = FALSE)[5L]))
  expect_true(is.finite(terra::values(result$raster, mat = FALSE)[4L]))
  expect_equal(validate_template_coverage(result$raster, template, TRUE, support_mask = support)$structurally_unsupported_cells, 1)
  expect_error(validate_template_coverage(bilinear, template, TRUE, support_mask = support), "missing_inside_count=1")
  finite_structural <- result$raster; terra::values(finite_structural)[5L] <- 99
  expect_error(validate_template_coverage(finite_structural, template, TRUE, support_mask = support), "outside_support_finite_count=1")
})

test_that("coverage regression reports 148 initial gaps, 145 repairs, and three structural exclusions", {
  skip_if_not_installed("terra")
  make <- function() terra::rast(nrows = 40, ncols = 400, xmin = 0, xmax = 400, ymin = 0, ymax = 40, crs = "EPSG:3857")
  template <- make(); support <- make(); bilinear <- make(); nearest <- make(); source <- make()
  terra::values(template) <- 1; terra::values(support) <- 1; terra::values(bilinear) <- 1; terra::values(nearest) <- 1; terra::values(source) <- 1
  structural <- c(15998L, 15999L, 16000L); gaps <- seq.int(2L, 2L + 10L * 144L, by = 10L)
  terra::values(support)[structural] <- NA_real_; terra::values(bilinear)[gaps] <- NA_real_; terra::values(nearest)[gaps] <- NA_real_
  result <- analyze_template_coverage(bilinear, nearest, source, template, support_mask = support, maximum_repair_count = 256L, maximum_repair_fraction = 0.01)
  expect_equal(result$diagnostics$pre_repair_missing_cells, 148)
  expect_equal(result$diagnostics$pre_repair_missing_supported_cells, 145)
  expect_equal(result$diagnostics$structurally_unsupported_cells, 3)
  expect_equal(result$diagnostics$repair_count, 145)
  expect_equal(result$diagnostics$post_repair_unexpected_missing_cells, 0)
  expect_equal(result$diagnostics$outside_support_finite_cells, 0)
})

test_that("weekly means retain structural NAs while requiring complete supported cells", {
  skip_if_not_installed("terra")
  template <- terra::rast(nrows = 2, ncols = 2, xmin = 0, xmax = 2, ymin = 0, ymax = 2, crs = "EPSG:4326")
  support <- template; terra::values(template) <- 1; terra::values(support) <- 1; terra::values(support)[2L] <- NA_real_
  base <- tempfile("era5land-weekly-support-", tmpdir = package_root()); dir.create(base, recursive = TRUE)
  on.exit(unlink(base, recursive = TRUE), add = TRUE)
  paths <- vapply(1:7, function(i) { r <- template; terra::values(r) <- c(i, NA_real_, i + 1, i + 2); path <- file.path(base, paste0("daily-", i, ".tif")); terra::writeRaster(r, path, overwrite = TRUE); path }, character(1))
  weekly <- aggregate_weekly_values(paths, get_variable_spec("era5land_tmean"))
  check <- validate_template_coverage(weekly, template, TRUE, support_mask = support)
  expect_true(check$complete)
  expect_true(is.na(terra::values(weekly, mat = FALSE)[2L]))
  expect_equal(weekly_input_fingerprint("2026-W01", get_variable_spec("era5land_tmean"), as.Date("2026-01-05") + 0:6, rep("x", 7), "template", support_mask_sha256 = "mask-a"), weekly_input_fingerprint("2026-W01", get_variable_spec("era5land_tmean"), as.Date("2026-01-05") + 0:6, rep("x", 7), "template", support_mask_sha256 = "mask-a"))
  expect_false(identical(weekly_input_fingerprint("2026-W01", get_variable_spec("era5land_tmean"), as.Date("2026-01-05") + 0:6, rep("x", 7), "template", support_mask_sha256 = "mask-a"), weekly_input_fingerprint("2026-W01", get_variable_spec("era5land_tmean"), as.Date("2026-01-05") + 0:6, rep("x", 7), "template", support_mask_sha256 = "mask-b")))
})

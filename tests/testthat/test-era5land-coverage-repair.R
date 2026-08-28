test_that("bounded coverage repair fills connected projection gaps through size four", {
  skip_if_not_installed("terra")
  template <- terra::rast(nrows = 10, ncols = 10, xmin = 0, xmax = 10, ymin = 0, ymax = 10, crs = "EPSG:4326")
  terra::values(template) <- 1
  bilinear <- template
  nearest <- template
  source <- template
  terra::values(bilinear) <- 10
  terra::values(nearest) <- 20
  terra::values(source) <- 30
  missing_cells <- c(
    terra::cellFromRowCol(template, 2, 2),
    terra::cellFromRowCol(template, 2, 6), terra::cellFromRowCol(template, 2, 7),
    terra::cellFromRowCol(template, 5, 2), terra::cellFromRowCol(template, 5, 3), terra::cellFromRowCol(template, 6, 2),
    terra::cellFromRowCol(template, 8, 7), terra::cellFromRowCol(template, 8, 8), terra::cellFromRowCol(template, 9, 7), terra::cellFromRowCol(template, 9, 8)
  )
  terra::values(bilinear)[missing_cells] <- NA
  result <- analyze_template_coverage(bilinear, nearest, source, template, maximum_repair_count = 20L, maximum_repair_fraction = 1, maximum_component_size = 4L)
  expect_true(result$repair_applied)
  expect_equal(result$repair_count, 10)
  expect_equal(result$unresolved_count, 0)
  expect_equal(sort(result$diagnostics$component_sizes), c(1L, 2L, 3L, 4L))
  expect_equal(result$diagnostics$projection_created_nodata_count, 10)
  expect_equal(result$diagnostics$missing_inside_pre_repair_count, 10)
  expect_equal(result$diagnostics$missing_inside_post_repair_count, 0)
  expect_equal(terra::values(result$raster, mat = FALSE)[missing_cells], rep(20, 10))
})

test_that("coverage repair leaves a component larger than the configured bound unresolved", {
  skip_if_not_installed("terra")
  template <- terra::rast(nrows = 6, ncols = 6, xmin = 0, xmax = 6, ymin = 0, ymax = 6, crs = "EPSG:4326")
  terra::values(template) <- 1
  bilinear <- template; nearest <- template; source <- template
  terra::values(bilinear) <- 10; terra::values(nearest) <- 20; terra::values(source) <- 30
  cells <- terra::cellFromRowCol(template, 2, 2:6)
  terra::values(bilinear)[cells] <- NA
  result <- analyze_template_coverage(bilinear, nearest, source, template, maximum_repair_count = 100L, maximum_repair_fraction = 1, maximum_component_size = 4L)
  expect_false(result$repair_applied)
  expect_equal(result$repair_count, 0)
  expect_equal(result$unresolved_count, 5)
  expect_equal(result$diagnostics$component_sizes, 5L)
  expect_equal(result$diagnostics$unrepairable_count, 5)
})

test_that("coverage repair diagnostics include pre/post rasters", {
  skip_if_not_installed("terra")
  diagnostic_dir <- file.path(getwd(), ".test-era5land-coverage-diagnostics")
  if (dir.exists(diagnostic_dir)) unlink(diagnostic_dir, recursive = TRUE, force = TRUE)
  on.exit(unlink(diagnostic_dir, recursive = TRUE, force = TRUE), add = TRUE)
  template <- terra::rast(nrows = 3, ncols = 3, xmin = 0, xmax = 3, ymin = 0, ymax = 3, crs = "EPSG:4326")
  terra::values(template) <- 1
  bilinear <- template; nearest <- template; source <- template
  terra::values(bilinear) <- 10; terra::values(nearest) <- 20; terra::values(source) <- 30
  terra::values(bilinear)[5] <- NA
  result <- analyze_template_coverage(bilinear, nearest, source, template, maximum_repair_count = 4L, maximum_repair_fraction = 1, diagnostics_dir = diagnostic_dir, date = "2026-02-01", prefix = "era5land")
  expect_true(all(file.exists(result$coverage_diagnostic_paths)))
  expect_true(all(c("missing_inside_pre_repair", "repaired_cells", "missing_inside_post_repair", "outside_mask") %in% names(result$coverage_diagnostic_paths)))
})

test_that("same-cell missing nearest uses an original local donor", {
  skip_if_not_installed("terra")
  template <- terra::rast(nrows = 5, ncols = 5, xmin = 0, xmax = 5, ymin = 0, ymax = 5, crs = "EPSG:4326")
  terra::values(template) <- 1
  bilinear <- template; nearest <- template; source <- template
  terra::values(bilinear) <- NA; terra::values(nearest) <- NA; terra::values(source) <- 1; terra::values(template) <- NA
  donor <- terra::cellFromRowCol(template, 2, 2); target <- terra::cellFromRowCol(template, 3, 3)
  terra::values(template)[c(target, donor)] <- 1; terra::values(bilinear)[donor] <- 42
  result <- analyze_template_coverage(bilinear, nearest, source, template, maximum_repair_count = 4L, maximum_repair_fraction = 1, maximum_donor_radius_cells = 2L)
  expect_true(result$repair_applied)
  expect_equal(terra::values(result$raster, mat = FALSE)[target], 42)
  expect_equal(result$details[[1]]$gap_type, "bilinear_missing_nearest_same_cell_missing_local_donor")
  expect_equal(result$details[[1]]$maximum_donor_distance_cells, 1)
})

test_that("local donor search expands to radius two but not beyond", {
  skip_if_not_installed("terra")
  make_case <- function(donor_row, donor_col) {
    template <- terra::rast(nrows = 7, ncols = 7, xmin = 0, xmax = 7, ymin = 0, ymax = 7, crs = "EPSG:4326")
    terra::values(template) <- 1
    bilinear <- template; nearest <- template; source <- template
    terra::values(bilinear) <- NA; terra::values(nearest) <- NA; terra::values(source) <- 1; terra::values(template) <- NA
    target <- terra::cellFromRowCol(template, 4, 4); donor <- terra::cellFromRowCol(template, donor_row, donor_col)
    terra::values(template)[c(target, donor)] <- 1; terra::values(bilinear)[donor] <- 7
    list(template = template, bilinear = bilinear, nearest = nearest, source = source, target = target)
  }
  radius_two <- make_case(2, 2)
  repaired <- analyze_template_coverage(radius_two$bilinear, radius_two$nearest, radius_two$source, radius_two$template, maximum_repair_count = 4L, maximum_repair_fraction = 1, maximum_donor_radius_cells = 2L)
  expect_true(repaired$repair_applied)
  expect_equal(repaired$details[[1]]$maximum_donor_distance_cells, 2)
  radius_three <- make_case(1, 1)
  rejected <- analyze_template_coverage(radius_three$bilinear, radius_three$nearest, radius_three$source, radius_three$template, maximum_repair_count = 4L, maximum_repair_fraction = 1, maximum_donor_radius_cells = 2L)
  expect_false(rejected$repair_applied)
  expect_match(rejected$component_records[[1]]$repair_failure_reason, "no_(valid_donor_within_radius|source_land_support)")
  expect_equal(rejected$unresolved_count, 1)
})

test_that("component repair is atomic and never self-propagates", {
  skip_if_not_installed("terra")
  template <- terra::rast(nrows = 7, ncols = 7, xmin = 0, xmax = 7, ymin = 0, ymax = 7, crs = "EPSG:4326")
  terra::values(template) <- 1
  bilinear <- template; nearest <- template; source <- template
  terra::values(bilinear) <- NA; terra::values(nearest) <- NA; terra::values(source) <- 1; terra::values(template) <- NA
  targets <- terra::cellFromRowCol(template, 4:5, 4)
  donor <- terra::cellFromRowCol(template, 2, 2); terra::values(template)[c(targets, donor)] <- 1; terra::values(bilinear)[donor] <- 9
  result <- analyze_template_coverage(bilinear, nearest, source, template, maximum_repair_count = 4L, maximum_repair_fraction = 1, maximum_donor_radius_cells = 2L)
  expect_false(result$repair_applied)
  expect_equal(result$repair_count, 0)
  expect_equal(result$unresolved_count, 2)
  expect_true(result$component_records[[1]]$repair_attempted)
  expect_match(result$component_records[[1]]$repair_failure_reason, "no_(valid_donor|source_land_support)")
  expect_equal(sum(as.numeric(result$diagnostics$repaired_cell_ids %||% integer()) > 0), 0)
  expect_equal(result$repair_count, result$missing_inside_count - result$unresolved_count)
})

test_that("failed product results retain date diagnostics and original error fields", {
  process <- list(written = character(), reused = character(), date_results = list(
    list(date = "2026-02-01", status = "failed", output_path = "out.tif", pre_repair_missing_cells = 148L, component_count = 124L, repaired_cells = 0L, post_repair_missing_cells = 148L, outside_mask_cells = 0L, failure_stage = "coverage_repair", failure_message = "no valid donor within radius")),
    processing_failures = list(list(stage = "coverage_repair", condition_class = "simpleError", condition_message = "no valid donor within radius", condition_call = "stop(...)", traceback = "trace")))
  failure <- list(failure_stage = "coverage_repair", failure_message = "no valid donor within radius", condition_class = "simpleError", condition_call = "stop(...)", traceback = "trace")
  result <- cdsdatagrab:::era5land_product_result("era5land_tmean", as.Date("2026-02-01"), process, "failed", failure, "t2m.nc", "t2m")
  expect_equal(result$failed_dates, "2026-02-01")
  expect_equal(result$pre_repair_missing_cells, 148)
  expect_equal(result$post_repair_missing_cells, 148)
  expect_equal(result$failure_stage, "coverage_repair")
  expect_equal(result$failure_message, "no valid donor within radius")
  expect_equal(result$condition_call, "stop(...)")
  expect_equal(result$date_results[[1]]$failure_message, "no valid donor within radius")
})

test_that("donor pools preserve full terra cell numbers and values", {
  skip_if_not_installed("terra")
  template <- terra::rast(nrows = 5, ncols = 5, xmin = 0, xmax = 5, ymin = 0, ymax = 5, crs = "EPSG:4326")
  terra::values(template) <- NA_real_; target <- terra::cellFromRowCol(template, 3, 3); donor <- terra::cellFromRowCol(template, 2, 2); terra::values(template)[c(target, donor)] <- 1
  projected <- template; terra::values(projected) <- NA_real_; terra::values(projected)[donor] <- 42
  pool <- cdsdatagrab:::era5land_donor_pool(projected, template, c(-Inf, Inf))
  expect_identical(pool$cells, as.integer(donor)); expect_identical(pool$values, 42)
  expect_true(donor %in% cdsdatagrab:::era5land_ring_cells(template, target, 1L))
  result <- analyze_template_coverage(projected, projected, template, template, maximum_repair_count = 4L, maximum_repair_fraction = 1, maximum_donor_radius_cells = 1L)
  expect_equal(result$repair_count, 1L); expect_equal(result$details[[1]]$donor_cells, donor); expect_equal(result$details[[1]]$selected_value, 42)
  candidate <- Filter(function(x) identical(x$candidate_cell, as.integer(donor)), result$details[[1]]$candidate_diagnostics)[[1L]]
  expect_equal(candidate$bilinear_value, 42); expect_equal(candidate$nearest_value, 42); expect_true(candidate$candidate_in_bilinear_donor_pool); expect_true(candidate$candidate_in_nearest_donor_pool)
})

test_that("shifted same-size donor rasters cannot reuse template cell numbers", {
  skip_if_not_installed("terra")
  template <- terra::rast(nrows = 4, ncols = 4, xmin = 0, xmax = 4, ymin = 0, ymax = 4, crs = "EPSG:4326")
  shifted <- terra::rast(nrows = 4, ncols = 4, xmin = 0.25, xmax = 4.25, ymin = 0, ymax = 4, crs = "EPSG:4326")
  terra::values(template) <- 1; terra::values(shifted) <- 2
  expect_equal(terra::ncell(template), terra::ncell(shifted))
  expect_false(terra::compareGeom(shifted, template, stopOnError = FALSE))
  expect_error(cdsdatagrab:::era5land_donor_pool(shifted, template, c(-Inf, Inf)), "geometry")
  expect_error(analyze_template_coverage(shifted, shifted, shifted, template, mask_template = FALSE, maximum_repair_count = 4L, maximum_repair_fraction = 1), "geometry")
})

test_that("ERA5-Land donor validation uses processed output units", {
  spec <- get_variable_spec("era5land_tmean")
  expect_equal(spec$source_hard_valid_range, c(150, 380))
  expect_equal(spec$hard_valid_range, c(-100, 70))
  expect_true(cdsdatagrab:::era5land_donor_is_valid(0, spec$hard_valid_range))
  expect_false(cdsdatagrab:::era5land_donor_is_valid(0, spec$source_hard_valid_range))
})

test_that("coverage failure returns diagnostics without masking the original error", {
  skip_if_not_installed("terra")
  skip_if_not_installed("ncdf4")
  base <- file.path(getwd(), ".test-era5land-coverage-failure-scope")
  dir.create(base, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(base, recursive = TRUE, force = TRUE), add = TRUE)
  raw_path <- file.path(base, "tmean.nc")
  lon <- ncdf4::ncdim_def("longitude", "degrees_east", c(10, 11))
  lat <- ncdf4::ncdim_def("latitude", "degrees_north", c(10, 11))
  tm <- ncdf4::ncdim_def("valid_time", "hours since 2026-02-01 00:00:00", c(0, 24))
  variable <- ncdf4::ncvar_def("t2m", "K", list(lon, lat, tm), -9999, prec = "double")
  nc <- ncdf4::nc_create(raw_path, list(variable), force_v4 = TRUE)
  ncdf4::ncvar_put(nc, variable, array(rep(273.15, 8), dim = c(2, 2, 2)))
  ncdf4::nc_close(nc)
  template <- terra::rast(nrows = 1, ncols = 1, xmin = 0, xmax = 1, ymin = 0, ymax = 1, crs = "EPSG:4326")
  terra::values(template) <- 1
  template_path <- file.path(base, "template.tif"); terra::writeRaster(template, template_path, overwrite = TRUE)
  spec <- get_variable_spec("era5land_tmean")
  cfg <- list(project = list(dataset_id = spec$id, profile = "smoke"), spatial = list(mask_to_template = TRUE, mask_to_boundary = FALSE, require_complete_template_coverage = TRUE), processing = list(resampling_method = "bilinear", datatype = "FLT4S", naflag = -9999), validation = list(coverage_max_repair_count = 4L, coverage_max_repair_fraction = 1, coverage_max_component_size = 4L, coverage_max_donor_radius_cells = 1L, coverage_max_source_buffer_km = 35, coverage_donor_count = 8L, hard_tolerance = 1e-6, require_exact_template_geometry = TRUE))
  dates <- as.Date("2026-02-01") + 0:1
  result <- process_downloaded_variable(raw_path, file.path(base, "daily"), template_path, NA_character_, cfg, spec, expected_dates = dates, run_expected_dates = dates, run_dir = file.path(base, "run"))
  expect_length(result$failed, 2L)
  expect_length(result$coverage_diagnostics, 2L)
  expect_true(length(result$coverage_diagnostics[[1]]$details) >= 1L)
  expect_match(result$processing_failures[[1]]$condition_message, "coverage_repair_incomplete")
  expect_match(result$processing_failures[[1]]$condition_message, "1 pre-repair missing")
  expect_false(grepl("repair_failure_reasons=NA", result$processing_failures[[1]]$condition_message, fixed = TRUE))
  expect_false(grepl("object 'coverage_records' not found", result$processing_failures[[1]]$condition_message, fixed = TRUE))
})

test_that("successful daily output records each date result after finalization", {
  skip_if_not_installed("terra")
  skip_if_not_installed("ncdf4")
  base <- file.path(getwd(), ".test-era5land-date-results")
  dir.create(base, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(base, recursive = TRUE, force = TRUE), add = TRUE)
  raw_path <- file.path(base, "tmean.nc")
  lon <- ncdf4::ncdim_def("longitude", "degrees_east", c(0.25, 0.75))
  lat <- ncdf4::ncdim_def("latitude", "degrees_north", c(0.25, 0.75))
  tm <- ncdf4::ncdim_def("valid_time", "hours since 2026-02-01 00:00:00", c(0, 24))
  variable <- ncdf4::ncvar_def("t2m", "K", list(lon, lat, tm), -9999, prec = "double")
  nc <- ncdf4::nc_create(raw_path, list(variable), force_v4 = TRUE)
  ncdf4::ncvar_put(nc, variable, array(273.15, dim = c(2, 2, 2)))
  ncdf4::nc_close(nc)
  template <- terra::rast(nrows = 2, ncols = 2, xmin = 0, xmax = 1, ymin = 0, ymax = 1, crs = "EPSG:4326")
  terra::values(template) <- 1
  template_path <- file.path(base, "template.tif")
  terra::writeRaster(template, template_path, overwrite = TRUE)
  spec <- get_variable_spec("era5land_tmean")
  cfg <- list(
    project = list(dataset_id = spec$id, profile = "smoke"),
    spatial = list(mask_to_template = TRUE, mask_to_boundary = FALSE, require_complete_template_coverage = TRUE),
    processing = list(resampling_method = "bilinear", datatype = "FLT4S", naflag = -9999),
    validation = list(coverage_max_repair_count = 4L, coverage_max_repair_fraction = 1, coverage_max_component_size = 4L, coverage_max_donor_radius_cells = 1L, coverage_max_source_buffer_km = 35, coverage_donor_count = 8L, hard_tolerance = 1e-6, require_exact_template_geometry = TRUE)
  )
  dates <- as.Date("2026-02-01") + 0:1
  result <- process_downloaded_variable(raw_path, file.path(base, "daily"), template_path, NA_character_, cfg, spec, expected_dates = dates, run_expected_dates = dates, run_dir = file.path(base, "run"))
  expect_length(result$failed, 0L)
  expect_length(result$written, 2L)
  expect_length(result$date_results, 2L)
  expect_identical(names(result$date_results), as.character(dates))
  expect_equal(unname(vapply(result$date_results, `[[`, character(1), "status")), c("success", "success"))
  expect_equal(unname(vapply(result$date_results, `[[`, character(1), "date")), as.character(dates))
  expect_true(all(vapply(result$date_results, function(x) file.exists(x$output_path), logical(1))))
  expect_true(all(vapply(result$date_results, function(x) is.list(x$coverage), logical(1))))
  expect_true(all(vapply(result$date_results, function(x) isTRUE(x$output_sha256 != ""), logical(1))))
  expect_length(list.files(file.path(base, "daily"), pattern = "\\.tmp-", full.names = TRUE), 0L)
})

test_that("source footprint fallback uses fine source pixels and records support", {
  skip_if_not_installed("terra")
  template <- terra::rast(nrows = 1, ncols = 1, xmin = 0, xmax = 1, ymin = 0, ymax = 1, crs = "EPSG:4326"); terra::values(template) <- 1
  bilinear <- template; nearest <- template; terra::values(bilinear) <- NA; terra::values(nearest) <- NA
  source <- terra::rast(nrows = 10, ncols = 10, xmin = 0, xmax = 1, ymin = 0, ymax = 1, crs = "EPSG:4326"); terra::values(source) <- NA_real_; terra::values(source)[c(45, 46)] <- c(10, 20)
  result <- analyze_template_coverage(bilinear, nearest, source, template, maximum_repair_count = 4L, maximum_repair_fraction = 1, maximum_donor_radius_cells = 1L, maximum_source_buffer_km = 35)
  expect_true(result$repaired); expect_match(result$details[[1]]$donor_method, "source_footprint"); expect_equal(result$details[[1]]$source_footprint_donor_count, 2L); expect_equal(result$details[[1]]$source_cell_count, 2L); expect_equal(result$details[[1]]$selected_value, 15)
  source_diagnostics <- result$details[[1]]$source_diagnostics
  expect_true(nzchar(source_diagnostics$source_crs)); expect_true(source_diagnostics$intersects_source_extent); expect_gt(source_diagnostics$extracted_rows, 0); expect_equal(source_diagnostics$finite_extracted_rows, 2L)
})

test_that("source fallback fails explicitly without support", {
  skip_if_not_installed("terra")
  template <- terra::rast(nrows = 1, ncols = 1, xmin = 0, xmax = 1, ymin = 0, ymax = 1, crs = "EPSG:4326"); terra::values(template) <- 1
  bilinear <- template; nearest <- template; terra::values(bilinear) <- NA; terra::values(nearest) <- NA
  source <- terra::rast(nrows = 10, ncols = 10, xmin = 0, xmax = 1, ymin = 0, ymax = 1, crs = "EPSG:4326"); terra::values(source) <- NA_real_
  result <- analyze_template_coverage(bilinear, nearest, source, template, maximum_repair_count = 4L, maximum_repair_fraction = 1, maximum_donor_radius_cells = 1L, maximum_source_buffer_km = 35)
  expect_false(result$repaired); expect_equal(result$unresolved_count, 1L); expect_equal(result$component_records[[1]]$repair_failure_reason, "no_source_land_support"); expect_true(result$component_records[[1]]$repair_eligible); expect_true(result$component_records[[1]]$repair_attempted)
})

test_that("source buffer is bounded and does not use distant target-grid donors", {
  skip_if_not_installed("terra")
  template <- terra::rast(nrows = 1, ncols = 1, xmin = 0, xmax = 0.1, ymin = 0, ymax = 0.1, crs = "EPSG:4326"); terra::values(template) <- 1
  bilinear <- template; nearest <- template; terra::values(bilinear) <- NA; terra::values(nearest) <- NA
  source <- terra::rast(nrows = 50, ncols = 50, xmin = -0.2, xmax = 0.3, ymin = -0.2, ymax = 0.3, crs = "EPSG:4326"); terra::values(source) <- NA_real_; terra::values(source)[terra::cellFromRowCol(source, 25, 31)] <- 30
  result <- analyze_template_coverage(bilinear, nearest, source, template, maximum_repair_count = 4L, maximum_repair_fraction = 1, maximum_donor_radius_cells = 1L, maximum_source_buffer_km = 35)
  expect_true(result$repaired); expect_equal(result$details[[1]]$donor_method, "source_buffer_nearest"); expect_lte(result$details[[1]]$maximum_source_distance_km, 35); expect_equal(result$details[[1]]$source_buffer_donor_count, 1L)
})

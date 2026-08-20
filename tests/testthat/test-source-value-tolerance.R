test_that("finite source hard bounds tolerate only numerical noise", {
  tolerance <- cdsdatagrab:::.source_validation_tolerance
  spec <- get_variable_spec("era5land_soilwater_l1_mean")
  expect_identical(spec$source_hard_valid_range, c(0, 1))
  expect_identical(tolerance, 1e-10)

  exact <- validate_source_values(c(0, 1), spec)
  expect_identical(exact$values, c(0, 1))
  expect_identical(c(exact$source_minimum, exact$source_maximum), c(0, 1))
  expect_identical(c(exact$source_lower_clamped_count, exact$source_upper_clamped_count), c(0L, 0L))

  observed <- validate_source_values(c(-1.151656e-20, 0.7469794), spec)
  expect_identical(observed$values, c(0, 0.7469794))
  expect_identical(observed$source_raw_minimum, -1.151656e-20)
  expect_identical(observed$source_minimum, 0)
  expect_identical(observed$source_lower_clamped_count, 1L)

  just_inside_lower <- validate_source_values(c(-0.99 * tolerance, 0.25), spec)
  expect_identical(just_inside_lower$values, c(0, 0.25))
  expect_error(validate_source_values(c(-1.01 * tolerance, 0.25), spec), "outside sanity range")

  just_inside_upper <- validate_source_values(c(0.25, 1 + 1e-12), spec)
  expect_identical(just_inside_upper$values, c(0.25, 1))
  expect_identical(just_inside_upper$source_maximum, 1)
  expect_identical(just_inside_upper$source_upper_clamped_count, 1L)
  expect_error(validate_source_values(c(0.25, 1.001), spec), "outside sanity range")

  normal <- c(0.02, 0.3, 0.75)
  expect_identical(validate_source_values(normal, spec)$values, normal)
})

test_that("source tolerance does not weaken temperature or pressure ranges", {
  temperature <- get_variable_spec("era5land_tmean")
  pressure <- get_variable_spec("era5land_surface_pressure_mean")
  expect_error(validate_source_values(c(149.99, 273.15), temperature), "outside sanity range")
  expect_error(validate_source_values(c(273.15, 380.01), temperature), "outside sanity range")
  expect_error(validate_source_values(c(19999.99, 100000), pressure), "outside sanity range")
  expect_error(validate_source_values(c(100000, 115000.01), pressure), "outside sanity range")
})

test_that("observed SW1 source noise is clamped before raster construction", {
  skip_if_not_installed("ncdf4")
  skip_if_not_installed("terra")
  root <- test_external_root("era5land-sw1-source-tolerance")
  dir.create(root, recursive = TRUE)
  path <- file.path(root, "volumetric_soil_water_layer_1_0_daily-mean.nc")
  lon <- ncdf4::ncdim_def("longitude", "degrees_east", c(-126.1, -126.0))
  lat <- ncdf4::ncdim_def("latitude", "degrees_north", c(42.9, 42.8))
  time <- ncdf4::ncdim_def("valid_time", "days since 2022-03-01 00:00:00", 0:1, calendar = "standard")
  variable <- ncdf4::ncvar_def("swvl1", "m**3 m**-3", list(lon, lat, time), -9999, prec = "double")
  nc <- ncdf4::nc_create(path, list(variable), force_v4 = TRUE)
  values <- array(c(-1.151656e-20, 0.2, 0.4, 0.7469794, 0.1, 0.3, 0.5, 0.7), dim = c(2, 2, 2))
  ncdf4::ncvar_put(nc, variable, values)
  ncdf4::nc_close(nc)

  dates <- as.Date("2022-03-01") + 0:1
  result <- read_daily_netcdf(path, get_variable_spec("era5land_soilwater_l1_mean"), dates, dates)
  expect_equal(result$source_value_raw_minimum, -1.151656e-20, tolerance = 1e-30)
  expect_identical(result$source_value_minimum, 0)
  expect_identical(result$source_lower_clamped_count, 1L)
  expect_identical(result$source_validation_tolerance, 1e-10)
  expect_identical(min(terra::values(result$rasters[[1]], mat = FALSE), na.rm = TRUE), 0)
  expect_equal(result$source_value_maximum, 0.7469794)
})

make_lai_netcdf_fixture <- function(path, dates=as.Date("2025-06-04") + 0:4) {
  lon <- ncdf4::ncdim_def("longitude", "degrees_east", c(-126, -125.75))
  lat <- ncdf4::ncdim_def("latitude", "degrees_north", c(42.7, 42.95))
  tm <- ncdf4::ncdim_def("valid_time", "hours since 2025-06-04 00:00:00", 24 * 0:(length(dates) - 1L))
  v <- ncdf4::ncvar_def("lai_lv", "1", list(lon, lat, tm), -9999, prec="double")
  nc <- ncdf4::nc_create(path, list(v), force_v4=TRUE)
  ncdf4::ncvar_put(nc, v, array(seq_len(length(dates)), dim=c(2, 2, length(dates))))
  ncdf4::nc_close(nc)
  path
}

test_that("LAI .netcdf is activated through ncdf4 and maps all requested dates", {
  skip_if_not_installed("ncdf4")
  skip_if_not_installed("terra")
  base <- test_external_root("lai-netcdf-activation")
  raw <- file.path(base, "raw"); dir.create(raw, recursive=TRUE)
  dates <- as.Date("2025-06-04") + 0:4
  target <- file.path(raw, "era5_lai_low_daily_2025-06_22662248.netcdf")
  make_lai_netcdf_fixture(target, dates)
  req <- list(target=basename(target), variable="leaf_area_index_low_vegetation", year="2025", month="06", day=sprintf("%02d", 4:8), request_hash="22662248")
  checked <- validate_downloaded_target(target, req)
  expect_true(checked$valid)
  expect_true(checked$container_readable)
  expect_true(checked$ncdf4_metadata_readable)
  expect_false(checked$gdal_metadata_readable)
  expect_equal(checked$selected_reader, "ncdf4")
  expect_true(checked$selected_reader_metadata_readable)
  expect_true(checked$scientific_variable_present)
  expect_true(checked$time_coordinate_readable)
  expect_true(checked$decoded_dates_valid)
  active <- select_active_raw_inputs(list(req), NULL, target)
  expect_equal(active$active, target)
  map <- map_dates_to_active_raw_sources(active$active, list(req))
  expect_equal(map$date, format(dates, "%Y-%m-%d"))
  expect_equal(map$source_path, rep(target, 5))

  spec <- get_variable_spec("era5_lai_low")
  template <- terra::rast(nrows=2, ncols=2, xmin=-126.125, xmax=-125.625, ymin=42.575, ymax=43.075, crs="EPSG:4326")
  terra::values(template) <- 1
  template_path <- file.path(base, "template.tif"); terra::writeRaster(template, template_path, overwrite=TRUE)
  cfg <- list(project=list(dataset_id=spec$id, profile="smoke"), spatial=list(mask_to_template=TRUE, mask_to_boundary=FALSE, require_complete_template_coverage=TRUE), processing=list(resampling_method="bilinear", datatype="FLT4S", naflag=-9999), validation=list(physical_minimum=0, physical_maximum=20, clamp_tolerance=.01, hard_tolerance=1e-6, require_exact_template_geometry=TRUE))
  result <- process_downloaded_variable(target, file.path(base, "daily"), template_path, NA_character_, cfg, spec, expected_dates=dates, run_expected_dates=dates, request_manifest=list(req), date_source_map=map, run_dir=file.path(base, "run"))
  expect_length(result$written, 5)
  expect_length(result$failed, 0)
  expect_equal(sort(basename(result$written)), paste0("lai_low_", format(dates, "%Y-%m-%d"), ".tif"))
})

test_that("LAI process rejects a false no-op when required dates are unmapped", {
  base <- test_external_root("lai-false-noop")
  expect_error(
    run_era5_mintemp_pipeline(package_file("config", "era5_lai_low_weekly_smoke.yml"), mode="process", dry_run=FALSE, output_root=base),
    "required_dates_unmapped|no_active_raw_source_for_required_dates"
  )
})

test_that("same-run LAI .netcdf promotion is selected without a CDS call", {
  skip_if_not_installed("ncdf4")
  base <- test_external_root("lai-same-run-download")
  paths <- resolve_storage_paths(list(project=list(profile="smoke", dataset_id="era5_lai_low"), paths=list(root=NULL)), package_root(), base, create=TRUE)
  dates <- as.Date("2025-06-04") + 0:4
  req <- list(dataset_short_name="reanalysis-era5-single-levels", product_type="reanalysis", variable="leaf_area_index_low_vegetation", daily_statistic="instantaneous_00_utc", time_zone="utc+00:00", time="00:00", frequency="monthly", data_format="netcdf", download_format="unarchived", area=c(43, -127, 42, -125), year="2025", month="06", day=sprintf("%02d", 4:8), request_hash="22662248", target="era5_lai_low_daily_2025-06_22662248.netcdf")
  out <- download_cds_requests(list(req), paths=paths, dry_run=FALSE, transfer_fun=function(dataset, payload, target) make_lai_netcdf_fixture(target, dates))
  expect_equal(out$status, "downloaded")
  expected_raw <- file.path(paths$raw_dir, sub("[.]netcdf$", ".nc", req$target))
  expect_true(file.exists(expected_raw))
  selected <- select_active_raw_inputs(list(req), out, list.files(paths$raw_dir, full.names=TRUE))
  expect_equal(selected$active, expected_raw)
  expect_equal(map_dates_to_active_raw_sources(selected$active, list(req))$date, format(dates, "%Y-%m-%d"))
})

local_era5land_test_dir <- function(label) {
  path <- tempfile(paste0("era5land-archive-", label, "-"), tmpdir = package_root())
  dir.create(path, recursive = TRUE); withr::defer(unlink(path, recursive = TRUE, force = TRUE), envir = testthat::teardown_env()); path
}

test_that("container detection uses magic bytes and ignores misleading extensions", {
  skip_if_not_installed("ncdf4")
  base <- local_era5land_test_dir("containers"); zip_path <- file.path(base, "archive.zip")
  source(package_file("tests", "fixtures", "make_era5land_zip_fixture.R")); make_era5land_zip_fixture(zip_path)
  expect_identical(detect_container_type(zip_path), "zip")
  mislabeled <- file.path(base, "archive.nc"); file.copy(zip_path, mislabeled); expect_identical(detect_container_type(mislabeled), "zip")
  extensionless <- file.path(base, "archive"); file.copy(zip_path, extensionless); expect_identical(detect_container_type(extensionless), "zip")
  classic <- file.path(base, "classic.nc"); lon <- ncdf4::ncdim_def("longitude", "degrees_east", -1); lat <- ncdf4::ncdim_def("latitude", "degrees_north", 1); tm <- ncdf4::ncdim_def("valid_time", "days since 2026-02-01 00:00:00", 0:2, calendar = "proleptic_gregorian"); v <- ncdf4::ncvar_def("t2m", "K", list(lon, lat, tm), -9999, prec = "double"); nc <- ncdf4::nc_create(classic, list(v), force_v4 = FALSE); ncdf4::ncvar_put(nc, v, array(273.15, c(1, 1, 3))); ncdf4::nc_close(nc); expect_identical(detect_container_type(classic), "netcdf_classic")
  unknown <- file.path(base, "unknown.bin"); writeBin(as.raw(c(1, 2, 3, 4, 5)), unknown); expect_identical(detect_container_type(unknown), "unknown")
})

test_that("confirmed ERA5-Land archive extracts eight members and maps 24 product dates", {
  skip_if_not_installed("ncdf4"); skip_if_not_installed("terra")
  base <- local_era5land_test_dir("mapping"); archive <- file.path(base, "monthly.zip"); source(package_file("tests", "fixtures", "make_era5land_zip_fixture.R")); make_era5land_zip_fixture(archive)
  inventory <- era5land_extract_archive(archive, file.path(base, "extracted"), "016f79fb", as.Date("2026-02-01") + 0:2, file.path(base, "run"))
  expect_length(inventory$product_id, 8); expect_equal(nrow(attr(inventory, "source_map")), 24); expect_false("number" %in% inventory$environmental_variable_alias)
  expect_setequal(inventory$environmental_variable_alias, c("t2m", "stl1", "stl2", "swvl1", "swvl2", "sp", "lai_hv", "lai_lv"))
  expect_true(all(grepl("2026-02-01;2026-02-02;2026-02-03", inventory$decoded_dates, fixed = TRUE)))
  expect_true(all(inventory$dimension_names == "longitude;latitude;valid_time"))
  for (id in era5land_family_product_ids()) {
    member <- era5land_member_for_product(inventory, id); x <- read_daily_netcdf(member$extracted_path, get_variable_spec(id), as.Date("2026-02-01") + 0:2, as.Date("2026-02-01") + 0:2)
    expect_equal(as.character(x$dates), as.character(as.Date("2026-02-01") + 0:2)); expect_length(x$rasters, 3L); expect_identical(x$time_coordinate_name, "valid_time")
  }
  expect_true(isTRUE(attr(era5land_extract_archive(archive, file.path(base, "extracted"), "016f79fb", as.Date("2026-02-01") + 0:2), "extraction_reused")))
})

test_that("ERA5-Land extraction handles coordinate direction and CF valid_time without shifting labels", {
  skip_if_not_installed("ncdf4"); skip_if_not_installed("terra")
  base <- local_era5land_test_dir("orientation"); source(package_file("tests", "fixtures", "make_era5land_zip_fixture.R")); archive <- file.path(base, "reversed.zip"); make_era5land_zip_fixture(archive, reverse_latitude = TRUE, reverse_longitude = TRUE)
  inv <- era5land_extract_archive(archive, file.path(base, "extracted"), "reversed", as.Date("2026-02-01") + 0:2); member <- era5land_member_for_product(inv, "era5land_tmean"); x <- read_daily_netcdf(member$extracted_path, get_variable_spec("era5land_tmean"), as.Date("2026-02-01") + 0:2)
  expect_equal(as.character(x$decoded_dates), as.character(as.Date("2026-02-01") + 0:2)); expect_true(x$latitude_direction %in% c("ascending", "descending")); expect_true(x$longitude_direction %in% c("ascending", "descending")); expect_true(all(is.finite(terra::values(x$rasters[[1]], mat = FALSE)), na.rm = TRUE))
})

test_that("mislabeled ZIPs and partial files are safely normalized and reused", {
  skip_if_not_installed("ncdf4")
  base <- local_era5land_test_dir("reuse"); raw <- file.path(base, "data", "smoke", "_sources", "era5land_daily_mean_utc06", "raw"); dir.create(raw, recursive = TRUE); partial <- file.path(raw, ".partial"); dir.create(partial); marker <- file.path(base, ".cds-datagrab-root"); jsonlite::write_json(list(application = "cds-datagrab"), marker, auto_unbox = TRUE)
  paths <- list(root = base, root_marker = marker, raw_dir = raw, dataset_root = dirname(raw), raw_quarantine_dir = file.path(dirname(raw), "quarantine", "raw"), runs_root = file.path(base, "runs"), pipeline_log_dir = file.path(base, "logs"), slurm_log_dir = file.path(base, "logs"))
  archive <- file.path(base, "archive.zip"); source(package_file("tests", "fixtures", "make_era5land_zip_fixture.R")); make_era5land_zip_fixture(archive); req <- list(target = "era5land_daily_mean_utc06_2026-02_016f79fb.nc", request_hash = "016f79fb")
  mislabeled <- file.path(raw, req$target); file.copy(archive, mislabeled); z <- finalize_raw_artifact(mislabeled, req, paths); expect_identical(detect_container_type(z$final_raw_path), "zip"); expect_true(file.exists(file.path(raw, "era5land_daily_mean_utc06_2026-02_016f79fb.zip"))); expect_false(file.exists(mislabeled)); expect_false(z$extension_content_match)
  identical_partial <- file.path(partial, "ecmwfr_identical.zip"); different_partial <- file.path(partial, "ecmwfr_different.zip"); file.copy(z$final_raw_path, identical_partial); writeBin(as.raw(c(1, 2, 3)), different_partial); z2 <- finalize_raw_artifact(z$final_raw_path, req, paths, partial_candidates = c(identical_partial, different_partial)); expect_false(file.exists(identical_partial)); expect_true(file.exists(different_partial)); expect_true("different_partial_retained" %in% z2$partial_status)
  unlink(z$final_raw_path); partial_only <- file.path(partial, "ecmwfr_partial.zip"); file.copy(archive, partial_only); z3 <- finalize_raw_artifact(partial_only, req, paths, partial_candidates = partial_only); expect_true(file.exists(z3$final_raw_path)); expect_identical(detect_container_type(z3$final_raw_path), "zip")
  expect_length(find_reusable_raw_artifact(req, paths)$candidates, 1L)
  cfg <- read_pipeline_config(package_file("config", "era5land_daily_mean_utc06_smoke.yml")); family_req <- build_era5land_daily_mean_requests(as.Date("2026-02-01") + 0:2, c(43, -127, 42, -125), cfg)[[1L]]; family_req$target <- req$target; family_req$request_hash <- req$request_hash; reused <- download_cds_requests(list(family_req), paths = paths, dry_run = FALSE, transfer_fun = function(...) stop("CDS transfer should not be called for cached archive")); expect_identical(reused$status[[1L]], "reused_existing"); expect_identical(reused$detected_container[[1L]], "zip"); expect_true(isTRUE(reused$raw_reused[[1L]]))
})

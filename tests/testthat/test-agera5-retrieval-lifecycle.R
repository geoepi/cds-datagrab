make_agera5_lifecycle_member <- function(path, date, value=50) {
  lon <- ncdf4::ncdim_def("lon", "degrees_east", c(-126, -125.9))
  lat <- ncdf4::ncdim_def("lat", "degrees_north", c(42.8, 42.7))
  tm <- ncdf4::ncdim_def("time", "days since 1900-01-01 00:00:00", as.numeric(as.Date(date) - as.Date("1900-01-01")))
  v <- ncdf4::ncvar_def("Derived_Relative_Humidity_2m_Min_24h", "%", list(lon, lat, tm), -9999, prec="double")
  nc <- ncdf4::nc_create(path, list(v), force_v4=TRUE)
  ncdf4::ncvar_put(nc, v, array(value, dim=c(2, 2, 1)))
  ncdf4::nc_close(nc)
  path
}

make_agera5_lifecycle_zip <- function(path, dates, source_dir) {
  dir.create(source_dir, recursive=TRUE, showWarnings=FALSE)
  dir.create(dirname(path), recursive=TRUE, showWarnings=FALSE)
  members <- vapply(as.Date(dates), function(d) {
    make_agera5_lifecycle_member(file.path(source_dir, paste0("rh_", format(d, "%Y%m%d"), ".nc")), d)
  }, character(1))
  old <- getwd(); setwd(source_dir); on.exit(setwd(old), add=TRUE)
  utils::zip(path, basename(members), flags="-q")
  setwd(old)
  path
}

make_agera5_lifecycle_request <- function(dates, cfg) {
  build_variable_requests(as.Date(dates), c(43, -127, 42, -125), cfg, get_variable_spec("agera5_relhum_min"))[[1L]]
}

test_that("AgERA5 promotes and reuses a completed partial-month archive", {
  skip_if_not_installed("ncdf4")
  base <- test_external_root("agera5-retrieval-lifecycle")
  cfg <- read_pipeline_config(package_file("config", "agera5_relhum_min_smoke.yml"))
  paths <- resolve_storage_paths(cfg, package_root(), base, create=TRUE)
  requested <- as.Date("2026-07-13") + 0:13
  req <- make_agera5_lifecycle_request(requested, cfg)
  old_dates <- as.Date("2026-07-01") + 0:11
  old_zip <- file.path(paths$raw_dir, "agera5_relhum_min_daily_2026-07-oldhash.zip")
  make_agera5_lifecycle_zip(old_zip, old_dates, file.path(base, "old-members"))
  staged <- file.path(paths$raw_dir, ".partial", "ecmwfr_84b164eb71a9a.zip")
  make_agera5_lifecycle_zip(staged, requested, file.path(base, "new-members"))

  out <- download_cds_requests(list(req), paths=paths, dry_run=FALSE,
    transfer_fun=function(...) stop("completed staged download should be reused"))
  final <- file.path(paths$raw_dir, sub("\\.(nc|netcdf)$", ".zip", req$target, ignore.case=TRUE))
  expect_identical(out$status[[1]], "reused_existing")
  expect_true(out$valid[[1]])
  expect_true(file.exists(final))
  expect_false(file.exists(staged))
  expect_true(file.exists(old_zip))

  manifest <- utils::read.csv(file.path(paths$extracted_dir, req$request_hash, "archive_manifest.csv"), stringsAsFactors=FALSE)
  expect_equal(nrow(manifest), 14)
  expect_equal(sort(manifest$date_from_filename), format(requested, "%Y-%m-%d"))
  active <- select_active_raw_inputs(list(req), out, list.files(paths$raw_dir, full.names=TRUE))
  expect_identical(active$active, final)
  mapped <- map_dates_to_active_raw_sources(active$active, list(req))
  expect_equal(mapped$date, format(requested, "%Y-%m-%d"))
  expect_false(any(as.Date(mapped$date) < min(requested) | as.Date(mapped$date) > max(requested)))
})

test_that("AgERA5 fresh retrieval is promoted and a post-download rerun does not re-request CDS", {
  skip_if_not_installed("ncdf4")
  base <- test_external_root("agera5-retrieval-rerun")
  cfg <- read_pipeline_config(package_file("config", "agera5_relhum_min_smoke.yml"))
  paths <- resolve_storage_paths(cfg, package_root(), base, create=TRUE)
  requested <- as.Date("2026-07-13") + 0:13
  req <- make_agera5_lifecycle_request(requested, cfg)
  response <- file.path(base, "response.zip")
  make_agera5_lifecycle_zip(response, requested, file.path(base, "members"))
  calls <- 0L
  transfer <- function(dataset, payload, target) {
    calls <<- calls + 1L
    returned <- file.path(dirname(target), "ecmwfr_84b164eb71a9a.zip")
    file.copy(response, returned, overwrite=TRUE)
    returned
  }
  first <- download_cds_requests(list(req), paths=paths, dry_run=FALSE, transfer_fun=transfer)
  expect_identical(first$status[[1]], "downloaded")
  expect_equal(calls, 1L)
  expect_true(file.exists(first$resolved_target_path[[1]]))
  expect_true(file.exists(file.path(paths$extracted_dir, req$request_hash, "archive_manifest.csv")))
  second <- download_cds_requests(list(req), paths=paths, dry_run=FALSE,
    transfer_fun=function(...) stop("CDS must not be requested on rerun"))
  expect_identical(second$status[[1]], "reused_existing")
  expect_true(second$valid[[1]])
})

test_that("AgERA5 archive coverage checks handle one-day, partial-month, and month-boundary requests", {
  skip_if_not_installed("ncdf4")
  base <- test_external_root("agera5-request-windows")
  cfg <- read_pipeline_config(package_file("config", "agera5_relhum_min_smoke.yml"))
  one_day <- as.Date("2026-07-13")
  partial_month <- as.Date("2026-07-13") + 0:13
  boundary <- as.Date("2026-07-30") + 0:3
  for (dates in list(one_day, partial_month)) {
    zip <- file.path(base, paste0("response-", format(min(dates), "%Y%m%d"), ".zip"))
    make_agera5_lifecycle_zip(zip, dates, file.path(base, paste0("members-", format(min(dates), "%Y%m%d"))))
    req <- make_agera5_lifecycle_request(dates, cfg)
    expect_true(agera5_archive_matches_request(zip, req))
    expect_equal(agera5_request_dates(req), dates)
  }
  boundary_requests <- build_variable_requests(boundary, c(43, -127, 42, -125), cfg, get_variable_spec("agera5_relhum_min"))
  expect_length(boundary_requests, 2L)
  for (req in boundary_requests) {
    dates <- as.Date(req$raw_request_dates)
    zip <- file.path(base, paste0("response-", format(min(dates), "%Y%m%d"), ".zip"))
    make_agera5_lifecycle_zip(zip, dates, file.path(base, paste0("members-", format(min(dates), "%Y%m%d"))))
    expect_true(agera5_archive_matches_request(zip, req))
  }
})

test_that("AgERA5 invalid or incomplete partial files never become active candidates", {
  skip_if_not_installed("ncdf4")
  base <- test_external_root("agera5-invalid-partial")
  cfg <- read_pipeline_config(package_file("config", "agera5_relhum_min_smoke.yml"))
  paths <- resolve_storage_paths(cfg, package_root(), base, create=TRUE)
  requested <- as.Date("2026-07-13") + 0:13
  req <- make_agera5_lifecycle_request(requested, cfg)
  invalid <- file.path(paths$raw_dir, ".partial", "ecmwfr-invalid.zip")
  dir.create(dirname(invalid), recursive=TRUE, showWarnings=FALSE)
  writeBin(as.raw(c(1, 2, 3, 4)), invalid)
  partial <- file.path(paths$raw_dir, ".partial", "ecmwfr-incomplete.zip")
  make_agera5_lifecycle_zip(partial, requested[-14], file.path(base, "incomplete-members"))
  expect_false(agera5_archive_matches_request(invalid, req))
  expect_false(agera5_archive_matches_request(partial, req))
  expect_length(agera5_archive_candidates(req, paths), 0L)
  expect_true(file.exists(invalid))
  expect_true(file.exists(partial))
  expect_length(select_active_raw_inputs(list(req), NULL, list.files(paths$raw_dir, full.names=TRUE))$active, 0L)
})

test_that("ERA5-Land family registry is distinct and complete", {
  ids <- era5land_family_product_ids(); expect_length(ids, 8); expect_equal(ids, c("era5land_tmean","era5land_soiltemp_l1_mean","era5land_soiltemp_l2_mean","era5land_soilwater_l1_mean","era5land_soilwater_l2_mean","era5land_surface_pressure_mean","era5land_lai_high_mean","era5land_lai_low_mean"))
  specs <- lapply(ids, get_variable_spec); expect_true(all(vapply(specs, function(x) identical(x$source_family_id,"era5land_daily_mean_utc06"), logical(1)))); expect_true(all(vapply(specs, function(x) identical(x$daily_statistic,"daily_mean"), logical(1)))); expect_true(all(vapply(specs, function(x) identical(x$time_zone,"utc-06:00"), logical(1)))); expect_true(all(vapply(specs, function(x) identical(x$frequency,"1_hourly"), logical(1))))
  expect_equal(get_variable_spec("era5land_surface_pressure_mean")$unit_conversion,"pascal_to_kilopascal"); expect_equal(get_variable_spec("era5land_lai_low_mean")$hard_valid_range,c(0,20)); expect_match(get_variable_spec("era5land_lai_high_mean")$metadata_notes,"climatology")
})

test_that("ERA5-Land planning creates one multi-variable request per month", {
  cfg <- read_pipeline_config(package_file("config","era5land_daily_mean_utc06_production.yml")); q <- build_era5land_daily_mean_requests(as.Date(c("2025-01-01","2025-01-02","2025-02-01")), c(43,-127,42,-125), cfg); expect_length(q,2); expect_true(all(vapply(q, function(x) length(x$variable)==8L, logical(1)))); expect_true(all(vapply(q, function(x) identical(x$requested_variables,x$variable), logical(1)))); expect_true(all(vapply(q, function(x) identical(x$data_format,"netcdf") && identical(x$download_format,"unarchived"), logical(1)))); expect_false(identical(q[[1]]$request_hash,q[[2]]$request_hash)); expect_match(q[[1]]$target,"era5land_daily_mean_utc06_2025-01")
  year <- build_era5land_daily_mean_requests(seq.Date(as.Date("2025-01-01"),as.Date("2025-12-31"),by="day"),c(43,-127,42,-125),cfg); expect_length(year,12)
  expect_error(build_era5land_daily_mean_requests(as.Date("2025-01-01"), c(43,-127,42,-125), cfg, variable_ids="era5land_tmean"), "all eight")
})

test_that("ERA5-Land API payload and unit conversions are explicit", {
  cfg <- read_pipeline_config(package_file("config","era5land_daily_mean_utc06_smoke.yml")); q <- build_era5land_daily_mean_requests(as.Date(c("2026-02-01","2026-02-02","2026-02-03")),c(43,-127,42,-125),cfg)[[1]]; p <- build_cds_api_payload(q); expect_equal(p$variable,q$variable); expect_equal(p[c("daily_statistic","time_zone","frequency","data_format","download_format")],list(daily_statistic="daily_mean",time_zone="utc-06:00",frequency="1_hourly",data_format="netcdf",download_format="unarchived")); expect_equal(as.numeric(convert_source_units(273.15,get_variable_spec("era5land_tmean"),"K")),0); expect_equal(as.numeric(convert_source_units(100000,get_variable_spec("era5land_surface_pressure_mean"),"Pa")),100); expect_equal(as.numeric(convert_source_units(.4,get_variable_spec("era5land_soilwater_l1_mean"),"m3 m-3")),.4)
})

test_that("ERA5-Land source storage is shared and product paths remain isolated", {
  cfg <- read_pipeline_config(package_file("config","era5land_daily_mean_utc06_smoke.yml")); root <- test_external_root("era5land-source"); s <- resolve_source_storage_paths(cfg,package_root(),root); expect_match(s$source_root,"data/smoke/_sources/era5land_daily_mean_utc06",fixed=TRUE); a <- resolve_storage_paths(list(project=list(profile="smoke",dataset_id="era5land_tmean"),paths=list(root=NULL)),package_root(),root); b <- resolve_storage_paths(list(project=list(profile="smoke",dataset_id="era5land_lai_low_mean"),paths=list(root=NULL)),package_root(),root); expect_false(identical(a$dataset_root,b$dataset_root)); expect_identical(a$root,b$root)
})

test_that("shared fixture contains and reads all eight NetCDF variables", {
  skip_if_not_installed("ncdf4"); skip_if_not_installed("terra"); source(package_file("tests","fixtures","make_era5land_family_fixture.R")); path <- file.path(test_external_root("era5land-fixture"),"bundle.nc"); dir.create(dirname(path),recursive=TRUE); make_era5land_family_fixture(path); md <- inspect_netcdf_ncdf4(path); expect_true(all(c("t2m","stl1","stl2","swvl1","swvl2","sp","lai_hv","lai_lv") %in% names(md$variables))); dates <- as.Date(c("2026-02-01","2026-02-02","2026-02-03")); for (id in era5land_family_product_ids()) { x <- read_daily_netcdf(path,get_variable_spec(id),dates,dates); expect_equal(as.character(x$dates),as.character(dates)); expect_length(x$rasters,3); expect_identical(x$reader_used,"ncdf4") }
})

test_that("ERA5-Land valid_time singleton dimensions remain readable for all products", {
  skip_if_not_installed("ncdf4"); skip_if_not_installed("terra")
  source(package_file("tests", "fixtures", "make_era5land_family_fixture.R"))
  path <- file.path(test_external_root("era5land-singleton-valid-time"), "bundle.nc")
  dir.create(dirname(path), recursive = TRUE)
  date <- as.Date("2026-07-26")
  make_era5land_family_fixture(path, dates = date, time_name = "valid_time")
  metadata <- inspect_netcdf_ncdf4(path)
  expect_identical(metadata$time_coordinate_name, "valid_time")
  expect_equal(as.character(metadata$decoded_dates), "2026-07-26")
  wrapped <- read_era5_daily_layers(path, expected_dates = date,
    variable_spec = get_variable_spec("era5land_tmean"))
  expect_identical(wrapped$time_coordinate_name, "valid_time")
  expect_length(wrapped$rasters, 1L)
  master_template <- terra::rast(nrows = 2, ncols = 2, xmin = -126.75, xmax = -125.75,
    ymin = 42.25, ymax = 43.25, crs = "EPSG:4326")
  for (id in era5land_family_product_ids()) {
    result <- read_daily_netcdf(path, get_variable_spec(id), date, date)
    expect_identical(result$time_coordinate_name, "valid_time")
    expect_equal(result$dimension_lengths, c(2, 2, 1))
    expect_length(result$rasters, 1L)
    expect_equal(c(terra::nrow(result$rasters[[1]]), terra::ncol(result$rasters[[1]])), c(2, 2))
    expect_true(terra::compareGeom(result$rasters[[1]], master_template, stopOnError = FALSE))
  }
})

test_that("NetCDF time aliases are resolved consistently and unsupported dimensions fail", {
  skip_if_not_installed("ncdf4"); skip_if_not_installed("terra")
  source(package_file("tests", "fixtures", "make_era5land_family_fixture.R"))
  base <- test_external_root("era5land-time-aliases")
  dir.create(base, recursive = TRUE)
  time_path <- file.path(base, "time.nc")
  valid_time_path <- file.path(base, "valid_time.nc")
  malformed_path <- file.path(base, "malformed.nc")
  make_era5land_family_fixture(time_path, dates = as.Date("2026-07-26") + 0:1, time_name = "time")
  make_era5land_family_fixture(valid_time_path, dates = as.Date("2026-07-26") + 0:1, time_name = "valid_time")
  make_era5land_family_fixture(malformed_path, dates = as.Date("2026-07-26") + 0:1, time_name = "forecast_time")
  dates <- as.Date("2026-07-26") + 0:1
  expect_identical(read_daily_netcdf(time_path, get_variable_spec("era5land_tmean"), dates, dates)$time_coordinate_name, "time")
  expect_identical(read_daily_netcdf(valid_time_path, get_variable_spec("era5land_tmean"), dates, dates)$time_coordinate_name, "valid_time")
  expect_error(read_daily_netcdf(malformed_path, get_variable_spec("era5land_tmean"), dates, dates), "longitude, latitude, and time dimensions")
  expect_error(resolve_netcdf_coordinate_dimensions(c("longitude", "latitude", "forecast_time")), "longitude, latitude, and time dimensions")
})

make_era5land_multimonth_test_archive <- function(path) {
  member_dir <- tempfile("era5land-month-cache-members-", tmpdir = dirname(path))
  dir.create(member_dir, recursive = TRUE)
  members <- paste0("member-", seq_len(8L), ".nc")
  for (member in members) writeLines("fixture", file.path(member_dir, member))
  old_wd <- getwd()
  on.exit({
    setwd(old_wd)
    unlink(member_dir, recursive = TRUE, force = TRUE)
  }, add = TRUE)
  setwd(member_dir)
  utils::zip(fs::path_abs(path), members, flags = "-q")
  invisible(path)
}

make_era5land_multimonth_test_config <- function(dates) {
  config_dir <- tempfile("era5land-month-boundary-config-", tmpdir = package_root())
  dir.create(config_dir, recursive = TRUE)
  withr::defer(unlink(config_dir, recursive = TRUE, force = TRUE),
    envir = testthat::teardown_env())
  cfg <- read_pipeline_config(package_file("config", "era5land_daily_mean_utc06_smoke.yml"))
  cfg$spatial$template_path <- package_file("spatial_domain", "study_area_raster.tif")
  cfg$spatial$bbox_path <- package_file("spatial_domain", "study_bbox.gpkg")
  cfg$temporal$initial_start_date <- as.character(min(dates))
  cfg$temporal$observed_end <- as.character(max(dates))
  cfg$temporal$configured_start_date <- as.character(min(dates))
  cfg$temporal$configured_end_date <- as.character(max(dates))
  cfg$temporal$future_end_date <- as.character(max(dates))
  config_path <- file.path(config_dir, "config.yml")
  yaml::write_yaml(cfg, config_path)
  list(path = config_path, config = cfg)
}

test_that("full mode processes every month across a boundary with partial caches", {
  dates <- as.Date("2026-10-30") + 0:3
  fixture <- make_era5land_multimonth_test_config(dates)
  root <- test_external_root("era5land-multimonth-partial-cache")
  cfg <- fixture$config
  spatial <- diagnose_spatial_domain(cfg$spatial$template_path, cfg$spatial$bbox_path, cfg)
  requests <- build_era5land_daily_mean_requests(dates, spatial$final_cds_area, cfg)
  expect_length(requests, 2L)
  expect_identical(lapply(requests, function(x) as.character(x$raw_request_dates)),
    list(as.character(dates[1:2]), as.character(dates[3:4])))

  source_paths <- resolve_source_storage_paths(cfg, package_root(), root, create = TRUE)
  first_archive <- file.path(source_paths$raw_dir,
    paste0(tools::file_path_sans_ext(basename(requests[[1L]]$target)), ".zip"))
  make_era5land_multimonth_test_archive(first_archive)

  staged_hashes <- character()
  retrieved_requests <- list()
  partial_cache_checks <- list()
  process_calls <- list()
  local_mocked_bindings(
    era5land_retrieve_requests = function(requests, registry, source_paths, config,
                                          transfer_fun = NULL, ...) {
      retrieved_requests[[length(retrieved_requests) + 1L]] <<-
        lapply(requests, function(x) as.character(x$raw_request_dates))
      for (request in requests) {
        if (is.null(era5land_local_archive(request, source_paths))) {
          archive <- file.path(source_paths$raw_dir,
            paste0(tools::file_path_sans_ext(basename(request$target)), ".zip"))
          make_era5land_multimonth_test_archive(archive)
        }
      }
      registry <- era5land_registry_reconcile(requests, registry, source_paths, config,
        persist = TRUE)
      list(registry = registry, retrieved = length(requests), failed = 0L, processing = 0L)
    },
    era5land_request_output_completeness = function(request, product_ids, config, root) {
      request_dates <- as.character(request$raw_request_dates)
      cached_date <- request_dates[[1L]]
      missing_dates <- request_dates[-1L]
      partial_cache_checks[[length(partial_cache_checks) + 1L]] <<- list(
        request_dates = request_dates, cached_dates = cached_date, missing_dates = missing_dates)
      list(valid = FALSE, products = lapply(product_ids, function(id) list(
        product_id = id, missing = missing_dates)), missing_products = product_ids)
    },
    era5land_product_output_completeness = function(product_id, request, config, root,
                                                    require_provenance = TRUE) {
      list(valid = FALSE, product_id = product_id,
        missing = as.character(request$raw_request_dates), output_paths = character())
    },
    era5land_extract_archive = function(archive_path, extracted_root, request_hash,
                                        request_dates, run_dir = NULL) {
      ids <- .era5land_product_ids()
      aliases <- c(era5land_tmean = "t2m", era5land_soiltemp_l1_mean = "stl1",
        era5land_soiltemp_l2_mean = "stl2", era5land_soilwater_l1_mean = "swvl1",
        era5land_soilwater_l2_mean = "swvl2", era5land_surface_pressure_mean = "sp",
        era5land_lai_high_mean = "lai_hv", era5land_lai_low_mean = "lai_lv")
      specs <- lapply(ids, get_variable_spec)
      inventory <- data.frame(
        request_hash = request_hash, archive_path = archive_path, archive_sha256 = "fixture",
        member_name = paste0(ids, ".nc"), member_size = 1,
        member_sha256 = paste0("fixture-", ids),
        extracted_path = file.path(extracted_root, request_hash, paste0(ids, ".nc")),
        container_type = rep("netcdf4_hdf5", length(ids)),
        netcdf_inspection_status = rep("ok", length(ids)),
        environmental_variable_alias = unname(aliases[ids]), product_id = ids,
        cds_variable = vapply(specs, function(x) x$cds_variable, character(1)),
        source_units = vapply(specs, function(x) x$source_units, character(1)),
        dimension_names = rep("longitude;latitude;time", length(ids)),
        dimension_lengths = rep("2;2;2", length(ids)), time_dimension = rep("time", length(ids)),
        decoded_dates = rep(paste(as.character(request_dates), collapse = ";"), length(ids)),
        stringsAsFactors = FALSE
      )
      attr(inventory, "source_map") <- data.frame()
      attr(inventory, "extraction_reused") <- FALSE
      inventory
    },
    process_downloaded_variable = function(file, daily_dir, template_path, boundary_path,
                                           config, variable_spec, expected_dates,
                                           request_manifest, ...) {
      request_dates <- as.character(request_manifest[[1L]]$raw_request_dates)
      available_dates <- intersect(as.character(expected_dates), request_dates)
      cached_dates <- if (length(available_dates)) available_dates[[1L]] else character()
      written_dates <- setdiff(available_dates, cached_dates)
      process_calls[[length(process_calls) + 1L]] <<- list(
        expected_dates = as.character(expected_dates), request_dates = request_dates,
        cached_dates = cached_dates, written_dates = written_dates)
      date_results <- lapply(available_dates, function(date) list(
        date = date, status = if (date %in% cached_dates) "reused" else "success"))
      list(written = paste0("written-", written_dates),
        reused = paste0("cached-", cached_dates), replaced = character(), failed = character(),
        processing_failures = list(), date_results = date_results, coverage_summary = list())
    },
    era5land_annotate_product_metadata = function(...) character(),
    .package = "cdsdatagrab"
  )

  result <- run_era5land_daily_mean_family(
    fixture$path, mode = "full", dry_run = FALSE,
    start_date = min(dates), end_date = max(dates), output_root = root,
    product_ids = "era5land_tmean",
    stage_fun = function(request, payload) {
      staged_hashes <<- c(staged_hashes, request$request_hash)
      list(job_id = paste0("fixture-", request$request_hash),
        job_url = paste0("https://cds.invalid/jobs/", request$request_hash))
    },
    transfer_fun = function(...) stop("unexpected live transfer in cached test")
  )

  expect_identical(result$status, "success")
  expect_length(result$requests, 2L)
  expect_length(result$request_results, 2L)
  expect_identical(staged_hashes, requests[[2L]]$request_hash)
  expect_length(retrieved_requests, 1L)
  expect_identical(retrieved_requests[[1L]],
    lapply(requests, function(x) as.character(x$raw_request_dates)))
  expect_identical(lapply(partial_cache_checks, `[[`, "missing_dates"),
    list(as.character(dates[2L]), as.character(dates[4L])))
  expect_identical(lapply(process_calls, `[[`, "expected_dates"),
    lapply(requests, function(x) as.character(x$raw_request_dates)))
  expect_identical(lapply(process_calls, `[[`, "cached_dates"),
    list(as.character(dates[1L]), as.character(dates[3L])))
  expect_identical(lapply(process_calls, `[[`, "written_dates"),
    list(as.character(dates[2L]), as.character(dates[4L])))
  expect_true(all(vapply(result$request_results, function(x) identical(x$status, "success"),
    logical(1))))
  expect_equal(vapply(result$request_results, function(x) x$manifest$daily_outputs_written,
    numeric(1)), c(1, 1))
  expect_equal(vapply(result$request_results, function(x) x$manifest$daily_outputs_reused,
    numeric(1)), c(1, 1))
  successful_dates <- unlist(lapply(result$request_results, function(x) {
    x$products[["era5land_tmean"]]$successful_dates
  }), use.names = FALSE)
  expect_setequal(successful_dates, as.character(dates))
})

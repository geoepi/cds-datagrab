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

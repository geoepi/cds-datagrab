make_era5land_zip_fixture <- function(zip_path, reverse_latitude = FALSE, reverse_longitude = FALSE) {
  if (!requireNamespace("ncdf4", quietly = TRUE)) stop("ncdf4 is required")
  src <- tempfile("era5land-members-"); dir.create(src)
  on.exit(unlink(src, recursive = TRUE, force = TRUE), add = TRUE)
  lon_values <- c(-126.5, -126.0, -125.5); lat_values <- c(42.5, 43.0)
  if (reverse_longitude) lon_values <- rev(lon_values)
  if (reverse_latitude) lat_values <- rev(lat_values)
  lon <- ncdf4::ncdim_def("longitude", "degrees_east", lon_values)
  lat <- ncdf4::ncdim_def("latitude", "degrees_north", lat_values)
  valid_time <- ncdf4::ncdim_def("valid_time", "days since 2026-02-01 00:00:00", 0:2, calendar = "proleptic_gregorian")
  products <- list(
    list(file = "2m_temperature_0_daily-mean.nc", id = "era5land_tmean", alias = "t2m", units = "K", base = 273.15),
    list(file = "soil_temperature_level_1_0_daily-mean.nc", id = "era5land_soiltemp_l1_mean", alias = "stl1", units = "K", base = 275),
    list(file = "soil_temperature_level_2_0_daily-mean.nc", id = "era5land_soiltemp_l2_mean", alias = "stl2", units = "K", base = 277),
    list(file = "volumetric_soil_water_layer_1_0_daily-mean.nc", id = "era5land_soilwater_l1_mean", alias = "swvl1", units = "m**3 m**-3", base = .3),
    list(file = "volumetric_soil_water_layer_2_0_daily-mean.nc", id = "era5land_soilwater_l2_mean", alias = "swvl2", units = "m**3 m**-3", base = .4),
    list(file = "surface_pressure_0_daily-mean.nc", id = "era5land_surface_pressure_mean", alias = "sp", units = "Pa", base = 100000),
    list(file = "leaf_area_index_high_vegetation_0_daily-mean.nc", id = "era5land_lai_high_mean", alias = "lai_hv", units = "m**2 m**-2", base = 3),
    list(file = "leaf_area_index_low_vegetation_0_daily-mean.nc", id = "era5land_lai_low_mean", alias = "lai_lv", units = "m**2 m**-2", base = 1)
  )
  for (item in products) {
    var <- ncdf4::ncvar_def(item$alias, item$units, list(lon, lat, valid_time), -9999, prec = "double")
    number <- ncdf4::ncvar_def("number", "1", list(), -9999, prec = "double")
    path <- file.path(src, item$file); nc <- ncdf4::nc_create(path, list(var, number), force_v4 = TRUE)
    z <- array(item$base, dim = c(length(lon_values), length(lat_values), 3L))
    for (k in seq_len(3L)) z[, , k] <- z[, , k] + outer(seq_along(lon_values) - 1, seq_along(lat_values) - 1, `+`) * .01 + k * .1
    ncdf4::ncvar_put(nc, var, z); ncdf4::ncvar_put(nc, number, 0); ncdf4::nc_close(nc)
  }
  old <- getwd(); on.exit(setwd(old), add = TRUE); setwd(src)
  utils::zip(zip_path, basename(vapply(products, function(x) file.path(src, x$file), character(1))), flags = "-q")
  zip_path
}

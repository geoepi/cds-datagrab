detect_download_format <- function(path) detect_container_type(path)

decode_netcdf_time <- function(values, units, calendar = NULL) {
  if (is.null(calendar) || !length(calendar) || is.na(calendar) || !is.character(calendar) || !nzchar(calendar)) calendar <- "standard"
  if (!calendar %in% c("standard", "gregorian", "proleptic_gregorian")) stop("Unsupported NetCDF calendar: ", calendar, call. = FALSE)
  match <- regexec("^\\s*([A-Za-z]+)\\s+since\\s+([0-9]{4}-[0-9]{2}-[0-9]{2})(?:[ T]([0-9]{2}):([0-9]{2}):([0-9]{2}(?:\\.[0-9]+)?))?", as.character(units))
  parts <- regmatches(as.character(units), match)[[1L]]
  if (length(parts) < 3L) stop("Unsupported NetCDF time units: ", units, call. = FALSE)
  multiplier <- switch(tolower(parts[[2L]]), seconds = 1, minutes = 60, hours = 3600, days = 86400,
    stop("Unsupported NetCDF time units: ", units, call. = FALSE))
  origin <- as.POSIXct(paste(parts[[3L]], if (length(parts) >= 4L && nzchar(parts[[4L]])) paste(parts[[4L]], parts[[5L]], parts[[6L]], sep = ":") else "00:00:00"), tz = "UTC")
  as.POSIXct(origin + as.numeric(values) * multiplier, tz = "UTC")
}

netcdf_dimension_aliases <- list(
  longitude = c("longitude", "lon"),
  latitude = c("latitude", "lat"),
  time = c("valid_time", "time", "date")
)

resolve_netcdf_coordinate_dimensions <- function(dimensions, require_time = TRUE) {
  dimensions <- as.character(dimensions)
  find_dimension <- function(kind) {
    aliases <- tolower(netcdf_dimension_aliases[[kind]])
    hits <- dimensions[tolower(dimensions) %in% aliases]
    if (length(hits) > 1L) stop("NetCDF has ambiguous ", kind, " dimensions: ", paste(hits, collapse = ", "), call. = FALSE)
    if (length(hits)) hits[[1L]] else NA_character_
  }
  resolved <- list(
    longitude = find_dimension("longitude"),
    latitude = find_dimension("latitude"),
    time = find_dimension("time")
  )
  required <- c(resolved$longitude, resolved$latitude, if (isTRUE(require_time)) resolved$time)
  if (anyNA(required)) stop("Selected NetCDF variable must have longitude, latitude, and time dimensions", call. = FALSE)
  resolved
}

inspect_netcdf_ncdf4 <- function(path) {
  if (!requireNamespace("ncdf4", quietly = TRUE)) stop("ncdf4 is required", call. = FALSE)
  nc <- ncdf4::nc_open(path)
  on.exit(ncdf4::nc_close(nc), add = TRUE)
  attribute <- function(variable, name, default = NULL) {
    value <- tryCatch(ncdf4::ncatt_get(nc, variable, name), error = function(e) list(hasatt = FALSE))
    if (isTRUE(value$hasatt)) value$value else default
  }
  dimensions <- lapply(nc$dim, function(dimension) list(
    name = dimension$name, length = dimension$len, values = dimension$vals, units = dimension$units
  ))
  variables <- lapply(nc$var, function(variable) list(
    name = variable$name, units = variable$units, long_name = attribute(variable$name, "long_name"),
    dimensions = vapply(variable$dim, function(dimension) dimension$name, character(1)),
    dimension_lengths = vapply(variable$dim, function(dimension) dimension$len, numeric(1)),
    data_signature = paste(vapply(variable$dim, function(dimension) dimension$name, character(1)), collapse = "|"),
    fill_value = variable$missval, missing_value = attribute(variable$name, "missing_value"),
    scale_factor = attribute(variable$name, "scale_factor", 1), add_offset = attribute(variable$name, "add_offset", 0)
  ))
  names(variables) <- vapply(nc$var, function(variable) variable$name, character(1))
  for (name in setdiff(names(dimensions), names(variables))) {
    variables[[name]] <- list(
      name = name, units = dimensions[[name]]$units, dimensions = name,
      dimension_lengths = dimensions[[name]]$length, fill_value = NA_real_,
      missing_value = NA_real_, scale_factor = 1, add_offset = 0
    )
  }
  coordinate_names <- resolve_netcdf_coordinate_dimensions(names(dimensions), require_time = FALSE)
  coordinate_values <- function(name) if (!is.na(name)) dimensions[[name]]$values else numeric()
  time_units <- if (!is.na(coordinate_names$time)) dimensions[[coordinate_names$time]]$units else NA_character_
  calendar <- if (!is.na(coordinate_names$time)) attribute(coordinate_names$time, "calendar") else NULL
  if (!is.character(calendar) || !length(calendar) || is.na(calendar) || !nzchar(calendar)) calendar <- NULL
  decoded <- if (!is.na(coordinate_names$time)) decode_netcdf_time(dimensions[[coordinate_names$time]]$values, time_units, calendar) else as.POSIXct(character())
  list(
    path = path, format = detect_download_format(path), variables = variables, dimensions = dimensions,
    coordinate_variables = list(
      longitude = coordinate_values(coordinate_names$longitude),
      latitude = coordinate_values(coordinate_names$latitude), time = coordinate_values(coordinate_names$time)
    ),
    time_variable = coordinate_names$time, time_coordinate_name = coordinate_names$time,
    time_units = time_units, time_calendar_original = calendar,
    time_calendar_effective = calendar %||% "standard", decoded_dates = as.Date(decoded, tz = "UTC"),
    latitude_order = if (!is.na(coordinate_names$latitude) && length(coordinate_values(coordinate_names$latitude)) > 1L) {
      values <- coordinate_values(coordinate_names$latitude)
      if (values[[1L]] < tail(values, 1L)) "ascending" else "descending"
    } else "single",
    longitude_order = if (!is.na(coordinate_names$longitude) && length(coordinate_values(coordinate_names$longitude)) > 1L) {
      values <- coordinate_values(coordinate_names$longitude)
      if (values[[1L]] < tail(values, 1L)) "ascending" else "descending"
    } else "single"
  )
}

inspect_netcdf_file <- function(path) inspect_netcdf_ncdf4(path)
select_era5_temperature_variable <- function(nc_metadata) resolve_netcdf_variable(nc_metadata, get_variable_spec("era5_mintemp"))

read_daily_netcdf <- function(path, variable_spec, raw_request_dates, dates_to_process = NULL, request_hash = NULL) {
  metadata <- inspect_netcdf_ncdf4(path)
  selected <- resolve_netcdf_variable(metadata, variable_spec)
  variable <- metadata$variables[[selected]]
  original_units <- variable$units
  normalized_units <- normalize_source_units(original_units)
  expected_units <- normalize_source_units(variable_spec$source_units)
  if (!identical(normalized_units, expected_units) && !(variable_spec$id == "era5_lai_low" && tolower(trimws(as.character(original_units))) %in% c("1", "dimensionless"))) {
    stop("Selected variable has incompatible source units: ", original_units, call. = FALSE)
  }
  dimensions <- variable$dimensions
  coordinates <- resolve_netcdf_coordinate_dimensions(dimensions)
  longitude_name <- coordinates$longitude
  latitude_name <- coordinates$latitude
  time_name <- coordinates$time
  nc <- ncdf4::nc_open(path)
  on.exit(ncdf4::nc_close(nc), add = TRUE)
  longitude <- nc$dim[[longitude_name]]$vals
  latitude <- nc$dim[[latitude_name]]$vals
  time_values <- nc$dim[[time_name]]$vals
  values <- ncdf4::ncvar_get(nc, selected, collapse_degen = FALSE, raw_datavals = FALSE)
  actual_dimensions <- dim(values)
  expected_dimensions <- as.integer(variable$dimension_lengths)
  if (length(actual_dimensions) != length(expected_dimensions) || !identical(as.integer(actual_dimensions), expected_dimensions)) {
    stop("Selected NetCDF variable did not preserve longitude, latitude, and time dimensions", call. = FALSE)
  }
  permutation <- match(c(longitude_name, latitude_name, time_name), dimensions)
  if (anyNA(permutation)) stop("Selected NetCDF variable must have longitude, latitude, and time dimensions", call. = FALSE)
  values <- aperm(values, permutation)
  fill_values <- c(variable$fill_value, variable$missing_value)
  if (length(fill_values) && any(is.finite(fill_values))) values[values %in% fill_values] <- NA_real_
  scale_factor <- as.numeric(variable$scale_factor)
  add_offset <- as.numeric(variable$add_offset)
  if (!is.na(scale_factor) && scale_factor != 1) values <- values * scale_factor
  if (!is.na(add_offset) && add_offset != 0) values <- values + add_offset
  decoded_dates <- as.Date(decode_netcdf_time(time_values, metadata$time_units, metadata$time_calendar_effective))
  expected_dates <- normalize_date_vector(raw_request_dates, "raw_request_dates")
  if (!identical(format(decoded_dates, "%Y-%m-%d"), format(expected_dates, "%Y-%m-%d"))) {
    stop("Raw date coverage mismatch; missing or extra request dates", call. = FALSE)
  }
  selected_dates <- normalize_date_vector(dates_to_process %||% expected_dates, "dates_to_process")
  indexes <- match(format(selected_dates, "%Y-%m-%d"), format(decoded_dates, "%Y-%m-%d"))
  if (anyNA(indexes)) stop("Selected dates are absent from raw", call. = FALSE)
  source <- validate_source_values(values, variable_spec)
  values <- source$values
  dx <- if (length(longitude) > 1L) median(diff(sort(longitude))) else 1
  dy <- if (length(latitude) > 1L) median(diff(sort(latitude))) else 1
  rasters <- lapply(indexes, function(index) {
    spatial <- matrix(values[, , index, drop = TRUE], nrow = length(longitude), ncol = length(latitude))
    spatial <- t(spatial)
    if (length(latitude) > 1L && latitude[[1L]] < tail(latitude, 1L)) spatial <- spatial[nrow(spatial):1, , drop = FALSE]
    if (length(longitude) > 1L && longitude[[1L]] > tail(longitude, 1L)) spatial <- spatial[, ncol(spatial):1, drop = FALSE]
    convert_source_units(terra::rast(spatial,
      extent = terra::ext(min(longitude) - abs(dx) / 2, max(longitude) + abs(dx) / 2,
        min(latitude) - abs(dy) / 2, max(latitude) + abs(dy) / 2), crs = "EPSG:4326"),
      variable_spec, original_units)
  })
  list(
    rasters = rasters, dates = selected_dates, decoded_dates = decoded_dates, reader_used = "ncdf4",
    source_format = metadata$format, selected_variable = selected, selected_netcdf_variable = selected,
    selected_variable_alias = selected, data_variable_dimensions = dimensions, dimension_names = dimensions,
    dimension_lengths = unname(variable$dimension_lengths), dimension_order = dimensions,
    latitude_direction = metadata$latitude_order, longitude_direction = metadata$longitude_order,
    longitude_convention = if (all(longitude >= 0)) "0_360" else "-180_180",
    time_coordinate_name = time_name, time_coordinate_units = metadata$time_units,
    time_coordinate_raw_values = time_values, time_coordinate_calendar_effective = metadata$time_calendar_effective,
    source_units = original_units, source_units_original = original_units, source_units_normalized = normalized_units,
    output_units = variable_spec$output_units, unit_conversion = variable_spec$unit_conversion,
    source_value_raw_minimum = source$source_raw_minimum, source_value_raw_maximum = source$source_raw_maximum,
    source_value_minimum = source$source_minimum, source_value_maximum = source$source_maximum,
    source_lower_clamped_count = source$source_lower_clamped_count,
    source_upper_clamped_count = source$source_upper_clamped_count,
    source_validation_tolerance = source$source_validation_tolerance, variable_spec = variable_spec,
    daily_statistic_source = if (variable_spec$id == "agera5_relhum_min") "AgERA5_precomputed_derived_indicator" else if (variable_spec$id == "era5_lai_low") "ERA5_monthly_climatology" else "cds_daily_statistics",
    daily_statistic = variable_spec$daily_statistic, subdaily_frequency = variable_spec$frequency
  )
}

read_era5_daily_with_ncdf4 <- function(path, variable = "t2m", expected_dates = NULL,
                                        variable_spec = NULL, raw_request_dates = NULL,
                                        dates_to_process = NULL, request_hash = NULL) {
  spec <- variable_spec %||% get_variable_spec(variable)
  read_daily_netcdf(path, spec, raw_request_dates %||% expected_dates,
    dates_to_process %||% raw_request_dates %||% expected_dates, request_hash)
}

read_era5_daily_layers <- function(path, expected_dates = NULL, variable_spec = NULL,
                                    raw_request_dates = NULL, dates_to_process = NULL,
                                    request_hash = NULL) {
  format <- detect_download_format(path)
  if (format %in% c("netcdf4_hdf5", "netcdf_classic")) {
    return(read_daily_netcdf(path, variable_spec %||% get_variable_spec("era5_mintemp"),
      raw_request_dates %||% expected_dates, dates_to_process %||% raw_request_dates %||% expected_dates,
      request_hash))
  }
  if (format == "zip") {
    extraction <- file.path(dirname(path), "extracted")
    fs::dir_create(extraction, recurse = TRUE)
    normalize_downloaded_file(path, extraction)
    files <- list.files(extraction, pattern = "\\.(nc|netcdf)$", full.names = TRUE, recursive = TRUE, ignore.case = TRUE)
    if (!length(files)) stop("ZIP contains no NetCDF files", call. = FALSE)
    return(read_era5_daily_layers(files[[1L]], expected_dates, variable_spec, raw_request_dates, dates_to_process, request_hash))
  }
  stop("Unsupported or non-NetCDF raw format: ", format, call. = FALSE)
}

discover_netcdf_files <- function(path) {
  if (detect_download_format(path) %in% c("netcdf4_hdf5", "netcdf_classic")) path else character()
}

normalize_downloaded_file <- function(path, extraction_dir) {
  if (detect_download_format(path) != "zip") return(discover_netcdf_files(path))
  fs::dir_create(extraction_dir, recurse = TRUE)
  utils::unzip(path, exdir = extraction_dir)
  list.files(extraction_dir, pattern = "\\.nc4?$", full.names = TRUE, recursive = TRUE, ignore.case = TRUE)
}

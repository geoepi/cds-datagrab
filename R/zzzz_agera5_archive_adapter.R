# Content-based AgERA5 archive handling. The existing direct-NetCDF path is
# retained; this adapter only changes the AgERA5 response/container boundary.
normalize_netcdf_name <- function(x) {
  x <- tolower(as.character(x)); x <- gsub("[^a-z0-9]+", "_", x); gsub("^_|_$", "", x)
}
get_nc_attribute <- function(nc, variable, attribute) {
  result <- ncdf4::ncatt_get(nc, variable, attribute)
  if (!isTRUE(result$hasatt)) return(NA_character_)
  as.character(result$value)
}
agera5_archive_manifest_schema_version <- 2L
agera5_adapter_inspection_version <- "agera5-rh-inspection-v2"
agera5_alias_hash <- function(variable_spec) digest::digest(c("Derived_Relative_Humidity_2m_Min_24h","derived_relative_humidity_2m_min_24h","2m_relative_humidity_derived","relative_humidity_2m_min"), algo="sha256")
agera5_selection_rules_hash <- function() digest::digest("exact-alias>normalized-alias>percent+lon+lat+relative-humidity+minimum-metadata", algo="sha256")
agera5_manifest_fingerprints <- function(variable_spec, checksum) {
  list(archive_manifest_schema_version=agera5_archive_manifest_schema_version,
       adapter_id="agera5_relhum_min", adapter_inspection_version=agera5_adapter_inspection_version,
       dataset_id=variable_spec$id, variable_spec_hash=variable_spec$variable_spec_hash,
       variable_alias_hash=agera5_alias_hash(variable_spec), selection_rules_hash=agera5_selection_rules_hash(),
       archive_checksum=checksum, created_with_package_version=as.character(utils::packageVersion("cdsdatagrab")))
}
.resolve_netcdf_variable_before_agera5 <- resolve_netcdf_variable
resolve_netcdf_variable <- function(nc_metadata, variable_spec) {
  if (!identical(variable_spec$id, "agera5_relhum_min")) return(.resolve_netcdf_variable_before_agera5(nc_metadata, variable_spec))
  aliases <- unique(c(variable_spec$netcdf_variable_names, "Derived_Relative_Humidity_2m_Min_24h", "derived_relative_humidity_2m_min_24h", "relative_humidity_2m_min"))
  names_available <- names(nc_metadata$variables)
  exact <- intersect(aliases, names_available)
  if (length(exact) == 1L) return(exact[[1]])
  normalized <- normalize_netcdf_name(names_available)
  alias_norm <- normalize_netcdf_name(aliases)
  norm_hits <- names_available[normalized %in% alias_norm]
  if (length(norm_hits) == 1L) return(norm_hits[[1]])
  excluded <- grepl("^(crs|time|lat|latitude|lon|longitude)(_|$)|bounds|grid", normalized)
  candidates <- names_available[!excluded]
  candidates <- candidates[vapply(candidates, function(n) {
    v <- nc_metadata$variables[[n]]
    units <- normalize_source_units(v$units %||% NA_character_)
    dims <- normalize_netcdf_name(v$dimensions %||% character())
    long <- normalize_netcdf_name(v$long_name %||% "")
    identical(units, "percent") && any(dims %in% c("lon","longitude")) && any(dims %in% c("lat","latitude")) && grepl("relative_humidity", long) && grepl("minimum|min_24|24_hour", long)
  }, logical(1))]
  if (length(candidates) != 1L) stop("Unable to select a unique AgERA5 RH variable; available variables: ", paste(names_available, collapse=", "), call.=FALSE)
  candidates[[1]]
}
archive_member_date <- function(name) {
  hits <- regmatches(basename(name), gregexpr("(?<![0-9])20[0-9]{6}(?![0-9])", basename(name), perl=TRUE))[[1]]
  if (!length(hits)) return(NA_character_)
  d <- tryCatch(as.Date(hits[[1]], "%Y%m%d"), error=function(e) NA)
  if (is.na(d)) NA_character_ else format(d, "%Y-%m-%d")
}

archive_member_safe <- function(name) {
  n <- gsub("\\\\", "/", as.character(name))
  nzchar(n) && !grepl("(^/|^[A-Za-z]:|(^|/)\\.\\.(/|$))", n) && !grepl("(^|/)($|\\.)", n)
}

extract_agera5_archive <- function(archive_path, extracted_root, request_hash, variable_spec, run_dir=NULL) {
  checksum <- digest::digest(file=archive_path, algo="sha256")
  final_dir <- file.path(extracted_root, request_hash)
  manifest_path <- file.path(final_dir, "archive_manifest.csv")
  if (dir.exists(final_dir) && file.exists(manifest_path)) {
    old <- tryCatch(utils::read.csv(manifest_path, stringsAsFactors=FALSE), error=function(e) NULL)
    fp <- agera5_manifest_fingerprints(variable_spec, checksum)
    inventory_matches <- function(x) {
      required <- c("member_relative_path", "extracted_path", "member_size", "member_checksum")
      if (!all(required %in% names(x)) || !nrow(x) || any(!vapply(x$member_relative_path, archive_member_safe, logical(1)))) return(FALSE)
      all(vapply(seq_len(nrow(x)), function(i) {
        p <- x$extracted_path[[i]]
        file.exists(p) && identical(as.numeric(file.info(p)$size), as.numeric(x$member_size[[i]])) &&
          identical(digest::digest(file=p, algo="sha256"), as.character(x$member_checksum[[i]]))
      }, logical(1)))
    }
    current <- !is.null(old) && nrow(old) && inventory_matches(old) &&
      all(vapply(names(fp), function(n) n %in% names(old) && all(as.character(old[[n]]) == as.character(fp[[n]])), logical(1)))
    if (isTRUE(current)) {
      attr(old, "extraction_reused") <- TRUE; attr(old, "manifest_reused") <- TRUE
      return(old)
    }
    if (!is.null(old) && nrow(old) && all(file.exists(old$extracted_path)) && all(old$archive_checksum == checksum)) {
      for (n in c("variable_candidate","selected","selection_reason","validation_message","selected_netcdf_variable","date_from_content")) if (!n %in% names(old)) old[[n]] <- NA
      for (n in names(fp)) old[[n]] <- unname(fp[[n]])
      rebuilt <- lapply(seq_len(nrow(old)), function(i) {
        p <- old$extracted_path[[i]]; md <- tryCatch(inspect_netcdf_ncdf4(p), error=function(e)e)
        selected <- if (inherits(md, "error")) NA_character_ else tryCatch(resolve_netcdf_variable(md, variable_spec), error=function(e) NA_character_)
        old$variable_candidate[[i]] <- !is.na(selected); old$selected[[i]] <- FALSE; old$selection_reason[[i]] <- ""
        old$validation_message[[i]] <- if (!is.na(selected)) "candidate" else "variable not found"
        old$selected_netcdf_variable[[i]] <- selected
        old$date_from_content[[i]] <- if (!inherits(md, "error") && length(md$decoded_dates)) canonical_iso_dates(md$decoded_dates[[1]], "date_from_content") else NA_character_
        old[i,]
      })
      rebuilt <- do.call(rbind, rebuilt); utils::write.csv(rebuilt, manifest_path, row.names=FALSE)
      if (!is.null(run_dir)) utils::write.csv(rebuilt, file.path(run_dir, "archive_manifest.csv"), row.names=FALSE)
      attr(rebuilt, "extraction_reused") <- TRUE; attr(rebuilt, "manifest_reused") <- FALSE
      attr(rebuilt, "manifest_rebuild_reason") <- "adapter fingerprint changed"
      return(rebuilt)
    }
    if (!is.null(old) && nrow(old) && !all(old$archive_checksum == checksum)) stop("Existing extracted AgERA5 directory has a different archive checksum", call.=FALSE)
  }
  listing <- tryCatch(utils::unzip(archive_path, list=TRUE), error=function(e) stop("Malformed ZIP archive: ", conditionMessage(e), call.=FALSE))
  members <- as.character(listing$Name)
  if (!length(members) || any(!vapply(members, archive_member_safe, logical(1)))) stop("Archive contains unsafe or empty member names", call.=FALSE)
  if (any(listing$Length < 0)) stop("Archive contains invalid member sizes", call.=FALSE)
  partial <- file.path(extracted_root, ".partial", paste0(request_hash, "-", as.integer(Sys.time()), "-", sample.int(1e6,1)))
  fs::dir_create(partial, recurse=TRUE)
  on.exit(if (dir.exists(partial)) unlink(partial, recursive=TRUE), add=TRUE)
  utils::unzip(archive_path, exdir=partial, overwrite=FALSE)
  extracted <- file.path(partial, members)
  if (any(!file.exists(extracted))) stop("Archive extraction did not produce every member", call.=FALSE)
  nc <- grepl("\\.(nc|netcdf)$", members, ignore.case=TRUE)
  fp <- agera5_manifest_fingerprints(variable_spec, checksum)
  rows <- lapply(seq_along(members), function(i) {
    p <- extracted[[i]]; fmt <- detect_download_format(p); d <- archive_member_date(members[[i]])
    variable_candidate <- FALSE; content_date <- NA_character_; validation <- "unselected"
    if (nc[[i]]) {
      md <- tryCatch(inspect_netcdf_ncdf4(p), error=function(e)e)
      if (!inherits(md, "error")) {
        variable_candidate <- !inherits(tryCatch(resolve_netcdf_variable(md, variable_spec), error=function(e)e), "error")
        content_date <- if (length(md$decoded_dates)) canonical_iso_dates(md$decoded_dates[[1]], "date_from_content") else NA_character_
        validation <- if (variable_candidate) "candidate" else "variable not found"
      } else validation <- conditionMessage(md)
    }
    data.frame(archive_manifest_schema_version=fp$archive_manifest_schema_version, adapter_id=fp$adapter_id,
      adapter_inspection_version=fp$adapter_inspection_version, dataset_id=fp$dataset_id,
      variable_spec_hash=fp$variable_spec_hash, variable_alias_hash=fp$variable_alias_hash,
      selection_rules_hash=fp$selection_rules_hash, created_with_package_version=fp$created_with_package_version,
      archive_path=normalizePath(archive_path,winslash="/",mustWork=FALSE), archive_checksum=checksum,
      request_hash=request_hash, member_name=members[[i]], member_relative_path=gsub("\\\\","/",members[[i]]),
      extracted_path=normalizePath(p,winslash="/",mustWork=FALSE), member_size=as.numeric(listing$Length[[i]]),
      member_checksum=digest::digest(file=p,algo="sha256"), detected_format=fmt, date_from_filename=d,
      date_from_content=content_date, variable_candidate=variable_candidate,
      selected_netcdf_variable=if (nc[[i]] && variable_candidate) tryCatch(resolve_netcdf_variable(inspect_netcdf_ncdf4(p),variable_spec), error=function(e) NA_character_) else NA_character_, selected=FALSE,
      selection_reason="", validation_message=validation, stringsAsFactors=FALSE)
  })
  manifest <- do.call(rbind, rows)
  if (dir.exists(final_dir)) stop("Extraction destination already exists", call.=FALSE)
  fs::dir_create(dirname(final_dir), recurse=TRUE)
  if (!file.rename(partial, final_dir)) stop("Could not atomically promote extracted archive", call.=FALSE)
  manifest$extracted_path <- file.path(final_dir, manifest$member_relative_path)
  manifest$extracted_path <- normalizePath(manifest$extracted_path,winslash="/",mustWork=FALSE)
  manifest$selected <- FALSE
  utils::write.csv(manifest, file.path(final_dir,"archive_manifest.csv"), row.names=FALSE)
  if (!is.null(run_dir)) utils::write.csv(manifest, file.path(run_dir,"archive_manifest.csv"), row.names=FALSE)
  attr(manifest, "extraction_reused") <- FALSE; attr(manifest, "manifest_reused") <- FALSE
  manifest
}

select_agera5_archive_members <- function(manifest, request_dates) {
  dates <- canonical_iso_dates(request_dates, "requested archive dates")
  out <- vector("list", length(dates))
  for (i in seq_along(dates)) {
    z <- manifest[manifest$date_from_filename == dates[[i]] & manifest$variable_candidate & manifest$detected_format %in% c("netcdf4_hdf5","netcdf_classic"),,drop=FALSE]
    if (nrow(z) != 1L) stop("Expected exactly one AgERA5 NetCDF member for ", dates[[i]], "; found ", nrow(z), call.=FALSE)
    if (!is.na(z$date_from_content[[1]]) && z$date_from_content[[1]] != dates[[i]]) stop("Archive filename/content date disagreement for ", dates[[i]], call.=FALSE)
    z$selected <- TRUE; z$selection_reason <- "unique variable/date match"
    if (!"selected_netcdf_variable" %in% names(z)) z$selected_netcdf_variable <- NA_character_
    if (is.na(z$selected_netcdf_variable[[1]])) z$selected_netcdf_variable[[1]] <- "Derived_Relative_Humidity_2m_Min_24h"
    out[[i]] <- z
  }
  do.call(rbind, out)
}

agera5_terra_aliases <- function() c("Derived_Relative_Humidity_2m_Min_24h", "derived_relative_humidity_2m_min_24h", "2m_relative_humidity_derived", "relative_humidity_2m_min")
agera5_netcdf_driver_available <- function(drivers) {
  if (is.null(drivers) || !nrow(as.data.frame(drivers)) || !all(c("name", "raster") %in% names(drivers))) return(FALSE)
  d <- as.data.frame(drivers, stringsAsFactors=FALSE)
  any(grepl("^netcdf$", as.character(d$name), ignore.case=TRUE) & as.logical(d$raster), na.rm=TRUE)
}
terra_has_netcdf_driver <- function() {
  override <- getOption("cdsdatagrab.agera5_netcdf_driver_available", NULL)
  if (!is.null(override)) return(isTRUE(override))
  if (!requireNamespace("terra", quietly=TRUE)) return(FALSE)
  d <- tryCatch(terra::gdal(drivers=TRUE), error=function(e) NULL)
  agera5_netcdf_driver_available(d)
}
agera5_terra_variable <- function(r, variable_spec) {
  aliases <- unique(c(variable_spec$netcdf_variable_names, agera5_terra_aliases()))
  vn <- tryCatch(terra::varnames(r), error=function(e) character())
  nm <- tryCatch(terra::names(r), error=function(e) character())
  vn <- as.character(vn); nm <- as.character(nm)
  exact <- intersect(aliases, vn)
  if (length(exact) == 1L) return(exact[[1]])
  norm <- normalize_netcdf_name(vn)
  hits <- vn[norm %in% normalize_netcdf_name(aliases)]
  if (length(hits) == 1L) return(hits[[1]])
  if (terra::nlyr(r) == 1L && length(vn) == 1L && normalize_netcdf_name(vn) %in% normalize_netcdf_name(aliases)) return(vn[[1]])
  stop("AgERA5 terra reader found zero or multiple RH layers; varnames=", paste(vn, collapse=", "), names=", paste(nm, collapse=", "), expected aliases=", paste(aliases, collapse=", "), call.=FALSE)
}

agera5_nc_attribute <- function(nc, variable, attribute, default=NA) {
  x <- tryCatch(ncdf4::ncatt_get(nc, variable, attribute), error=function(e) list(hasatt=FALSE))
  if (!isTRUE(x$hasatt)) return(default)
  x$value
}
agera5_coordinate_check <- function(x, name) {
  x <- as.numeric(x)
  if (!length(x) || any(!is.finite(x)) || anyDuplicated(x)) stop("AgERA5 ", name, " coordinate is empty, nonfinite, or duplicated", call.=FALSE)
  o <- order(x); s <- x[o]; delta <- diff(s); step <- median(delta)
  if (!length(delta) || any(delta <= 0) || !is.finite(step) || max(abs(delta-step)) > max(1e-8, abs(step)*1e-4)) stop("AgERA5 ", name, " coordinate is not strictly monotonic and regularly spaced", call.=FALSE)
  if (abs(step-0.1) > 0.001) stop("AgERA5 ", name, " coordinate spacing is not approximately 0.1 degrees: ", step, call.=FALSE)
  list(values=x, order=o, sorted=s, step=step, direction=if (x[[1]] < x[[length(x)]]) "ascending" else "descending", reordered=!identical(o, seq_along(x)))
}
agera5_result <- function(r, path, expected, selected, units, source_min, source_max, non_na, na_count, low, high, diagnostics, reader_selected, reader_attempted, reason) {
  diagnostics$netcdf_gdal_driver_available <- diagnostics$netcdf_gdal_driver_available %||% NA
  diagnostics$reader_attempted <- reader_attempted; diagnostics$reader_selected <- reader_selected; diagnostics$reader_selection_reason <- reason
  list(raster=r, date=expected, selected_source_variable=selected, selected_netcdf_variable=selected,
       source_units=units, source_crs="EPSG:4326", source_resolution=as.numeric(terra::res(r)),
       source_extent=c(terra::xmin(terra::ext(r)),terra::xmax(terra::ext(r)),terra::ymin(terra::ext(r)),terra::ymax(terra::ext(r))),
       source_minimum=source_min, source_maximum=source_max, source_non_na_count=non_na, source_na_count=na_count,
       source_value_minimum=source_min, source_value_maximum=source_max,
       clamped_low_count=low, clamped_high_count=high, date_source=diagnostics$date_source %||% "netcdf_time",
       reader_selected=reader_selected, reader_attempted=reader_attempted, reader_diagnostics=diagnostics,
       terra_names=diagnostics$terra_names %||% character(), terra_varnames=diagnostics$terra_varnames %||% character(),
       terra_time=diagnostics$terra_time %||% character(), source_format="netcdf4_hdf5", reader_used=reader_selected,
       selected_variable=selected, selected_variable_alias=selected, source_units_original=units,
       source_units_normalized=normalize_source_units(units), output_units="percent", unit_conversion="identity",
       dates=as.Date(expected), decoded_dates=as.POSIXct(expected,tz="UTC"), rasters=list(r),
       daily_statistic_source="AgERA5_precomputed_derived_indicator", daily_statistic="24_hour_minimum", subdaily_frequency="daily")
}

read_agera5_daily_member_ncdf4 <- function(path, expected_date, filename_date=NULL, variable_spec, fallback_date=NULL, driver_available=FALSE, reader_attempted="ncdf4") {
  if (!requireNamespace("ncdf4", quietly=TRUE)) stop("ncdf4 is required for AgERA5 members when GDAL has no NetCDF raster driver", call.=FALSE)
  expected <- canonical_iso_dates(expected_date, "expected AgERA5 member date")
  if (length(expected) != 1L) stop("AgERA5 daily member requires exactly one expected date", call.=FALSE)
  nc <- ncdf4::nc_open(path); on.exit(ncdf4::nc_close(nc), add=TRUE)
  md <- inspect_netcdf_ncdf4(path); selected <- resolve_netcdf_variable(md, variable_spec); v <- nc$var[[selected]]
  dims <- vapply(v$dim, function(d) d$name, character(1)); raw_dims <- vapply(v$dim, function(d) d$len, numeric(1))
  lon_name <- dims[grepl("^(lon|longitude)$", dims, ignore.case=TRUE)][1]; lat_name <- dims[grepl("^(lat|latitude)$", dims, ignore.case=TRUE)][1]; time_name <- dims[grepl("^(time|valid_time)$", dims, ignore.case=TRUE)][1]
  if (anyNA(c(lon_name,lat_name,time_name)) || length(dims) != 3L || !identical(sort(raw_dims), sort(c(nc$dim[[lon_name]]$len,nc$dim[[lat_name]]$len,1)))) stop("AgERA5 variable must have lon, lat, and singleton time dimensions; dimensions=", paste(dims,collapse=","), " lengths=", paste(raw_dims,collapse="x"), call.=FALSE)
  lon <- nc$dim[[lon_name]]$vals; lat <- nc$dim[[lat_name]]$vals; tm <- nc$dim[[time_name]]$vals
  lc <- agera5_coordinate_check(lon,"longitude"); ac <- agera5_coordinate_check(lat,"latitude")
  if (length(tm) != 1L) stop("AgERA5 member must have exactly one time coordinate", call.=FALSE)
  time_units <- nc$dim[[time_name]]$units; calendar <- agera5_nc_attribute(nc,time_name,"calendar", "standard")
  decoded <- tryCatch(as.Date(decode_netcdf_time(tm,time_units,calendar)), error=function(e) as.Date(NA))
  date_source <- "netcdf_time"
  source_date <- if (!is.na(decoded[[1]])) format(decoded[[1]],"%Y-%m-%d") else NA_character_
  if (is.na(source_date) && !is.null(fallback_date)) { source_date <- canonical_iso_dates(fallback_date,"AgERA5 fallback date"); date_source <- "archive_validated_filename_content_fallback" }
  if (is.na(source_date) || !identical(source_date,expected[[1]]) || (!is.null(filename_date) && !identical(source_date,canonical_iso_dates(filename_date,"filename date")[[1]]))) stop("AgERA5 member date mismatch; expected=",expected[[1]]," decoded=",source_date, call.=FALSE)
  values <- ncdf4::ncvar_get(nc, selected, collapse_degen=FALSE, raw_datavals=FALSE); actual_dims <- dim(values)
  if (length(actual_dims) != 3L || !identical(as.integer(actual_dims), as.integer(raw_dims))) stop("AgERA5 raw array dimensions do not preserve variable dimensions: expected ",paste(raw_dims,collapse="x")," observed ",paste(actual_dims,collapse="x"),call.=FALSE)
  perm <- match(c(lon_name,lat_name,time_name),dims); values <- aperm(values,perm); lat_order <- order(lat, decreasing=TRUE); matrix_north_up <- t(values[lc$order,lat_order,1,drop=TRUE])
  if (!identical(dim(matrix_north_up), c(length(lat),length(lon)))) stop("AgERA5 transformed matrix dimensions are incorrect",call.=FALSE)
  dx <- lc$step; dy <- ac$step; ex <- terra::ext(min(lc$sorted)-dx/2,max(lc$sorted)+dx/2,min(ac$sorted)-dy/2,max(ac$sorted)+dy/2); r <- terra::rast(matrix_north_up,extent=ex,crs="EPSG:4326")
  units <- as.character(v$units %||% agera5_nc_attribute(nc,selected,"units",NA_character_))[[1]]
  if (!identical(normalize_source_units(units),"percent")) stop("AgERA5 ncdf4 member units are not percent: ",units,call.=FALSE)
  finite <- is.finite(values); non_na <- sum(finite); na_count <- sum(!finite); source_min <- if(non_na)min(values[finite]) else NA_real_; source_max <- if(non_na)max(values[finite]) else NA_real_; tolerance <- 1e-6
  if (!is.finite(source_min)||!is.finite(source_max)||source_min < -tolerance||source_max > 100+tolerance) stop("AgERA5 member has materially invalid relative-humidity values: ",source_min," to ",source_max,call.=FALSE)
  low <- sum(values < 0,na.rm=TRUE); high <- sum(values > 100,na.rm=TRUE); if(low||high){matrix_north_up <- pmin(100,pmax(0,matrix_north_up)); terra::values(r) <- as.vector(t(matrix_north_up))}
  diag <- list(netcdf_gdal_driver_available=driver_available, source_dimension_order=dims, raw_array_dimensions=raw_dims, longitude_direction=lc$direction, latitude_direction=ac$direction, longitude_reordered=lc$reordered, latitude_reordered=!identical(lat_order,seq_along(lat)), final_matrix_dimensions=dim(matrix_north_up), date_source=date_source, time_units=time_units, calendar=calendar, fill_value=v$missval, missing_value=agera5_nc_attribute(nc,selected,"missing_value",NA), scale_factor=agera5_nc_attribute(nc,selected,"scale_factor",1), add_offset=agera5_nc_attribute(nc,selected,"add_offset",0), coordinate_ranges=list(longitude=range(lon),latitude=range(lat)), source_minimum=source_min, source_maximum=source_max)
  agera5_result(r,path,expected,selected,units,source_min,source_max,non_na,na_count,low,high,diag,"ncdf4",reader_attempted,"active GDAL runtime has no NetCDF raster driver" )
}

read_agera5_daily_member_terra <- function(path, expected_date, variable_spec, fallback_date=NULL, driver_available=TRUE, reader_attempted="terra") {
  if (!requireNamespace("terra", quietly=TRUE)) stop("terra is required for AgERA5 daily-member processing", call.=FALSE)
  expected <- canonical_iso_dates(expected_date, "expected AgERA5 member date")
  if (length(expected) != 1L) stop("AgERA5 daily member requires exactly one expected date", call.=FALSE)
  r <- tryCatch(terra::rast(path), error=function(e) { class(e) <- c("agera5_terra_open_error", class(e)); stop(e) })
  if (terra::nlyr(r) < 1L) stop("AgERA5 member has no raster layers: ", path, call.=FALSE)
  selected <- agera5_terra_variable(r, variable_spec)
  if (terra::nlyr(r) != 1L) {
    vn <- as.character(terra::varnames(r)); idx <- which(vn == selected)
    if (length(idx) != 1L) stop("AgERA5 member has multiple layers and no unique RH layer: ", path, call.=FALSE)
    r <- r[[idx]]
  }
  if (terra::nlyr(r) != 1L) stop("AgERA5 member must contain exactly one RH layer: ", path, call.=FALSE)
  units <- as.character(tryCatch(terra::units(r), error=function(e) NA_character_))[[1]]
  if (!identical(normalize_source_units(units), "percent")) stop("AgERA5 terra member units are not percent: ", units, call.=FALSE)
  source_time <- tryCatch(terra::time(r), error=function(e) NULL)
  date_source <- "terra_time"
  source_date <- if (!is.null(source_time) && length(source_time) && !is.na(source_time[[1]])) format(as.Date(source_time[[1]]), "%Y-%m-%d") else NA_character_
  if (is.na(source_date) && !is.null(fallback_date)) { source_date <- canonical_iso_dates(fallback_date, "AgERA5 fallback date"); date_source <- "archive_validated_filename_content_fallback" }
  if (is.na(source_date) || !identical(source_date, expected[[1]])) stop("AgERA5 member date mismatch for ", path, "; expected ", expected[[1]], ", decoded ", source_date, call.=FALSE)
  crs <- terra::crs(r, proj=TRUE); resolution <- terra::res(r); ext <- terra::ext(r)
  if (!nzchar(crs) || !isTRUE(terra::is.lonlat(r))) stop("AgERA5 member must use geographic WGS84 coordinates: ", path, call.=FALSE)
  if (length(resolution) != 2L || any(!is.finite(resolution)) || any(abs(resolution - 0.1) > 0.001)) stop("AgERA5 member resolution is not approximately 0.1 degrees: ", paste(resolution, collapse=", "), call.=FALSE)
  if (terra::nrow(r) < 1L || terra::ncol(r) < 1L) stop("AgERA5 member has invalid dimensions: ", path, call.=FALSE)
  mm <- terra::global(r, c("min", "max"), na.rm=TRUE)
  source_min <- as.numeric(mm[1, 1]); source_max <- as.numeric(mm[1, 2])
  if (!is.finite(source_min) || !is.finite(source_max)) stop("AgERA5 member contains no finite non-NA values: ", path, call.=FALSE)
  tolerance <- 1e-6
  if (source_min < -tolerance || source_max > 100 + tolerance) stop("AgERA5 member has materially invalid relative-humidity values: ", source_min, " to ", source_max, call.=FALSE)
  below <- if (source_min < 0) as.numeric(terra::global(r < 0, "sum", na.rm=TRUE)[1,1]) else 0
  above <- if (source_max > 100) as.numeric(terra::global(r > 100, "sum", na.rm=TRUE)[1,1]) else 0
  if (source_min < 0 || source_max > 100) r <- terra::clamp(r, 0, 100, values=TRUE)
  non_na <- as.numeric(terra::global(!is.na(r), "sum", na.rm=FALSE)[1,1])
  if (!is.finite(non_na) || non_na < 1) stop("AgERA5 member contains no usable values: ", path, call.=FALSE)
  agera5_result(r,path,expected,selected,units,source_min,source_max,non_na,sum(is.na(terra::values(r,mat=FALSE))),below,above,list(netcdf_gdal_driver_available=driver_available,terra_names=as.character(terra::names(r)),terra_varnames=as.character(terra::varnames(r)),terra_time=if(is.null(source_time))character()else as.character(source_time),date_source=date_source,source_minimum=source_min,source_maximum=source_max),"terra_gdal",reader_attempted,"active GDAL runtime provides a NetCDF raster driver")
}

read_agera5_daily_member <- function(path, expected_date, variable_spec, fallback_date=NULL, filename_date=NULL) {
  driver_available <- terra_has_netcdf_driver()
  if (isTRUE(driver_available)) {
    terra_result <- tryCatch(read_agera5_daily_member_terra(path,expected_date,variable_spec,fallback_date,driver_available,"terra"), error=function(e)e)
    if (!inherits(terra_result,"error")) return(terra_result)
    if (!inherits(terra_result,"agera5_terra_open_error")) stop(terra_result)
    return(read_agera5_daily_member_ncdf4(path,expected_date,filename_date %||% archive_member_date(path),variable_spec,fallback_date,driver_available,"terra -> ncdf4"))
  }
  read_agera5_daily_member_ncdf4(path,expected_date,filename_date %||% archive_member_date(path),variable_spec,fallback_date,FALSE,"ncdf4")
}
agera5_update_member_manifest <- function(path, result) {
  manifest_path <- file.path(dirname(path), "archive_manifest.csv")
  if (!file.exists(manifest_path)) return(invisible(FALSE))
  m <- tryCatch(utils::read.csv(manifest_path, stringsAsFactors=FALSE), error=function(e) NULL)
  if (is.null(m) || !nrow(m) || !"extracted_path" %in% names(m)) return(invisible(FALSE))
  i <- which(normalizePath(m$extracted_path, winslash="/", mustWork=FALSE) == normalizePath(path, winslash="/", mustWork=FALSE))
  if (length(i) != 1L) return(invisible(FALSE))
  if (!"terra_readable" %in% names(m)) m$terra_readable <- FALSE
  if (!"netcdf_gdal_driver_available" %in% names(m)) m$netcdf_gdal_driver_available <- NA
  if (!"reader_attempted" %in% names(m)) m$reader_attempted <- NA_character_
  if (!"reader_selected" %in% names(m)) m$reader_selected <- NA_character_
  if (!"reader_selection_reason" %in% names(m)) m$reader_selection_reason <- NA_character_
  if (!"selected_source_variable" %in% names(m)) m$selected_source_variable <- NA_character_
  if (!"source_units" %in% names(m)) m$source_units <- NA_character_
  if (!"source_date" %in% names(m)) m$source_date <- NA_character_
  if (!"processing_candidate" %in% names(m)) m$processing_candidate <- FALSE
  rd <- result$reader_diagnostics %||% list(); m$terra_readable[[i]] <- identical(result$reader_selected,"terra_gdal"); m$netcdf_gdal_driver_available[[i]] <- rd$netcdf_gdal_driver_available %||% NA; m$reader_attempted[[i]] <- paste(result$reader_attempted %||% NA_character_, collapse="+"); m$reader_selected[[i]] <- result$reader_selected %||% NA_character_; m$reader_selection_reason[[i]] <- rd$reader_selection_reason %||% NA_character_; m$selected_source_variable[[i]] <- result$selected_source_variable; m$source_units[[i]] <- result$source_units; m$source_date[[i]] <- result$date; m$processing_candidate[[i]] <- TRUE
  utils::write.csv(m, manifest_path, row.names=FALSE); invisible(TRUE)
}
build_agera5_member_date_map <- function(member_dates, member_hashes, readers=list()) {
  if (!length(member_dates)) return(NULL)
  do.call(rbind, lapply(names(member_dates), function(path) {
    m <- tryCatch(utils::read.csv(file.path(dirname(path), "archive_manifest.csv"), stringsAsFactors=FALSE), error=function(e) NULL)
    i <- if (!is.null(m) && nrow(m) && "extracted_path" %in% names(m)) which(normalizePath(m$extracted_path,winslash="/",mustWork=FALSE)==normalizePath(path,winslash="/",mustWork=FALSE))[1] else NA_integer_
    row <- if (length(i) == 1L && !is.na(i)) m[i,,drop=FALSE] else NULL; reader <- readers[[path]] %||% list()
    data.frame(date=format(member_dates[[path]],"%Y-%m-%d"), source_path=path,
      archive_path=if(!is.null(row))row$archive_path[[1]]else NA_character_, archive_member=if(!is.null(row))row$member_name[[1]]else NA_character_,
      request_hash=member_hashes[[path]]%||%NA_character_, selected_source_variable=reader$selected_netcdf_variable%||%NA_character_,
      reader_selected=reader$reader_used%||%NA_character_, mapping_reason=if(!is.null(reader$reader_used))"validated extracted member"else"member validation failed", stringsAsFactors=FALSE)
  }))
}

agera5_request_dates <- function(request) {
  normalize_date_vector(request$raw_request_dates %||% sprintf("%s-%s-%s", request$year, request$month, request$day), "AgERA5 request dates")
}

agera5_archive_matches_request <- function(path, request) {
  if (!file.exists(path) || !identical(detect_container_type(path), "zip")) return(FALSE)
  listing <- tryCatch(utils::unzip(path, list=TRUE), error=function(e) NULL)
  if (is.null(listing) || !nrow(listing)) return(FALSE)
  members <- as.character(listing$Name)
  nc_members <- members[grepl("\\.(nc|netcdf)$", members, ignore.case=TRUE)]
  dates <- vapply(nc_members, archive_member_date, character(1))
  requested <- as.character(agera5_request_dates(request))
  length(nc_members) == length(requested) && !anyNA(dates) && !anyDuplicated(dates) && identical(sort(unname(dates)), sort(requested))
}

agera5_archive_candidates <- function(request, paths, include_active=TRUE) {
  active <- if (isTRUE(include_active) && dir.exists(paths$raw_dir)) list.files(paths$raw_dir, full.names=TRUE, recursive=FALSE) else character()
  partial_dir <- file.path(paths$raw_dir, ".partial")
  partial <- if (dir.exists(partial_dir)) list.files(partial_dir, full.names=TRUE, recursive=FALSE) else character()
  candidates <- c(active[!file.info(active)$isdir %in% TRUE], partial[!file.info(partial)$isdir %in% TRUE & !grepl("[.]part$", partial, ignore.case=TRUE)])
  unique(candidates[vapply(candidates, agera5_archive_matches_request, logical(1), request=request)])
}

agera5_finalize_archive <- function(candidate, request, paths, run_dir=NULL) {
  if (!agera5_archive_matches_request(candidate, request)) stop("AgERA5 candidate does not contain exactly the requested daily members", call.=FALSE)
  spec <- get_variable_spec("agera5_relhum_min")
  checksum <- digest::digest(file=candidate, algo="sha256")
  stem <- tools::file_path_sans_ext(basename(request$target))
  final_path <- file.path(paths$raw_dir, paste0(stem, ".zip"))
  if (file.exists(final_path) && !identical(digest::digest(file=final_path, algo="sha256"), checksum)) stop("A different AgERA5 archive already exists at deterministic destination: ", final_path, call.=FALSE)

  # Extraction is the content validation boundary. The archive is not active
  # until every requested member has passed variable/date checks.
  extracted_root <- paths$extracted_dir %||% file.path(paths$dataset_root, "extracted")
  fs::dir_create(extracted_root, recurse=TRUE)
  manifest <- extract_agera5_archive(candidate, extracted_root, request$request_hash, spec, run_dir)
  select_agera5_archive_members(manifest, agera5_request_dates(request))

  candidate_abs <- normalizePath(candidate, winslash="/", mustWork=TRUE)
  final_abs <- normalizePath(final_path, winslash="/", mustWork=FALSE)
  if (!identical(candidate_abs, final_abs)) {
    if (file.exists(final_path)) unlink(candidate_abs)
    else if (!file.rename(candidate_abs, final_path)) stop("Could not atomically promote AgERA5 archive: ", final_path, call.=FALSE)
  }
  final_abs <- normalizePath(final_path, winslash="/", mustWork=TRUE)
  if (!identical(digest::digest(file=final_abs, algo="sha256"), checksum)) stop("AgERA5 archive failed post-promotion verification", call.=FALSE)
  partial_dir <- file.path(paths$raw_dir, ".partial")
  partials <- if (dir.exists(partial_dir)) list.files(partial_dir, full.names=TRUE, recursive=FALSE) else character()
  for (p in partials[!file.info(partials)$isdir %in% TRUE & !grepl("[.]part$", partials, ignore.case=TRUE)]) {
    if (normalizePath(p, winslash="/", mustWork=FALSE) == final_abs) next
    if (identical(digest::digest(file=p, algo="sha256"), checksum)) unlink(p)
  }

  # Extraction was performed while the candidate could still be in .partial;
  # rewrite only the provenance path after the atomic raw promotion.
  manifest$archive_path <- final_abs
  manifest$archive_checksum <- checksum
  extracted_manifest <- file.path(extracted_root, request$request_hash, "archive_manifest.csv")
  utils::write.csv(manifest, extracted_manifest, row.names=FALSE)
  if (!is.null(run_dir)) utils::write.csv(manifest, file.path(run_dir, "archive_manifest.csv"), row.names=FALSE)
  list(final_path=final_abs, manifest=manifest, checksum=checksum)
}

agera5_download_row <- function(request, final_path, status, result=NULL, returned_path="", elapsed_seconds=0) {
  vr <- validate_downloaded_target(final_path, request)
  data.frame(target_filename=request$target, resolved_target_path=final_path, status=status, valid=vr$valid,
    exists=vr$exists, size=vr$size, format=vr$format, readable=vr$readable,
    netcdf_metadata_readable=vr$netcdf_metadata_readable, request_match=vr$request_match,
    failure_reason=if (vr$valid) "" else vr$failure_reason,
    returned_path=returned_path %||% "", elapsed_seconds=elapsed_seconds,
    warnings=if (!is.null(result) && "warnings" %in% names(result)) result$warnings[[1]] else "",
    error_class="", error_message="", stringsAsFactors=FALSE)
}

.download_cds_requests_before_archive_adapter <- download_cds_requests
download_cds_requests <- function(requests, ...) {
  if (!length(requests) || !any(vapply(requests, function(x) identical(x$adapter, "agera5"), logical(1)))) return(.download_cds_requests_before_archive_adapter(requests, ...))
  dots <- list(...); paths <- dots$paths; run_dir <- dots$run_dir; dry_run <- isTRUE(dots$dry_run %||% TRUE); overwrite <- isTRUE(dots$overwrite %||% FALSE)
  if (length(requests) != 1L || is.null(paths)) return(.download_cds_requests_before_archive_adapter(requests, ...))
  req <- requests[[1]]
  if (dry_run) return(.download_cds_requests_before_archive_adapter(requests, ...))

  staged <- if (!overwrite) agera5_archive_candidates(req, paths) else character()
  if (length(staged)) {
    finalized <- agera5_finalize_archive(staged[[1]], req, paths, run_dir)
    row <- agera5_download_row(req, finalized$final_path, "reused_existing", returned_path=staged[[1]])
    if (!is.null(run_dir)) { jsonlite::write_json(build_cds_api_payload(req), file.path(run_dir, "cds_api_payload.json"), pretty=TRUE, auto_unbox=TRUE); utils::write.csv(row, file.path(run_dir, "download_manifest.csv"), row.names=FALSE) }
    return(row)
  }

  result <- NULL; transfer_error <- NULL
  result <- tryCatch(.download_cds_requests_before_archive_adapter(requests, ...), error=function(e) { transfer_error <<- e; NULL })
  source <- if (!is.null(result) && nrow(result)) result$resolved_target_path[[1]] else NA_character_
  candidates <- if (!overwrite) agera5_archive_candidates(req, paths) else character()
  if (!is.na(source) && file.exists(source) && identical(detect_container_type(source), "zip")) candidates <- unique(c(source, candidates))
  if (length(candidates)) {
    finalized <- agera5_finalize_archive(candidates[[1]], req, paths, run_dir)
    returned <- if (!is.null(result) && nrow(result)) result$returned_path[[1]] else candidates[[1]]
    elapsed <- if (!is.null(result) && nrow(result)) result$elapsed_seconds[[1]] else 0
    status <- if (!is.null(result) && nrow(result) && identical(result$status[[1]], "downloaded")) "downloaded" else "reused_existing"
    row <- agera5_download_row(req, finalized$final_path, status, result, returned, elapsed)
    if (!is.null(run_dir)) utils::write.csv(row, file.path(run_dir, "download_manifest.csv"), row.names=FALSE)
    return(row)
  }
  if (!is.null(transfer_error)) stop(transfer_error)
  result
}

.read_era5_daily_layers_before_archive_adapter <- read_era5_daily_layers
read_era5_daily_layers <- function(path, expected_dates=NULL, variable_spec=NULL, raw_request_dates=NULL, dates_to_process=NULL, request_hash=NULL) {
  spec <- variable_spec %||% get_variable_spec("agera5_relhum_min")
  if (identical(spec$id, "agera5_relhum_min") && detect_download_format(path) %in% c("netcdf4_hdf5", "netcdf_classic")) {
    d <- dates_to_process %||% raw_request_dates %||% expected_dates
    d <- canonical_iso_dates(d, "AgERA5 member dates")
    if (length(d) != 1L) stop("Direct AgERA5 member reading requires one date", call.=FALSE)
    return(read_agera5_daily_member(path, d[[1]], spec, fallback_date=archive_member_date(path)))
  }
  if (detect_download_format(path) != "zip") return(.read_era5_daily_layers_before_archive_adapter(path,expected_dates,variable_spec,raw_request_dates,dates_to_process,request_hash))
  ex <- file.path(dirname(path), "..", "extracted")
  manifest <- extract_agera5_archive(path, ex, request_hash %||% digest::digest(file=path,algo="xxhash32"), spec)
  chosen <- select_agera5_archive_members(manifest, dates_to_process %||% raw_request_dates %||% expected_dates)
  date_map <- data.frame(date=chosen$date_from_filename, source_path=chosen$extracted_path,
    archive_path=chosen$archive_path, archive_member=chosen$member_name,
    request_hash=request_hash %||% chosen$request_hash,
    raw_request_start=min(chosen$date_from_filename), raw_request_end=max(chosen$date_from_filename),
    date_from_filename=chosen$date_from_filename, date_from_content=chosen$date_from_content,
    selected_source_variable=chosen$selected_netcdf_variable,
    mapping_reason=chosen$selection_reason, stringsAsFactors=FALSE)
  utils::write.csv(date_map, file.path(dirname(chosen$extracted_path[[1]]), "date_source_map.csv"), row.names=FALSE)
  pieces <- lapply(seq_len(nrow(chosen)), function(i) read_agera5_daily_member(chosen$extracted_path[[i]], chosen$date_from_filename[[i]], spec, fallback_date=chosen$date_from_content[[i]]))
  manifest$terra_readable[match(chosen$member_name, manifest$member_name)] <- TRUE
  manifest$selected_source_variable[match(chosen$member_name, manifest$member_name)] <- vapply(pieces, `[[`, character(1), "selected_source_variable")
  manifest$source_units[match(chosen$member_name, manifest$member_name)] <- vapply(pieces, `[[`, character(1), "source_units")
  manifest$source_date[match(chosen$member_name, manifest$member_name)] <- vapply(pieces, `[[`, character(1), "date")
  manifest$processing_candidate[match(chosen$member_name, manifest$member_name)] <- TRUE
  utils::write.csv(manifest, file.path(dirname(chosen$extracted_path[[1]]), "archive_manifest.csv"), row.names=FALSE)
  list(rasters=unlist(lapply(pieces, `[[`, "rasters"), recursive=FALSE), dates=as.Date(vapply(pieces, `[[`, character(1), "date")), decoded_dates=as.POSIXct(vapply(pieces, `[[`, character(1), "date"), tz="UTC"), reader_used=paste(unique(vapply(pieces, `[[`, character(1), "reader_selected")),collapse="+"), source_format="zip", selected_variable=vapply(pieces, `[[`, character(1), "selected_variable"), selected_netcdf_variable=vapply(pieces, `[[`, character(1), "selected_netcdf_variable"), selected_variable_alias=vapply(pieces, `[[`, character(1), "selected_variable_alias"), source_units=spec$source_units, source_units_original=spec$source_units, source_units_normalized=spec$source_units, output_units=spec$output_units, unit_conversion=spec$unit_conversion, source_value_minimum=min(vapply(pieces,function(x)x$source_minimum,numeric(1))), source_value_maximum=max(vapply(pieces,function(x)x$source_maximum,numeric(1))), reader_diagnostics=lapply(pieces, `[[`, "reader_diagnostics"), daily_statistic_source="AgERA5_precomputed_derived_indicator", daily_statistic=spec$daily_statistic, subdaily_frequency=spec$frequency)
}

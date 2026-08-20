detect_download_format <- function(path) detect_container_type(path)
decode_netcdf_time <- function(values, units, calendar=NULL) { if(is.null(calendar)||!length(calendar)||is.na(calendar)||!is.character(calendar)||!nzchar(calendar))calendar<-"standard"; if(!calendar%in%c("standard","gregorian","proleptic_gregorian"))stop("Unsupported NetCDF calendar: ",calendar,call.=FALSE); m<-regexec("^\\s*([A-Za-z]+)\\s+since\\s+([0-9]{4}-[0-9]{2}-[0-9]{2})(?:[ T]([0-9]{2}):([0-9]{2}):([0-9]{2}(?:\\.[0-9]+)?))?",as.character(units)); z<-regmatches(as.character(units),m)[[1]]; if(length(z)<3)stop("Unsupported NetCDF time units: ",units,call.=FALSE); mult<-switch(tolower(z[2]),seconds=1,minutes=60,hours=3600,days=86400,stop("Unsupported NetCDF time units: ",units,call.=FALSE)); origin<-as.POSIXct(paste(z[3],ifelse(length(z)>=4&&nzchar(z[4]),paste(z[4],z[5],z[6],sep=":"),"00:00:00")),tz="UTC"); as.POSIXct(origin+as.numeric(values)*mult,tz="UTC") }
inspect_netcdf_ncdf4 <- function(path) { if(!requireNamespace("ncdf4",quietly=TRUE))stop("ncdf4 is required"); nc<-ncdf4::nc_open(path); on.exit(ncdf4::nc_close(nc),add=TRUE); dims<-lapply(nc$dim,function(d)list(name=d$name,length=d$len,values=d$vals,units=d$units)); vars<-lapply(nc$var,function(v){a<-tryCatch(ncdf4::ncatt_get(nc,v$name,"long_name")$value,error=function(e)NULL); list(name=v$name,units=v$units,long_name=a,dimensions=vapply(v$dim,function(d)d$name,character(1)),dimension_lengths=vapply(v$dim,function(d)d$len,numeric(1)),data_signature=paste(vapply(v$dim,function(d)d$name,character(1)),collapse="|"),fill_value=v$missval,missing_value=tryCatch(ncdf4::ncatt_get(nc,v$name,"missing_value")$value,error=function(e)NULL),scale_factor=tryCatch(ncdf4::ncatt_get(nc,v$name,"scale_factor")$value,error=function(e)1),add_offset=tryCatch(ncdf4::ncatt_get(nc,v$name,"add_offset")$value,error=function(e)0))}); names(vars)<-vapply(nc$var,function(v)v$name,character(1)); coord_names<-names(dims); time_name<-coord_names[grepl("^(valid_time|time)$",coord_names,ignore.case=TRUE)][1]; lon_name<-coord_names[grepl("^(longitude|lon)$",coord_names,ignore.case=TRUE)][1]; lat_name<-coord_names[grepl("^(latitude|lat)$",coord_names,ignore.case=TRUE)][1]; time_units<-if(!is.na(time_name))dims[[time_name]]$units else NA_character_; cal<-if(!is.na(time_name))tryCatch(ncdf4::ncatt_get(nc,time_name,"calendar")$value,error=function(e)NULL)else NULL; if(!is.character(cal)||!length(cal)||is.na(cal)||!nzchar(cal))cal<-NULL; decoded<-if(!is.na(time_name))decode_netcdf_time(dims[[time_name]]$values,time_units,cal)else as.POSIXct(character()); list(path=path,format="netcdf4_hdf5",dimensions=dims,variables=vars,coordinate_variables=list(latitude=lat_name,longitude=lon_name,time=time_name),time_coordinate_name=time_name,time_units=time_units,time_calendar_original=cal,time_calendar_effective=cal%||%"standard",decoded_dates=as.Date(decoded,tz="UTC"),latitude_order=if(!is.na(lat_name)&&length(dims[[lat_name]]$values)>1)if(dims[[lat_name]]$values[1]<tail(dims[[lat_name]]$values,1))"ascending"else"descending"else NA_character_,longitude_order=if(!is.na(lon_name)&&length(dims[[lon_name]]$values)>1)if(dims[[lon_name]]$values[1]<tail(dims[[lat_name]]$values,1))"ascending"else"descending"else NA_character_) }
inspect_netcdf_file <- function(path) inspect_netcdf_ncdf4(path)
select_era5_temperature_variable <- function(nc_metadata) resolve_netcdf_variable(nc_metadata,get_variable_spec("era5_mintemp"))
resolve_netcdf_variable <- function(nc_metadata, variable_spec) { exact<-intersect(variable_spec$netcdf_variable_names,names(nc_metadata$variables)); if(length(exact)==1L)return(exact); if(length(exact)>1L){s<-lapply(exact,function(n)nc_metadata$variables[[n]]$data_signature%||%nc_metadata$variables[[n]]$dimensions);if(length(unique(s))>1)stop("NetCDF variable aliases are ambiguous and refer to different data",call.=FALSE);return(exact[[1]])}; norm<-function(x)gsub("[^a-z0-9]","",tolower(x%||%"")); candidates<-names(nc_metadata$variables)[vapply(nc_metadata$variables,function(v)norm(v$long_name)==norm(variable_spec$long_name),logical(1))]; if(length(candidates)!=1L)stop(if(length(candidates))"Multiple NetCDF variables remain after metadata resolution" else paste("No NetCDF variable matched aliases:",paste(variable_spec$netcdf_variable_names,collapse=", ")),call.=FALSE); candidates[[1]] }
read_daily_netcdf <- function(path, variable_spec, raw_request_dates, dates_to_process=NULL, request_hash=NULL) {
  md <- inspect_netcdf_ncdf4(path)
  selected <- resolve_netcdf_variable(md, variable_spec)
  v <- md$variables[[selected]]
  original <- v$units
  normalized <- normalize_source_units(original)
  expected <- normalize_source_units(variable_spec$source_units)
  if (!identical(normalized, expected) && !(variable_spec$id == "era5_lai_low" && tolower(trimws(as.character(original))) %in% c("1", "dimensionless"))) stop("Selected variable has incompatible source units: ", original, call.=FALSE)
  dims <- v$dimensions
  tn <- intersect(dims, c("valid_time", "time", "date"))[1]
  ln <- intersect(dims, c("longitude", "lon"))[1]
  an <- intersect(dims, c("latitude", "lat"))[1]
  if (any(is.na(c(tn, ln, an)))) stop("Selected NetCDF variable must have longitude, latitude, and time dimensions", call.=FALSE)
  nc <- ncdf4::nc_open(path)
  on.exit(ncdf4::nc_close(nc), add=TRUE)
  lon <- ncdf4::ncvar_get(nc, ln)
  lat <- ncdf4::ncvar_get(nc, an)
  tv <- ncdf4::ncvar_get(nc, tn)
  a <- ncdf4::ncvar_get(nc, selected)
  perm <- match(c(ln, an, tn), dims)
  if (length(dim(a)) != 3L || anyNA(perm)) stop("Selected NetCDF variable must have longitude, latitude, and time dimensions", call.=FALSE)
  a <- aperm(a, perm)
  fill <- c(v$fill_value, v$missing_value)
  if (length(fill) && any(is.finite(fill))) a[a %in% fill] <- NA_real_
  sf <- as.numeric(v$scale_factor)
  ao <- as.numeric(v$add_offset)
  if (!is.na(sf) && sf != 1) a <- a * sf
  if (!is.na(ao) && ao != 0) a <- a + ao
  decoded <- as.Date(decode_netcdf_time(tv, md$time_units, md$time_calendar_effective))
  expected_dates <- normalize_date_vector(raw_request_dates, "raw_request_dates")
  if (!identical(format(decoded, "%Y-%m-%d"), format(expected_dates, "%Y-%m-%d"))) stop("Raw date coverage mismatch; missing or extra request dates", call.=FALSE)
  selected_dates <- normalize_date_vector(dates_to_process %||% expected_dates, "dates_to_process")
  idx <- match(format(selected_dates, "%Y-%m-%d"), format(decoded, "%Y-%m-%d"))
  if (anyNA(idx)) stop("Selected dates are absent from raw", call.=FALSE)
  source <- validate_source_values(a, variable_spec)
  a <- source$values
  dx <- if (length(lon) > 1) median(diff(sort(lon))) else 1
  dy <- if (length(lat) > 1) median(diff(sort(lat))) else 1
  ras <- lapply(idx, function(k) {
    mm <- t(a[, , k, drop=TRUE])
    if (length(lat) > 1 && lat[1] < tail(lat, 1)) mm <- mm[nrow(mm):1, , drop=FALSE]
    if (length(lon) > 1 && lon[1] > tail(lon, 1)) mm <- mm[, ncol(mm):1, drop=FALSE]
    convert_source_units(terra::rast(mm, extent=terra::ext(min(lon)-abs(dx)/2, max(lon)+abs(dx)/2, min(lat)-abs(dy)/2, max(lat)+abs(dy)/2), crs="EPSG:4326"), variable_spec, original)
  })
  list(rasters=ras,dates=selected_dates,decoded_dates=decoded,reader_used="ncdf4",source_format=md$format,selected_variable=selected,selected_netcdf_variable=selected,selected_variable_alias=selected,data_variable_dimensions=dims,dimension_names=dims,dimension_lengths=unname(v$dimension_lengths),dimension_order=dims,latitude_direction=md$latitude_order,longitude_direction=md$longitude_order,longitude_convention=if(all(lon>=0))"0_360"else"-180_180",time_coordinate_name=tn,time_coordinate_units=md$time_units,time_coordinate_raw_values=tv,time_coordinate_calendar_effective=md$time_calendar_effective,source_units=original,source_units_original=original,source_units_normalized=normalized,output_units=variable_spec$output_units,unit_conversion=variable_spec$unit_conversion,source_value_raw_minimum=source$source_raw_minimum,source_value_raw_maximum=source$source_raw_maximum,source_value_minimum=source$source_minimum,source_value_maximum=source$source_maximum,source_lower_clamped_count=source$source_lower_clamped_count,source_upper_clamped_count=source$source_upper_clamped_count,source_validation_tolerance=source$source_validation_tolerance,variable_spec=variable_spec,daily_statistic_source=if(variable_spec$id=="agera5_relhum_min")"AgERA5_precomputed_derived_indicator"else if(variable_spec$id=="era5_lai_low")"ERA5_monthly_climatology"else"cds_daily_statistics",daily_statistic=variable_spec$daily_statistic,subdaily_frequency=variable_spec$frequency)
}
read_era5_daily_with_ncdf4 <- function(path,variable="t2m",expected_dates=NULL,variable_spec=NULL,raw_request_dates=NULL,dates_to_process=NULL,request_hash=NULL) { spec<-variable_spec%||%get_variable_spec(variable); read_daily_netcdf(path,spec,raw_request_dates%||%expected_dates,dates_to_process%||%raw_request_dates%||%expected_dates,request_hash) }
read_era5_daily_layers <- function(path,expected_dates=NULL,variable_spec=NULL,raw_request_dates=NULL,dates_to_process=NULL,request_hash=NULL) {fmt<-detect_download_format(path);if(fmt=="netcdf4_hdf5"||fmt=="netcdf_classic")return(read_daily_netcdf(path,variable_spec%||%get_variable_spec("era5_mintemp"),raw_request_dates%||%expected_dates,dates_to_process%||%raw_request_dates%||%expected_dates,request_hash));if(fmt=="zip"){ex<-file.path(dirname(path),"extracted");fs::dir_create(ex,recurse=TRUE);normalize_downloaded_file(path,ex);f<-list.files(ex,pattern="\\.(nc|netcdf)$",full.names=TRUE,recursive=TRUE,ignore.case=TRUE)[1];if(is.na(f))stop("ZIP contains no NetCDF files");return(read_era5_daily_layers(f,expected_dates,variable_spec,raw_request_dates,dates_to_process,request_hash))};stop("Unsupported or non-NetCDF raw format: ",fmt,call.=FALSE)}
discover_netcdf_files <- function(path){if(detect_download_format(path)%in%c("netcdf4_hdf5","netcdf_classic"))return(path);character()}
normalize_downloaded_file <- function(path,extraction_dir){if(detect_download_format(path)!="zip")return(discover_netcdf_files(path));fs::dir_create(extraction_dir,recurse=TRUE);utils::unzip(path,exdir=extraction_dir);list.files(extraction_dir,pattern="\\.nc4?$",full.names=TRUE,recursive=TRUE,ignore.case=TRUE)}

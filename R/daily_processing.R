extract_daily_layers <- function(nc_file, expected_variable="2m_temperature", variable_spec=NULL) read_era5_daily_layers(nc_file, variable_spec=variable_spec %||% get_variable_spec(expected_variable))

standardize_daily_raster <- function(source,template,boundary=NULL,resampling_method="bilinear",mask_to_boundary=FALSE,mask_to_template=TRUE) {
  if(!requireNamespace("terra",quietly=TRUE)) stop("terra is required")
  out <- terra::project(source,template,method=resampling_method)
  if(mask_to_template) out <- terra::mask(out,template)
  if(mask_to_boundary&&!is.null(boundary)) out <- terra::mask(out,terra::vect(boundary))
  out
}

promote_validated_daily_output <- function(raster, output_path, template, spec, config, tmp_path = NULL) {
  tmp_path <- tmp_path %||% tempfile(pattern=paste0(".",basename(output_path),".tmp-"),tmpdir=dirname(output_path),fileext=".tif")
  backup_path <- NULL
  on.exit({
    if(file.exists(tmp_path)) unlink(tmp_path,force=TRUE)
    if(!is.null(backup_path)&&file.exists(backup_path)&&!file.exists(output_path)) file.rename(backup_path,output_path)
  }, add=TRUE)
  terra::writeRaster(raster,tmp_path,overwrite=TRUE,wopt=list(datatype=config$processing$datatype,gdal=c("COMPRESS=DEFLATE","PREDICTOR=3","TILED=YES"),NAflag=config$processing$naflag))
  if(!file.exists(tmp_path)) stop("Temporary raster was not created",call.=FALSE)
  check <- validate_raster_against_template(tmp_path,template,spec$hard_valid_range,TRUE,spec)
  if(!check$valid) stop(paste0("Temporary raster validation failed: ",check$message),call.=FALSE)
  reopened <- tryCatch(terra::rast(tmp_path),error=function(e)e)
  if(inherits(reopened,"error")) stop("Temporary raster could not be reopened: ",conditionMessage(reopened),call.=FALSE)
  reopened_check <- validate_raster_against_template(reopened,template,spec$hard_valid_range,TRUE,spec)
  if(!reopened_check$valid) stop(paste0("Reopened temporary raster validation failed: ",reopened_check$message),call.=FALSE)
  if(file.exists(output_path)) {
    backup_path <- tempfile(pattern=paste0(".",basename(output_path),".previous-"),tmpdir=dirname(output_path),fileext=".tif")
    if(!file.rename(output_path,backup_path)) stop("Could not stage existing daily output for replacement: ",output_path,call.=FALSE)
  }
  promoted <- file.rename(tmp_path,output_path)
  if(!promoted) {
    if(!is.null(backup_path)&&file.exists(backup_path)) file.rename(backup_path,output_path)
    stop("Could not atomically promote daily output: ",output_path,call.=FALSE)
  }
  final_check <- validate_raster_against_template(output_path,template,spec$hard_valid_range,TRUE,spec)
  if(!final_check$valid) {
    unlink(output_path,force=TRUE)
    if(!is.null(backup_path)&&file.exists(backup_path)) file.rename(backup_path,output_path)
    stop(paste0("Final daily output validation failed: ",final_check$message),call.=FALSE)
  }
  if(!is.null(backup_path)&&file.exists(backup_path)) unlink(backup_path,force=TRUE)
  list(path=output_path,sha256=digest::digest(file=output_path,algo="sha256"),minimum=final_check$minimum,maximum=final_check$maximum,finite_count=final_check$n)
}

process_downloaded_variable <- function(raw_files,daily_dir,template_path,bbox_path,config,variable_spec=NULL,overwrite_dates=NULL,expected_dates=NULL,run_dir=NULL,run_expected_dates=NULL,request_manifest=NULL,date_source_map=NULL) {
  coverage_records <- list(); coverage_state <- new.env(parent = emptyenv()); coverage_state$records <- coverage_records; agera5_diagnostics <- list(); agera5_member_map <- NULL
  append_coverage_record <- function(record) { coverage_state$records <- c(coverage_state$records, list(record)); invisible(record) }
  spec <- variable_spec %||% get_variable_spec(config$project$dataset_id,config)
  lineage <- config$era5land_lineage %||% list()
  expected_dates <- normalize_date_vector(expected_dates, "expected_dates")
  run_expected_dates <- normalize_date_vector(run_expected_dates %||% expected_dates,"run_expected_dates")
  overwrite_dates <- if (is.null(overwrite_dates)) NULL else normalize_date_vector(overwrite_dates, "overwrite_dates")
  agera5_member_dates <- setNames(as.Date(character()),character()); agera5_member_hashes <- setNames(character(),character())
  if(identical(spec$id,"agera5_relhum_min")&&length(raw_files)) {
    raw_formats <- vapply(raw_files,detect_download_format,character(1))
    for(f in raw_files[raw_formats=="zip"]) {
      req0 <- if(!is.null(request_manifest)) request_entry_for_raw(f,request_manifest) else NULL
      rh <- if(!is.null(req0)) req0$request_hash else digest::digest(file=f,algo="xxhash32")
      md0 <- extract_agera5_archive(f,file.path(dirname(f),"..","extracted"),rh,spec)
      requested0 <- if(!is.null(date_source_map)) selected_dates_for_raw(f,date_source_map) else if(!is.null(req0)) build_request_dates(req0) else run_expected_dates
      chosen0 <- select_agera5_archive_members(md0,requested0)
      for(j in seq_len(nrow(chosen0))) { p0 <- chosen0$extracted_path[[j]]; agera5_member_dates[[p0]] <- normalize_date_vector(chosen0$date_from_filename[[j]], "AgERA5 member date"); agera5_member_hashes[[p0]] <- rh }
    }
    raw_files <- unique(c(raw_files[raw_formats!="zip"],names(agera5_member_dates)))
    if(length(agera5_member_dates)) date_source_map <- NULL
  }
  if(!is.null(request_manifest)&&!is.null(date_source_map)) validate_date_source_map(date_source_map,raw_files,request_manifest)
  fs::dir_create(daily_dir,recurse=TRUE); template <- terra::rast(template_path); support_info <- if (exists("era5land_support_mask_info", mode = "function")) era5land_support_mask_info(config, template, required = FALSE) else NULL; support_mask <- if (is.null(support_info)) NULL else support_info$mask; before <- template_fingerprint(template)
  boundary <- if(isTRUE(config$spatial$mask_to_boundary)) sf::st_read(bbox_path,quiet=TRUE) else NULL
  written <- reused <- replaced <- failed <- character(); readers <- list(); processing_failures <- list(); date_results <- list()
  record_date_result <- function(date_result) {
    if (!is.list(date_result) || !length(date_result$date)) {
      stop("A date result must contain a non-missing date", call. = FALSE)
    }
    key <- canonical_iso_dates(date_result$date[[1L]], "date_result$date")
    if (length(key) != 1L) stop("A date result must contain exactly one date", call. = FALSE)
    key <- key[[1L]]
    duplicate_date_fields <- which(names(date_result) == "date")
    if (length(duplicate_date_fields) > 1L) date_result <- date_result[-duplicate_date_fields[-1L]]
    date_result$date <- key
    current <- date_results
    current[[key]] <- date_result
    date_results <<- current
    invisible(date_result)
  }
  date_result_from_coverage <- function(date, status, output_path, coverage_result = NULL, failure_stage = NULL, failure_message = NULL) {
    date <- canonical_iso_dates(date, "date result date")
    if (length(date) != 1L) stop("A date result must contain exactly one date", call. = FALSE)
    list(
      date = date[[1L]], status = status, output_path = output_path,
      pre_repair_missing_cells = if (is.null(coverage_result)) NA_integer_ else coverage_result$missing_inside_pre_repair_count,
      pre_repair_missing_supported_cells = if (is.null(coverage_result)) NA_integer_ else coverage_result$missing_inside_pre_repair_supported_count,
      structurally_unsupported_cells = if (is.null(coverage_result)) NA_integer_ else coverage_result$structurally_unsupported_cells,
      component_count = if (is.null(coverage_result)) NA_integer_ else length(coverage_result$component_records),
      repaired_cells = if (is.null(coverage_result)) NA_integer_ else coverage_result$repair_count,
      post_repair_missing_cells = if (is.null(coverage_result)) NA_integer_ else coverage_result$missing_inside_post_repair_count,
      post_repair_unexpected_missing_cells = if (is.null(coverage_result)) NA_integer_ else coverage_result$missing_inside_post_repair_count,
      outside_mask_cells = if (is.null(coverage_result)) NA_integer_ else coverage_result$outside_mask_count,
      outside_support_finite_cells = if (is.null(coverage_result)) NA_integer_ else coverage_result$outside_support_finite_count,
      coverage = if (is.null(coverage_result)) NULL else coverage_result$diagnostics,
      failure_stage = failure_stage, failure_message = failure_message
    )
  }
  condition_details <- function(e) {
    call <- tryCatch(conditionCall(e), error = function(err) NULL)
    list(condition_class = class(e), condition_message = conditionMessage(e), condition_call = if (is.null(call)) NULL else paste(deparse(call), collapse = " "),
      traceback = substr(paste(vapply(sys.calls(), function(x) paste(deparse(x), collapse = " "), character(1)), collapse = " <- "), 1L, 8000L))
  }
  is_undated_failure <- function(date) {
    while (is.list(date) && length(date) == 1L) date <- date[[1L]]
    if (is.null(date)) return(TRUE)
    if (length(date) != 1L) return(FALSE)
    if (inherits(date, c("Date", "POSIXct", "POSIXlt")) || is.atomic(date)) return(isTRUE(is.na(date)[[1L]]))
    FALSE
  }
  add_failure <- function(raw_path,date=NULL,step,e=NULL,metadata=list(),coverage_failure_message=NULL,error_details=NULL) {
    undated <- is_undated_failure(date)
    key_date <- if (undated) NA_character_ else canonical_iso_dates(date, "processing failure date")
    if (!undated && length(key_date) != 1L) stop("A processing failure must contain exactly one date", call. = FALSE)
    normalized_date <- if (undated) NULL else normalize_date_vector(key_date, "processing failure date")
    candidate_output_path <- if (undated) NULL else file.path(daily_dir,daily_output_filename(spec,normalized_date))
    error_details <- error_details %||% condition_details(e); if (!isTRUE(nzchar(error_details$condition_message %||% "")) && isTRUE(nzchar(coverage_failure_message %||% ""))) error_details$condition_message <- coverage_failure_message
    z <- c(list(raw_path=raw_path,date=if(undated) NA_character_ else key_date[[1L]],product_id=spec$id,variable_id=spec$id,stage=step,processing_step=step,selected_netcdf_variable=metadata$selected_variable %||% spec$netcdf_variable_names[[1]],source_units=metadata$source_units_original %||% metadata$source_units %||% spec$source_units,source_member=metadata$source_member %||% NULL,source_alias=metadata$source_alias %||% NULL,candidate_output_path=candidate_output_path,diagnostic_directory=if(is.null(run_dir)) NULL else file.path(run_dir,"diagnostics","coverage"),warnings=metadata$warnings %||% character(),coverage_diagnostics=metadata$coverage_diagnostics %||% NULL,error_message=error_details$condition_message %||% ""), error_details)
    processing_failures[[length(processing_failures)+1L]] <<- z
    if(identical(spec$id,"agera5_relhum_min")) agera5_diagnostics[[length(agera5_diagnostics)+1L]] <<- c(list(member_path=raw_path,terra_readable=FALSE,expected_date=z$date),z)
    failed <<- c(failed,if(undated) raw_path else candidate_output_path)
    invisible(z)
  }
  record_netcdf_read_failure <- function(raw_path, failure_dates, e) {
    original_error <- condition_details(e)
    failure_index <- length(processing_failures) + 1L
    z <- tryCatch(
      add_failure(raw_path, NULL, "netcdf_read", error_details = original_error),
      error = function(bookkeeping_error) {
        diagnostic_error <- tryCatch(condition_details(bookkeeping_error), error = function(details_error) list(condition_class = class(bookkeeping_error), condition_message = conditionMessage(bookkeeping_error), condition_call = NULL, traceback = NULL))
        fallback <- c(list(raw_path=raw_path,date=NA_character_,product_id=spec$id,variable_id=spec$id,stage="netcdf_read",processing_step="netcdf_read",candidate_output_path=NULL,diagnostic_recording_error=diagnostic_error),original_error)
        processing_failures[[failure_index]] <<- fallback
        failed <<- c(failed,raw_path)
        fallback
      }
    )
    diagnostic_errors <- list()
    for (failure_index_date in seq_along(failure_dates)) {
      failed_date <- failure_dates[[failure_index_date]]
      tryCatch({
        failed_date <- normalize_date_vector(failed_date, "failed processing date")
        output_path <- file.path(daily_dir,daily_output_filename(spec,failed_date))
        record_date_result(c(date_result_from_coverage(failed_date,"failed",output_path,failure_stage="netcdf_read",failure_message=original_error$condition_message),z))
      }, error = function(bookkeeping_error) {
        diagnostic_errors[[length(diagnostic_errors)+1L]] <<- tryCatch(condition_details(bookkeeping_error), error = function(details_error) list(condition_class = class(bookkeeping_error), condition_message = conditionMessage(bookkeeping_error), condition_call = NULL, traceback = NULL))
      })
    }
    if (length(diagnostic_errors)) {
      if (is.null(z$diagnostic_recording_error)) z$diagnostic_recording_error <- diagnostic_errors[[1L]]
      if (length(diagnostic_errors) > 1L) z$diagnostic_recording_error$additional_errors <- diagnostic_errors[-1L]
      processing_failures[[failure_index]] <<- z
    }
    invisible(z)
  }
  coverage_failure_message_for <- function(coverage_result) {
    reasons <- unique(Filter(function(x) is.character(x) && length(x) == 1L && !is.na(x) && nzchar(x), vapply(coverage_result$component_records, function(x) x$repair_failure_reason %||% "", character(1))))
    scalar_or <- function(x, default = 0L) if (length(x)) x[[1L]] else default
    sprintf("coverage_repair_incomplete: %d pre-repair missing; %d target-grid repairable; %d source-fallback attempted; %d unresolved after fallback; outside_mask_count=%d; repair_failure_reasons=%s", scalar_or(coverage_result$missing_inside_pre_repair_count), scalar_or(coverage_result$diagnostics$target_grid_supported_count), scalar_or(coverage_result$diagnostics$source_fallback_attempted_count), scalar_or(coverage_result$unresolved_count), scalar_or(coverage_result$outside_mask_count), if(length(reasons)) paste(reasons, collapse = ";") else "not_available")
  }
  if(!length(raw_files)&&length(run_expected_dates)) {
    existing_inv <- inventory_daily_products(daily_dir,spec$daily_filename_prefix,template_path,TRUE,config)
    reused <- existing_inv$path[existing_inv$observed_valid%in%TRUE&existing_inv$date%in%run_expected_dates]
  }
  for(f in raw_files) {
    req <- if(!is.null(request_manifest)) tryCatch(request_entry_for_raw(f,request_manifest),error=function(e)NULL) else NULL
    raw_request_dates <- normalize_date_vector(if(!is.null(req)) build_request_dates(req) else if(identical(spec$id,"agera5_relhum_min")&&!is.null(agera5_member_dates[[f]])) agera5_member_dates[[f]] else run_expected_dates, "raw_request_dates")
    dates_to_process <- normalize_date_vector(if(!is.null(date_source_map)) selected_dates_for_raw(f,date_source_map) else raw_request_dates, "dates_to_process")
    if(!length(dates_to_process)) next
     x <- tryCatch(read_era5_daily_layers(f,variable_spec=spec,raw_request_dates=raw_request_dates,dates_to_process=dates_to_process,request_hash=if(!is.null(req)) req$request_hash else if(f %in% names(agera5_member_hashes)) agera5_member_hashes[[f]] else NULL),error=function(e){ record_netcdf_read_failure(f,dates_to_process,e); NULL})
    if(is.null(x)) next
    x$dates <- normalize_date_vector(x$dates, "reader dates")
    readers[[f]] <- list(reader_used=x$reader_used,source_format=x$source_format,selected_variable=x$selected_variable %||% NA,selected_netcdf_variable=x$selected_netcdf_variable %||% x$selected_variable %||% NA,selected_variable_alias=x$selected_variable_alias %||% NA,data_variable_dimensions=x$data_variable_dimensions %||% x$dimension_names %||% character(),source_units=x$source_units %||% NA,source_units_original=x$source_units_original %||% x$source_units %||% NA,source_units_normalized=x$source_units_normalized %||% NA,output_units=x$output_units %||% spec$output_units,unit_conversion=x$unit_conversion %||% spec$unit_conversion,source_value_minimum=x$source_value_minimum %||% NA_real_,source_value_maximum=x$source_value_maximum %||% NA_real_,raw_request_dates=raw_request_dates,raw_request_hash=if(!is.null(req)) req$request_hash else if(f %in% names(agera5_member_hashes)) agera5_member_hashes[[f]] else NA_character_,raw_checksum=if(file.exists(f)) digest::digest(file=f,algo="sha256") else NA_character_,dates_to_process=dates_to_process,dates=x$dates,dimension_names=x$dimension_names %||% character(),dimension_lengths=x$dimension_lengths %||% numeric(),dimension_order=x$dimension_order %||% character(),decoded_dates=x$decoded_dates %||% x$dates,latitude_direction=x$latitude_direction %||% NA,longitude_direction=x$longitude_direction %||% NA,longitude_convention=x$longitude_convention %||% NA,time_coordinate_name=x$time_coordinate_name %||% NA,time_coordinate_units=x$time_coordinate_units %||% NA,time_coordinate_raw_values=x$time_coordinate_raw_values %||% numeric(),time_coordinate_calendar_effective=x$time_coordinate_calendar_effective %||% "standard",daily_statistic_source=x$daily_statistic_source %||% "cds_daily_statistics",daily_statistic=x$daily_statistic %||% spec$daily_statistic,subdaily_frequency=x$subdaily_frequency %||% spec$frequency)
    if(identical(spec$id,"agera5_relhum_min")) { agera5_update_member_manifest(f,x); agera5_diagnostics[[length(agera5_diagnostics)+1L]] <- list(member_path=f,terra_readable=identical(x$reader_selected,"terra_gdal"),n_layers=if(!is.null(x$rasters)) length(x$rasters) else NA_integer_,names=x$terra_names%||%character(),varnames=x$terra_varnames%||%character(),units=x$source_units%||%NA_character_,time=x$terra_time%||%character(),crs=x$source_crs%||%character(),resolution=x$source_resolution%||%numeric(),extent=x$source_extent%||%numeric(),source_minimum=x$source_minimum%||%NA_real_,source_maximum=x$source_maximum%||%NA_real_,expected_date=as.character(dates_to_process),decoded_date=as.character(x$dates),selected_variable=x$selected_source_variable%||%x$selected_variable%||%NA_character_,reader_selected=x$reader_selected%||%x$reader_used%||%NA_character_,reader_attempted=x$reader_attempted%||%NA_character_,reader_diagnostics=x$reader_diagnostics%||%list()) }
    for(i in seq_along(x$dates)) {
      d <- x$dates[i]; out <- file.path(daily_dir,daily_output_filename(spec,d)); existed_before <- file.exists(out); valid_before <- FALSE
       if(existed_before) { vr0 <- validate_daily_output(out,d,template,config,variable_spec=spec); valid_before <- isTRUE(vr0$valid); if(valid_before&&is.null(overwrite_dates)) { if(!out%in%reused) reused <- c(reused,out); record_date_result(date_result_from_coverage(d,"reused",out)); next } }
      if(!is.null(overwrite_dates)&&!(d%in%overwrite_dates)) next
      coverage_result <- NULL; tmp_path <- NULL; coverage_recorded <- FALSE; coverage_failure_message <- NULL
      tryCatch({
        bilinear <- terra::project(x$rasters[[i]],template,method=config$processing$resampling_method)
        nearest <- terra::project(x$rasters[[i]],template,method="near")
        coverage_result <- analyze_template_coverage(bilinear,nearest,x$rasters[[i]],template,mask_template=isTRUE(config$spatial$mask_to_template),maximum_repair_count=config$validation$coverage_max_repair_count%||%256L,maximum_repair_fraction=config$validation$coverage_max_repair_fraction%||%0.01,maximum_component_size=config$validation$coverage_max_component_size%||%4L,maximum_donor_radius_cells=config$coverage$local_target_radius_cells%||%config$validation$coverage_max_donor_radius_cells%||%2L,maximum_donor_radius_km=config$validation$coverage_max_donor_radius_km%||%NULL,donor_count=config$validation$coverage_donor_count%||%8L,maximum_source_buffer_km=config$coverage$source_buffer_max_km%||%config$validation$coverage_max_source_buffer_km%||%35,source_range=spec$hard_valid_range,diagnostics_dir=if(isTRUE(config$spatial$write_coverage_diagnostics)&&!is.null(run_dir)) file.path(run_dir,"diagnostics","coverage") else NULL,date=d,prefix=spec$daily_filename_prefix,support_mask=support_mask)
        append_coverage_record(c(list(date=as.character(d),variable_id=spec$id),coverage_result$diagnostics))
        coverage_recorded <- TRUE
        if(coverage_result$unresolved_count>0L&&isTRUE(config$spatial$require_complete_template_coverage%||%TRUE)) { coverage_failure_message <<- coverage_failure_message_for(coverage_result); stop(coverage_failure_message, call. = FALSE) }
        z <- coverage_result$raster; if(isTRUE(config$spatial$mask_to_boundary)&&!is.null(boundary)) z <- terra::mask(z,terra::vect(boundary))
        stats <- if(spec$id%in%c("era5_soilmoist","era5_lai_low","agera5_relhum_min")) normalize_output_values(terra::values(z,mat=FALSE),spec,config) else validate_variable_values(terra::values(z,mat=FALSE),spec,config$validation$hard_tolerance %||% 1e-6)
        terra::values(z) <- stats$values
        vr <- validate_raster_against_template(z,template,spec$hard_valid_range,TRUE,variable_spec=spec); if(!vr$valid) stop(vr$message,call.=FALSE)
        coverage <- validate_template_coverage(z,template,isTRUE(config$spatial$require_complete_template_coverage%||%TRUE),if(isTRUE(config$spatial$write_coverage_diagnostics)&&!is.null(run_dir)) file.path(run_dir,"diagnostics","coverage") else NULL,d,spec$daily_filename_prefix,support_mask=support_mask)
        final <- promote_validated_daily_output(z,out,template,spec,config,tmp_path)
        final_reopened <- terra::rast(out); final_check <- validate_raster_against_template(final_reopened,template,spec$hard_valid_range,TRUE,spec); if(!final_check$valid) stop(paste0("Final output reopen validation failed: ",final_check$message),call.=FALSE); final_coverage <- validate_template_coverage(final_reopened,template,TRUE,NULL,d,spec$daily_filename_prefix,support_mask=support_mask)
        records <- coverage_state$records; records[[length(records)]] <- c(records[[length(records)]], list(final_missing_inside_count=final_coverage$missing_inside_count,final_outside_mask_count=final_coverage$outside_mask_count,final_sha256=final$sha256,final_minimum=final$minimum,final_maximum=final$maximum)); coverage_state$records <- records
         meta <- c(list(variable_id=spec$id,short_name=spec$short_name,long_name=spec$long_name,model_alias=spec$model_alias%||%NULL,source_dataset=spec$dataset_short_name,source_variable=spec$cds_variable,netcdf_alias=readers[[f]]$selected_variable_alias,source_units=readers[[f]]$source_units,source_units_original=readers[[f]]$source_units_original,source_units_normalized=readers[[f]]$source_units_normalized,output_units=spec$output_units,unit_conversion=spec$unit_conversion,daily_statistic=spec$daily_statistic,weekly_statistic=spec$weekly_statistic,spatial_interpolation=spec$spatial_interpolation,source_family_id=lineage$source_family_id%||%NULL,request_hash=lineage$request_hash%||%NULL,request_start=lineage$request_start%||%NULL,request_end=lineage$request_end%||%NULL,source_member=lineage$source_member%||%NULL,source_alias=lineage$source_alias%||%NULL,source_archive_path=lineage$source_archive_path%||%NULL,source_map_rows=lineage$source_map_rows%||%NULL,daily_time_zone=lineage$daily_time_zone%||%spec$time_zone,daily_sampling_frequency=lineage$daily_sampling_frequency%||%spec$frequency,metadata_notes=spec$metadata_notes%||%NULL,coverage_repair_applied=coverage_result$repair_applied,coverage_repair_method=if(coverage_result$repair_applied) "bounded_nearest_neighbor_component_repair" else NULL,coverage_repair_count=coverage_result$repair_count,coverage_repair_fraction=coverage_result$repair_fraction,coverage_repaired_cell_ids=coverage_result$repaired_cell_ids,coverage_diagnostics=coverage_result$diagnostics,source_cell_count=coverage_result$source_cell_count,source_non_na_count=coverage_result$source_non_na_count,source_na_count=coverage_result$source_na_count,source_na_fraction=coverage_result$source_na_fraction,variable_spec_hash=spec$variable_spec_hash,template_sha256=template_fingerprint(template)$sha256,master_template_sha256=template_fingerprint(template)$sha256,era5land_support_mask_path=support_info$paths$support_mask%||%NULL,era5land_support_mask_sha256=support_info$support_mask_sha256%||%NULL,unsupported_cells_audit_path=support_info$paths$unsupported_cells_audit%||%NULL,unsupported_cells_audit_sha256=support_info$audit_sha256%||%NULL,structurally_unsupported_cell_count=support_info$unsupported_count%||%0L,structurally_unsupported_cell_ids=support_info$unsupported_cells%||%integer(),support_distance_threshold_km=support_info$support_distance_threshold_km%||%NULL,daily_statistic_source=x$daily_statistic_source%||%"cds_daily_statistics",source_minimum=readers[[f]]$source_value_minimum,source_maximum=readers[[f]]$source_value_maximum,temporal_character=spec$temporal_character%||%NULL,interannual_variability=spec$interannual_variability%||%NULL,daily_time_basis=spec$daily_time_basis%||%spec$time_zone,source_grid_degrees=spec$source_grid_degrees%||%NULL,spatial_processing=spec$spatial_processing%||%NULL,soft_range_warning=stats$soft_range_warning,output_minimum=stats$final_minimum,output_maximum=stats$final_maximum,non_na_count=stats$non_na_count,na_count=sum(is.na(stats$values)),clamped_low_count=stats$cells_clamped_low,clamped_high_count=stats$cells_clamped_high,output_sha256=final$sha256,output_reopened_valid=TRUE),stats[setdiff(names(stats),"values")])
         assert_json_serializable(meta,"daily sidecar metadata"); if (exists("era5land_atomic_write_json", mode = "function")) era5land_atomic_write_json(meta, paste0(out,".json")) else jsonlite::write_json(meta,paste0(out,".json"),auto_unbox=TRUE,pretty=TRUE,null="null")
         date_result <- date_result_from_coverage(d,"success",out,coverage_result)
         date_result$output_sha256 <- final$sha256
         date_result$output_minimum <- final$minimum
         date_result$output_maximum <- final$maximum
         record_date_result(date_result)
         if(existed_before&&!valid_before) replaced <- c(replaced,out) else written <- c(written,out)
       }, error=function(e) { if(!is.null(tmp_path)&&file.exists(tmp_path)) unlink(tmp_path); if(!coverage_recorded&&!is.null(coverage_result)) append_coverage_record(c(list(date=as.character(d),variable_id=spec$id),coverage_result$diagnostics)); metadata <- c(readers[[f]],list(coverage_diagnostics=if(!is.null(coverage_result)) coverage_result$diagnostics else NULL,source_member=if(!is.null(req)) req$target %||% NULL else NULL,source_alias=readers[[f]]$selected_variable_alias %||% NULL)); failure_stage <- if(!is.null(coverage_result)&&coverage_result$unresolved_count>0L) "coverage_repair" else "daily_output"; z <- add_failure(f,d,failure_stage,e,metadata,if(!is.null(coverage_result)&&coverage_result$unresolved_count>0L) coverage_failure_message_for(coverage_result) else coverage_failure_message); record_date_result(c(date_result_from_coverage(d,"failed",out,coverage_result,failure_stage,z$condition_message),z)) })
    }
  }
  if(identical(spec$id,"agera5_relhum_min")&&length(agera5_member_dates)) agera5_member_map <- build_agera5_member_date_map(agera5_member_dates,agera5_member_hashes,readers)
  if(!is.null(agera5_member_map)&&!is.null(run_dir)) utils::write.csv(agera5_member_map,file.path(run_dir,"date_source_map.csv"),row.names=FALSE)
  if(identical(spec$id,"agera5_relhum_min")&&!is.null(run_dir)) tryCatch({assert_json_serializable(agera5_diagnostics,"AgERA5 member diagnostics");jsonlite::write_json(agera5_diagnostics,file.path(run_dir,"agera5_member_diagnostic.json"),pretty=TRUE,auto_unbox=TRUE)},error=function(e) warning("Could not serialize AgERA5 diagnostics: ",conditionMessage(e),call.=FALSE))
  if(!identical(before,template_fingerprint(template))) stop("Template fingerprint changed during processing")
  stopifnot(!length(intersect(written,reused)),!length(intersect(written,replaced)),!length(intersect(reused,replaced)))
  coverage_records <- coverage_state$records
  cov_sum <- function(field, default=NA_real_) { values <- vapply(coverage_records,function(x) as.numeric(x[[field]] %||% default),numeric(1)); if(!length(values)||all(is.na(values))) NA_real_ else sum(values,na.rm=TRUE) }
   list(written=written,reused=reused,replaced=replaced,failed=failed,processing_failures=processing_failures,readers=readers,date_source_map=agera5_member_map,agera5_diagnostics=agera5_diagnostics,coverage_diagnostics=coverage_records,date_results=date_results,coverage_summary=list(requested_dates=length(run_expected_dates),processed_dates=length(written)+length(reused)+length(replaced)+length(failed),master_template_cells=if(is.null(support_info)) sum(!is.na(terra::values(template,mat=FALSE))) else support_info$master_template_cells,era5land_supported_cells=if(is.null(support_info)) sum(!is.na(terra::values(template,mat=FALSE))) else support_info$era5land_supported_cells,supported_cell_count=if(is.null(support_info)) sum(!is.na(terra::values(template,mat=FALSE))) else support_info$era5land_supported_cells,structurally_unsupported_cells=if(is.null(support_info)) 0L else support_info$unsupported_count,pre_repair_missing_supported_cells=cov_sum("missing_inside_pre_repair_supported_count"),repaired_supported_cells=cov_sum("repair_count"),post_repair_unexpected_missing_cells=cov_sum("missing_inside_post_repair_count"),outside_support_finite_cells=cov_sum("outside_support_finite_count"),pre_repair_missing_cells=cov_sum("missing_inside_pre_repair_count"),repaired_cells=cov_sum("repair_count"),post_repair_missing_cells=cov_sum("missing_inside_post_repair_count"),outside_mask_cells=cov_sum("outside_mask_count")),variable_spec_hash=spec$variable_spec_hash,support_provenance=if(is.null(support_info)) list() else list(master_template_path=support_info$master_template_path,master_template_sha256=support_info$master_template_sha256,era5land_support_mask_path=support_info$paths$support_mask,era5land_support_mask_sha256=support_info$support_mask_sha256,unsupported_cells_audit_path=support_info$paths$unsupported_cells_audit,unsupported_cells_audit_sha256=support_info$audit_sha256,structurally_unsupported_cell_count=support_info$unsupported_count,structurally_unsupported_cell_ids=support_info$unsupported_cells,support_distance_threshold_km=support_info$support_distance_threshold_km))
}

process_downloaded_mintemp <- function(raw_files,daily_dir,template_path,bbox_path,config,overwrite_dates=NULL,expected_dates=NULL,run_dir=NULL) process_downloaded_variable(raw_files,daily_dir,template_path,bbox_path,config,get_variable_spec("era5_mintemp",config),overwrite_dates,expected_dates,run_dir)

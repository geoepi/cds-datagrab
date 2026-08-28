validate_raster_against_template <- function(raster, template, value_range=c(-100,70), exact_geometry=TRUE, variable_spec=NULL) {
  r <- tryCatch(if(is.character(raster)) terra::rast(raster) else raster, error=function(e)e)
  if(inherits(r,"error")) return(list(valid=FALSE,message=conditionMessage(r)))
  if(terra::nlyr(r)!=1) return(list(valid=FALSE,message="expected one layer"))
  if(exact_geometry) { same<-identical(terra::crs(r),terra::crs(template))&&all(abs(as.vector(terra::ext(r))-as.vector(terra::ext(template)))<1e-9)&&all(abs(as.numeric(terra::res(r))-as.numeric(terra::res(template)))<1e-9)&&terra::nrow(r)==terra::nrow(template)&&terra::ncol(r)==terra::ncol(template)&&all(abs(as.numeric(terra::origin(r))-as.numeric(terra::origin(template)))<1e-9);if(!same)return(list(valid=FALSE,message="geometry does not match template")) }
  v<-as.numeric(terra::values(r,mat=FALSE));v<-v[is.finite(v)];if(!length(v))return(list(valid=FALSE,message="all values are NA"));if(any(v<value_range[1]|v>value_range[2]))return(list(valid=FALSE,message="values outside configured range"));stats<-if(!is.null(variable_spec))validate_variable_values(v,variable_spec)else NULL;list(valid=TRUE,message="ok",minimum=min(v),maximum=max(v),n=length(v),statistics=stats)
}
coverage_cell_neighbors <- function(r, cell) {
  rc <- terra::rowColFromCell(r, cell)
  rows <- max(1L, rc[1] - 1L):min(terra::nrow(r), rc[1] + 1L)
  cols <- max(1L, rc[2] - 1L):min(terra::ncol(r), rc[2] + 1L)
  as.integer(terra::cellFromRowColCombine(r, rows, cols))
}

find_nonserializable_objects <- function(x, path="root") {
  forbidden <- c("SpatRaster","SpatVector","sf","sfc","externalptr","connection","environment","function")
  cls <- class(x)
  if (any(cls %in% forbidden) || typeof(x) %in% c("externalptr","environment","closure","builtin","special")) return(list(list(path=path, class=cls, message=paste0(path, ": class ",paste(cls,collapse="/")," is not allowed in JSON metadata"))))
  if (is.list(x)) {
    out <- list()
    for (i in seq_along(x)) out <- c(out, find_nonserializable_objects(x[[i]], paste0(path,".",if(!is.null(names(x))&&nzchar(names(x)[i]))names(x)[i]else"[[",i,"]]")))
    return(out)
  }
  list()
}

assert_json_serializable <- function(x, context="object") {
  bad <- find_nonserializable_objects(x, context)
  if (length(bad)) stop(bad[[1]]$message, call.=FALSE)
  tryCatch({ jsonlite::toJSON(x, auto_unbox=TRUE, null="null", na="null"); invisible(TRUE) }, error=function(e) stop(sprintf("%s is not JSON serializable: %s",context,conditionMessage(e)),call.=FALSE))
}

coverage_component_sets <- function(r, cells) {
  cells <- as.integer(cells)
  if (!length(cells)) return(list())
  remaining <- cells
  components <- list()
  while (length(remaining)) {
    component <- integer()
    frontier <- remaining[[1L]]
    while (length(frontier)) {
      component <- unique(c(component, frontier))
      neighbours <- unique(unlist(lapply(frontier, function(cell) coverage_cell_neighbors(r, cell)), use.names = FALSE))
      frontier <- intersect(neighbours, remaining)
      frontier <- setdiff(frontier, component)
    }
    components[[length(components) + 1L]] <- sort(as.integer(component))
    remaining <- setdiff(remaining, component)
  }
  components
}

write_coverage_repair_diagnostics <- function(template, missing_pre, repaired, missing_post, outside_mask, diagnostic_dir, date = NULL, prefix = NULL) {
  if (is.null(diagnostic_dir)) return(character())
  fs::dir_create(diagnostic_dir, recurse = TRUE)
  stem <- if (is.null(date)) "output" else paste0(prefix %||% "daily", "_", format(as.Date(date), "%Y-%m-%d"))
  masks <- list(
    missing_inside_pre_repair = missing_pre,
    repaired_cells = repaired,
    missing_inside_post_repair = missing_post,
    outside_mask = outside_mask
  )
  paths <- vapply(names(masks), function(name) file.path(diagnostic_dir, paste0(stem, "_", name, ".tif")), character(1))
  for (name in names(masks)) {
    r <- template
    terra::values(r) <- ifelse(masks[[name]], 1, NA)
    terra::writeRaster(r, paths[[name]], overwrite = TRUE)
  }
  paths
}

analyze_template_coverage <- function(bilinear, nearest, source, template, mask_template=TRUE, maximum_repair_count=4L, maximum_repair_fraction=0.0005, maximum_component_size=4L, diagnostics_dir=NULL, date=NULL, prefix=NULL) {
  bilinear_unmasked <- bilinear
  nearest_unmasked <- nearest
  output_masked <- bilinear_unmasked
  if (mask_template) {
    output_masked <- terra::mask(bilinear_unmasked, template)
  }
  template_values <- terra::values(template, mat=FALSE)
  output_values <- terra::values(output_masked, mat=FALSE)
  bilinear_values <- terra::values(bilinear_unmasked, mat=FALSE)
  nearest_values <- terra::values(nearest_unmasked, mat=FALSE)
  template_valid <- !is.na(template_values)
  missing <- template_valid & is.na(output_values)
  xy <- if (any(missing)) terra::xyFromCell(template, which(missing)) else matrix(numeric(), ncol=2)
  source_points <- if (nrow(xy)) terra::project(terra::vect(xy, crs=terra::crs(template)), terra::crs(source)) else NULL
  source_xy <- if (!is.null(source_points)) terra::crds(source_points) else matrix(numeric(), ncol=2)
  source_extent <- terra::ext(source)
  source_values <- terra::values(source, mat=FALSE)
  source_cells <- if (nrow(source_xy)) terra::cellFromXY(source, source_xy) else integer()
  missing_cells <- which(missing)
  components <- coverage_component_sets(template, missing_cells)
  component_lookup <- integer(max(length(template_values), 1L))
  for (k in seq_along(components)) component_lookup[components[[k]]] <- k
  component_size <- if (length(missing_cells)) vapply(missing_cells, function(cell) length(components[[component_lookup[[cell]]]]), integer(1)) else integer()
  target_neighbors <- lapply(missing_cells, function(cell) setdiff(coverage_cell_neighbors(template, cell), cell))
  target_xy <- if (length(missing_cells)) terra::xyFromCell(template, unique(unlist(target_neighbors))) else matrix(numeric(), ncol=2)
  target_neighbor_values <- if (length(missing_cells)) lapply(target_neighbors, function(z) as.numeric(bilinear_values[z])) else list()
  details <- lapply(seq_along(source_cells), function(k) {
    cell <- source_cells[[k]]
    inside <- is.finite(cell) && source_xy[k,1] >= source_extent$xmin && source_xy[k,1] <= source_extent$xmax && source_xy[k,2] >= source_extent$ymin && source_xy[k,2] <= source_extent$ymax
    neighbors <- if (inside) coverage_cell_neighbors(source, cell) else integer()
    neighbor_values <- if (length(neighbors)) as.numeric(source_values[neighbors]) else numeric()
    bilinear_value <- bilinear_values[missing_cells[k]]
    nearest_value <- nearest_values[which(missing)[k]]
    target_cells <- target_neighbors[[k]]; target_values <- target_neighbor_values[[k]]; target_coords <- if(length(target_cells))terra::xyFromCell(template,target_cells)else matrix(numeric(),ncol=2); target_distances <- if(length(target_cells))sqrt(rowSums((target_coords-matrix(xy[k,],nrow=nrow(target_coords),ncol=2,byrow=TRUE))^2))else numeric(); finite_target <- is.finite(target_values); masked_target_values <- if(length(target_cells))as.numeric(output_values[target_cells])else numeric(); nearest_target_values <- if(length(target_cells))as.numeric(nearest_values[target_cells])else numeric(); classification <- if (!inside) "outside_source_support" else if (is.na(nearest_value) || !length(neighbor_values) || all(is.na(neighbor_values))) "source_nodata" else if (is.na(bilinear_value) && is.finite(nearest_value)) "bilinear_interpolation_artifact" else "unknown"
    list(cell_id=missing_cells[k], row=terra::rowFromCell(template, missing_cells[k]), column=terra::colFromCell(template, missing_cells[k]), template_x=xy[k,1], template_y=xy[k,2], longitude=NA_real_, latitude=NA_real_, template_value=template_values[missing_cells[k]], distance_to_projected_source_boundary=min(abs(source_xy[k,1]-source_extent$xmin),abs(source_xy[k,1]-source_extent$xmax),abs(source_xy[k,2]-source_extent$ymin),abs(source_xy[k,2]-source_extent$ymax)), bilinear_value=bilinear_value, nearest_value=nearest_value, source_cell=cell, source_neighbor_values=neighbor_values, source_neighbor_na_count=sum(is.na(neighbor_values)), inside_source_extent=inside, target_neighbor_cell_ids=target_cells, target_neighbor_rows=if(length(target_cells))terra::rowFromCell(template,target_cells)else integer(), target_neighbor_columns=if(length(target_cells))terra::colFromCell(template,target_cells)else integer(), target_neighbor_x=if(length(target_coords))target_coords[,1]else numeric(), target_neighbor_y=if(length(target_coords))target_coords[,2]else numeric(), target_neighbor_longitude=numeric(), target_neighbor_latitude=numeric(), target_neighbor_distances=target_distances, target_neighbor_values=target_values, target_neighbor_template_mask_values=if(length(target_cells))as.numeric(template_values[target_cells])else numeric(), masked_output_neighbor_values=masked_target_values, masked_output_neighbor_finite_count=sum(is.finite(masked_target_values)), masked_output_neighbor_na_count=sum(!is.finite(masked_target_values)), unmasked_bilinear_neighbor_finite_count=sum(finite_target), unmasked_bilinear_neighbor_na_count=sum(!finite_target), unmasked_nearest_neighbor_finite_count=sum(is.finite(nearest_target_values)), unmasked_nearest_neighbor_na_count=sum(!is.finite(nearest_target_values)), target_finite_neighbor_count=sum(finite_target), target_na_neighbor_count=sum(!finite_target), missing_component_size=component_size[k], classification=classification)
  })
  if (length(details)) {
    target_xy_all <- do.call(rbind,lapply(details,function(x)c(x$template_x,x$template_y)))
    lonlat <- terra::crds(terra::project(terra::vect(target_xy_all,crs=terra::crs(template)),"EPSG:4326"))
    for (k in seq_along(details)) { details[[k]]$longitude <- lonlat[k,1]; details[[k]]$latitude <- lonlat[k,2]; if(length(details[[k]]$target_neighbor_cell_ids)){q<-terra::crds(terra::project(terra::vect(cbind(details[[k]]$target_neighbor_x,details[[k]]$target_neighbor_y),crs=terra::crs(template)),"EPSG:4326"));details[[k]]$target_neighbor_longitude<-q[,1];details[[k]]$target_neighbor_latitude<-q[,2]}else{details[[k]]$target_neighbor_longitude<-numeric();details[[k]]$target_neighbor_latitude<-numeric()}}
    land <- vapply(details,function(x)identical(x$classification,"source_nodata")&&is.na(x$bilinear_value)&&is.na(x$nearest_value)&&x$source_neighbor_na_count==length(x$source_neighbor_values)&&x$missing_component_size==1L&&x$target_finite_neighbor_count>=4L,logical(1))
    for (k in which(land)) details[[k]]$classification <- "isolated_land_mask_mismatch"
  }
  artifact <- vapply(details, function(x) identical(x$classification, "bilinear_interpolation_artifact") && is.finite(x$nearest_value) && x$missing_component_size <= maximum_component_size, logical(1))
  land <- vapply(details, function(x) identical(x$classification, "isolated_land_mask_mismatch"), logical(1))
  repairable <- (artifact | land) & vapply(details, function(x) x$missing_component_size <= maximum_component_size, logical(1))
  repair_count <- sum(repairable)
  template_non_na <- sum(template_valid)
  repair_fraction <- if (template_non_na) repair_count / template_non_na else 0
  component_repairable <- vapply(components, function(component) {
    rows <- match(component, missing_cells)
    donor_ok <- vapply(rows, function(row) {
      (artifact[[row]] && is.finite(nearest_values[missing_cells[[row]]])) ||
        (land[[row]] && sum(is.finite(details[[row]]$target_neighbor_values)) > 0L)
    }, logical(1))
    length(component) <= maximum_component_size && length(rows) > 0L && all(repairable[rows]) && all(donor_ok)
  }, logical(1))
  repairable_cells <- repairable & vapply(missing_cells, function(cell) component_repairable[[component_lookup[[cell]]]], logical(1))
  repair_count <- sum(repairable_cells)
  repair_fraction <- if (template_non_na) repair_count / template_non_na else 0
  eligible <- length(details) > 0L && any(repairable_cells) && repair_count <= maximum_repair_count && repair_fraction <= maximum_repair_fraction
  repaired_cells <- if (eligible) missing_cells[repairable_cells] else integer()
  if (length(repaired_cells)) for (k in which(repairable)) {
    cell <- missing_cells[[k]]
    if (land[[k]]) {
      finite <- is.finite(details[[k]]$target_neighbor_values)
      output_values[[cell]] <- weighted.mean(details[[k]]$target_neighbor_values[finite], 1 / details[[k]]$target_neighbor_distances[finite])
    } else output_values[[cell]] <- nearest_values[[cell]]
  }
  terra::values(output_masked) <- output_values
  missing_post <- template_valid & is.na(output_values)
  outside_mask <- !template_valid & !is.na(output_values)
  classification_counts <- table(vapply(details, `[[`, character(1), "classification"))
  source_nodata_count <- sum(vapply(details, function(x) x$classification == "source_nodata", logical(1)))
  projection_created_nodata_count <- sum(vapply(details, function(x) x$classification == "bilinear_interpolation_artifact", logical(1)))
  land_mask_boundary_count <- sum(vapply(details, function(x) x$classification == "isolated_land_mask_mismatch", logical(1)))
  repaired_mask <- rep(FALSE, length(output_values)); repaired_mask[repaired_cells] <- TRUE
  diagnostics_paths <- write_coverage_repair_diagnostics(template, missing, repaired_mask, missing_post, outside_mask, diagnostics_dir, date, prefix)
  diagnostics <- list(details=details, template_non_na=template_non_na, missing_inside_count=length(missing_cells), repair_applied=length(repaired_cells)>0L, repair_method=if(any(land[repairable]))"local_final_grid_idw"else if(length(repaired_cells))"nearest_for_isolated_bilinear_na"else NULL, repair_count=length(repaired_cells), repair_fraction=repair_fraction, repaired_cell_ids=repaired_cells, unresolved_count=length(missing_cells)-length(repaired_cells), eligible=eligible, source_cell_count=length(source_values), source_non_na_count=sum(!is.na(source_values)), source_na_count=sum(is.na(source_values)), source_na_fraction=if(length(source_values))sum(is.na(source_values))/length(source_values)else 0)
  diagnostics$classification_counts <- as.list(classification_counts)
  diagnostics$source_nodata_count <- source_nodata_count
  diagnostics$projection_created_nodata_count <- projection_created_nodata_count
  diagnostics$land_mask_boundary_count <- land_mask_boundary_count
  diagnostics$repairable_count <- sum(repairable_cells)
  diagnostics$unrepairable_count <- sum(!repairable_cells)
  diagnostics$maximum_component_size <- maximum_component_size
  diagnostics$component_sizes <- vapply(components, length, integer(1))
  diagnostics$missing_inside_pre_repair_count <- sum(missing)
  diagnostics$missing_inside_post_repair_count <- sum(missing_post)
  diagnostics$outside_mask_count <- sum(outside_mask)
  diagnostics$coverage_diagnostic_paths <- diagnostics_paths
  list(raster=output_masked, diagnostics=diagnostics, details=details, repaired=length(repaired_cells)>0L, template_non_na=template_non_na, missing_inside_count=sum(missing), missing_inside_post_repair_count=sum(missing_post), outside_mask_count=sum(outside_mask), repair_applied=length(repaired_cells)>0L, repair_count=length(repaired_cells), repair_fraction=repair_fraction, repaired_cell_ids=repaired_cells, unresolved_count=sum(missing_post), eligible=eligible, source_cell_count=length(source_values), source_non_na_count=sum(!is.na(source_values)), source_na_count=sum(is.na(source_values)), source_na_fraction=if(length(source_values))sum(is.na(source_values)) / length(source_values) else 0, source_nodata_count=source_nodata_count, projection_created_nodata_count=projection_created_nodata_count, land_mask_boundary_count=land_mask_boundary_count, repairable_count=sum(repairable_cells), unrepairable_count=sum(!repairable_cells), maximum_component_size=maximum_component_size, component_sizes=vapply(components, length, integer(1)), coverage_diagnostic_paths=diagnostics_paths)
}

validate_template_coverage <- function(output,template,require_complete=TRUE,diagnostic_dir=NULL,date=NULL,prefix=NULL) {out<-if(is.character(output))terra::rast(output)else output;template_values<-terra::values(template,mat=FALSE);output_values<-terra::values(out,mat=FALSE);template_valid<-!is.na(template_values);output_valid<-!is.na(output_values);if(length(template_valid)!=length(output_valid))stop("Output and template cell counts differ",call.=FALSE);missing_inside<-template_valid&!output_valid;outside_mask<-!template_valid&output_valid;idx<-which(missing_inside);xy<-if(length(idx))terra::xyFromCell(template,idx)else matrix(numeric(),ncol=2);result<-list(template_non_na=sum(template_valid),output_non_na=sum(output_valid),missing_inside_count=sum(missing_inside),outside_mask_count=sum(outside_mask),complete=!any(missing_inside|outside_mask),missing_cell_indices=idx,missing_cell_details=if(length(idx))lapply(seq_along(idx),function(i)list(cell_id=idx[[i]],row=terra::rowFromCell(template,idx[[i]]),column=terra::colFromCell(template,idx[[i]]),template_x=xy[i,1],template_y=xy[i,2],longitude=xy[i,1],latitude=xy[i,2],template_value=template_values[idx[[i]]]))else list(),missing_x_range=if(length(idx))range(xy[,1])else c(NA_real_,NA_real_),missing_y_range=if(length(idx))range(xy[,2])else c(NA_real_,NA_real_));if(!is.null(diagnostic_dir)&&!result$complete){fs::dir_create(diagnostic_dir,recurse=TRUE);stem<-if(is.null(date))"output"else paste0(prefix%||%"mintemp","_",format(as.Date(date),"%Y-%m-%d"));m<-template;o<-template;terra::values(m)<-ifelse(missing_inside,1,NA);terra::values(o)<-ifelse(outside_mask,1,NA);result$coverage_diagnostic_paths<-c(missing_inside=file.path(diagnostic_dir,paste0(stem,"_missing_inside.tif")),outside_mask=file.path(diagnostic_dir,paste0(stem,"_outside_mask.tif")));terra::writeRaster(m,result$coverage_diagnostic_paths[[1]],overwrite=TRUE);terra::writeRaster(o,result$coverage_diagnostic_paths[[2]],overwrite=TRUE)}else result$coverage_diagnostic_paths<-character();if(isTRUE(require_complete)&&!result$complete)stop(sprintf("Template coverage incomplete: missing_inside_count=%d outside_mask_count=%d",result$missing_inside_count,result$outside_mask_count),call.=FALSE);result }
validate_daily_output <- function(path,expected_date,template,config,diagnostic_dir=NULL,variable_spec=NULL) {spec<-variable_spec%||%get_variable_spec(config$project$dataset_id,config);p<-parse_grid_filename(path,spec$daily_filename_prefix);if(!p$valid||p$timestep!="daily"||p$date!=as.Date(expected_date))return(list(valid=FALSE,message="filename date mismatch"));support_info<-if(exists("era5land_support_mask_info",mode="function"))era5land_support_mask_info(config,template,required=FALSE)else NULL;support_mask<-if(is.null(support_info))NULL else support_info$mask;g<-tryCatch(validate_template_coverage(path,template,isTRUE(config$spatial$require_complete_template_coverage%||%TRUE),diagnostic_dir,expected_date,support_mask=support_mask),error=function(e)e);if(inherits(g,"error"))return(list(valid=FALSE,message=conditionMessage(g),coverage=g));v<-validate_raster_against_template(path,template,spec$hard_valid_range,config$validation$require_exact_template_geometry,spec);v$coverage<-g;v}
validate_weekly_output <- function(path,expected_iso_year,expected_iso_week,template=NULL,config=NULL,variable_spec=NULL) {if(is.null(config)&&is.list(template)){config<-template;template<-terra::rast(path)};spec<-variable_spec%||%get_variable_spec(config$project$dataset_id,config);parse_path<-if(endsWith(tolower(path),".tmp.tif"))paste0(substr(path,1L,nchar(path)-8L),".tif")else path;p<-parse_grid_filename(parse_path,spec$weekly_filename_prefix);if(!p$valid||p$timestep!="weekly"||p$iso_year!=as.integer(expected_iso_year)||p$iso_week!=as.integer(expected_iso_week))return(list(valid=FALSE,message="filename week mismatch"));validate_raster_against_template(path,template,spec$hard_valid_range,config$validation$require_exact_template_geometry,spec)}

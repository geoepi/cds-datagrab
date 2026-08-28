era5land_donor_is_valid <- function(value, source_range = c(-Inf, Inf)) {
  isTRUE(length(value) == 1L && is.finite(value) && value >= source_range[1] && value <= source_range[2])
}

era5land_row_col_matrix <- function(r, cells) {
  cells <- as.integer(cells)
  if (!length(cells)) return(matrix(integer(), ncol = 2L))
  x <- terra::rowColFromCell(r, cells)
  if (is.null(dim(x))) matrix(x, nrow = 1L, ncol = 2L) else x
}

era5land_ring_distance <- function(r, origin, cells) {
  if (!length(cells)) return(integer())
  a <- era5land_row_col_matrix(r, origin)[1L, ]
  b <- era5land_row_col_matrix(r, cells)
  pmax(abs(b[, 1L] - a[1L]), abs(b[, 2L] - a[2L]))
}

era5land_ring_cells <- function(r, cell, radius, exclude = integer()) {
  rc <- era5land_row_col_matrix(r, cell)[1L, ]
  rows <- max(1L, rc[1L] - radius):min(terra::nrow(r), rc[1L] + radius)
  cols <- max(1L, rc[2L] - radius):min(terra::ncol(r), rc[2L] + radius)
  cells <- as.integer(terra::cellFromRowColCombine(r, rows, cols))
  cells <- cells[!cells %in% exclude & cells != cell]
  if (!length(cells)) return(integer())
  cells[era5land_ring_distance(r, cell, cells) <= radius]
}

era5land_cell_distances <- function(r, origin, cells) {
  if (!length(cells)) return(numeric())
  a <- terra::xyFromCell(r, origin); b <- terra::xyFromCell(r, cells)
  if (is.null(dim(b))) b <- matrix(b, nrow = 1L, ncol = 2L)
  dx <- b[, 1L] - a[1L]; dy <- b[, 2L] - a[2L]
  if (isTRUE(terra::is.lonlat(r))) {
    lat <- mean(c(a[2L], b[, 2L])) * pi / 180
    sqrt((dx * 111.32 * cos(lat))^2 + (dy * 111.32)^2)
  } else {
    units <- tolower(terra::crs(r, proj = TRUE))
    multiplier <- if (grepl("units=m|metre|meter", units)) 0.001 else 1
    sqrt(dx^2 + dy^2) * multiplier
  }
}

era5land_donor_pool <- function(projected_unmasked, template, source_range) {
  if (!isTRUE(terra::compareGeom(projected_unmasked, template, stopOnError = FALSE, messages = FALSE))) {
    stop("Projected donor raster and template geometry do not match", call. = FALSE)
  }
  template_values <- as.numeric(terra::values(template, mat = FALSE))
  projected_values <- as.numeric(terra::values(projected_unmasked, mat = FALSE))
  if (length(template_values) != length(projected_values)) stop("Projected donor and template value vectors have different lengths", call. = FALSE)
  inside <- !is.na(template_values)
  donor_cells <- which(inside & vapply(projected_values, era5land_donor_is_valid, logical(1), source_range = source_range))
  stopifnot(length(donor_cells) == length(projected_values[donor_cells]), all(is.finite(projected_values[donor_cells])))
  list(cells = as.integer(donor_cells), values = projected_values[donor_cells], full_values = projected_values, inside = inside,
    geometry = era5land_geometry_diagnostic(projected_unmasked, template, "donor"))
}

era5land_pool_values <- function(pool, cells) {
  if (!length(cells)) return(numeric())
  if (any(cells < 1L | cells > length(pool$full_values))) stop("Donor cell is outside the full template-aligned value vector", call. = FALSE)
  pool$full_values[as.integer(cells)]
}

era5land_geometry_diagnostic <- function(projected, template, label) {
  compare <- tryCatch(isTRUE(terra::compareGeom(projected, template, stopOnError = FALSE, messages = FALSE)), error = function(e) FALSE)
  extent_values <- function(r) c(terra::xmin(r), terra::xmax(r), terra::ymin(r), terra::ymax(r))
  list(label = label, compare_geom = compare, crs = identical(terra::crs(projected, proj = TRUE), terra::crs(template, proj = TRUE)), extent = isTRUE(all.equal(extent_values(projected), extent_values(template))), resolution = isTRUE(all.equal(as.numeric(terra::res(projected)), as.numeric(terra::res(template)))), origin = isTRUE(all.equal(as.numeric(terra::origin(projected)), as.numeric(terra::origin(template)))), nrow = identical(terra::nrow(projected), terra::nrow(template)), ncol = identical(terra::ncol(projected), terra::ncol(template)), ncell = identical(terra::ncell(projected), terra::ncell(template)), projected_ncell = terra::ncell(projected), template_ncell = terra::ncell(template))
}

era5land_target_cell_polygon <- function(template, cell) {
  center <- terra::xyFromCell(template, cell); resolution <- terra::res(template)
  x <- center[1L] + c(-1, 1, 1, -1, -1) * resolution[1L] / 2
  y <- center[2L] + c(-1, -1, 1, 1, -1) * resolution[2L] / 2
  terra::vect(list(cbind(x, y)), type = "polygons", crs = terra::crs(template))
}

era5land_point_distances <- function(r, origin_xy, cells) {
  if (!length(cells)) return(numeric())
  b <- terra::xyFromCell(r, cells); if (is.null(dim(b))) b <- matrix(b, nrow = 1L, ncol = 2L)
  dx <- b[, 1L] - origin_xy[1L]; dy <- b[, 2L] - origin_xy[2L]
  if (isTRUE(terra::is.lonlat(r))) {
    lat <- mean(c(origin_xy[2L], b[, 2L])) * pi / 180
    sqrt((dx * 111.32 * cos(lat))^2 + (dy * 111.32)^2)
  } else {
    units <- tolower(terra::crs(r, proj = TRUE)); multiplier <- if (grepl("units=m|metre|meter", units)) 0.001 else 1
    sqrt(dx^2 + dy^2) * multiplier
  }
}

era5land_source_footprint_donor <- function(target_cell, source, template, source_range, maximum_source_buffer_km = 35) {
  extent_values <- function(r) c(terra::xmin(r), terra::xmax(r), terra::ymin(r), terra::ymax(r))
  empty <- list(value = NA_real_, method = NULL, donor_cells = integer(), donor_values = numeric(),
    source_cell_count = 0L, source_footprint_donor_count = 0L, source_buffer_donor_count = 0L,
    minimum_source_distance_km = NA_real_, maximum_source_distance_km = NA_real_, source_minimum = NA_real_, source_maximum = NA_real_,
    failure_reason = "no_source_land_support")
  same_grid <- tryCatch(isTRUE(terra::compareGeom(source, template, stopOnError = FALSE, messages = FALSE)), error = function(e) FALSE)
  if (same_grid) return(empty)
  polygon <- tryCatch(era5land_target_cell_polygon(template, target_cell), error = function(e) NULL)
  if (is.null(polygon)) return(empty)
  template_crs <- terra::crs(template, proj = TRUE); source_crs <- terra::crs(source, proj = TRUE)
  if (!nzchar(template_crs) || !nzchar(source_crs)) { empty$failure_reason <- "source_or_template_crs_missing"; return(empty) }
  empty$source_diagnostics <- list(template_crs = template_crs, source_crs = source_crs, target_polygon_extent_template = extent_values(polygon))
  source_polygon <- tryCatch(terra::project(polygon, terra::crs(source)), error = function(e) NULL)
  if (is.null(source_polygon)) return(empty)
  source_polygon_extent <- extent_values(source_polygon); source_extent <- extent_values(source); intersects <- source_polygon_extent[1L] <= source_extent[2L] && source_polygon_extent[2L] >= source_extent[1L] && source_polygon_extent[3L] <= source_extent[4L] && source_polygon_extent[4L] >= source_extent[3L]
  empty$source_diagnostics$target_polygon_extent_source <- source_polygon_extent; empty$source_diagnostics$source_extent <- source_extent; empty$source_diagnostics$intersects_source_extent <- intersects
  if (!intersects) { empty$failure_reason <- "target_polygon_outside_source_extent"; return(empty) }
  extracted <- tryCatch(terra::extract(source, source_polygon, cells = TRUE, exact = TRUE), error = function(e) NULL)
  source_values <- as.numeric(terra::values(source, mat = FALSE))
  empty$source_diagnostics$extracted_rows <- if (is.null(extracted)) 0L else nrow(extracted)
  if (!is.null(extracted) && nrow(extracted) && "cell" %in% names(extracted)) {
    cells <- as.integer(extracted$cell); values <- source_values[cells]
    valid <- vapply(values, era5land_donor_is_valid, logical(1), source_range = source_range)
    cells <- cells[valid]; values <- values[valid]; empty$source_diagnostics$finite_extracted_rows <- length(cells)
    fractions <- if ("fraction" %in% names(extracted)) as.numeric(extracted$fraction[valid]) else rep(1, length(values))
    if (length(cells)) {
      center <- terra::xyFromCell(template, target_cell)
      center_source <- terra::project(terra::vect(matrix(center, nrow = 1L, ncol = 2L), type = "points", crs = terra::crs(template)), terra::crs(source))
      distances <- era5land_point_distances(source, terra::crds(center_source)[1L, ], cells)
      weighted <- length(unique(fractions)) > 1L && sum(fractions) > 0
      value <- if (weighted) sum(values * fractions) / sum(fractions) else mean(values)
      return(list(value = value, method = if (weighted) "source_footprint_weighted_mean" else "source_footprint_mean", source_diagnostics = empty$source_diagnostics,
        donor_cells = cells, donor_values = values, source_cell_count = length(cells), source_footprint_donor_count = length(cells), source_buffer_donor_count = 0L,
        minimum_source_distance_km = min(distances), maximum_source_distance_km = max(distances), source_minimum = min(values), source_maximum = max(values), failure_reason = NULL))
    }
  }
  center <- terra::xyFromCell(template, target_cell)
  center_source <- tryCatch(terra::project(terra::vect(matrix(center, nrow = 1L, ncol = 2L), type = "points", crs = terra::crs(template)), terra::crs(source)), error = function(e) NULL)
  if (is.null(center_source)) return(empty)
  valid_cells <- which(vapply(source_values, era5land_donor_is_valid, logical(1), source_range = source_range))
  distances <- era5land_point_distances(source, terra::crds(center_source)[1L, ], valid_cells)
  keep <- is.finite(distances) & distances <= maximum_source_buffer_km
  if (!any(keep)) return(empty)
  cells <- valid_cells[keep]; values <- source_values[cells]; distances <- distances[keep]; selected <- order(distances, cells)[1L]
  empty$source_diagnostics$finite_extracted_rows <- 0L
  list(value = values[selected], method = "source_buffer_nearest", source_diagnostics = empty$source_diagnostics, donor_cells = cells[selected], donor_values = values[selected],
    source_cell_count = length(cells), source_footprint_donor_count = 0L, source_buffer_donor_count = length(cells),
    minimum_source_distance_km = min(distances), maximum_source_distance_km = max(distances), source_minimum = min(values), source_maximum = max(values), failure_reason = NULL)
}

era5land_component_donors <- function(target_cell, component_cells, bilinear_pool, nearest_pool, source, template, source_range,
                                      maximum_donor_radius_cells, maximum_donor_count = 8L, maximum_source_buffer_km = 35) {
  target_bilinear <- era5land_pool_values(bilinear_pool, target_cell)
  target_nearest <- era5land_pool_values(nearest_pool, target_cell)
  exact_bilinear <- if (era5land_donor_is_valid(target_bilinear, source_range)) target_cell else integer()
  exact_nearest <- if (era5land_donor_is_valid(target_nearest, source_range)) target_cell else integer()
  base <- list(value = NA_real_, method = NULL, donor_cells = integer(), donor_values = numeric(), target_donor_cells_considered = integer(), candidate_diagnostics = list(),
    target_ring_radius_searched = 0L, exact_bilinear_donor_count = length(exact_bilinear), exact_nearest_donor_count = length(exact_nearest),
    local_bilinear_donor_count = 0L, local_nearest_donor_count = 0L, maximum_donor_distance_cells = NA_real_, maximum_donor_distance_km = NA_real_,
    source_cell_count = 0L, source_footprint_donor_count = 0L, source_buffer_donor_count = 0L, minimum_source_distance_km = NA_real_, maximum_source_distance_km = NA_real_,
    source_minimum = NA_real_, source_maximum = NA_real_, source_diagnostics = list(), failure_reason = "no_valid_donor_within_radius")
  if (length(exact_nearest)) {
    base$value <- target_nearest; base$method <- "same_cell_nearest"; base$donor_cells <- exact_nearest; base$donor_values <- target_nearest; base$maximum_donor_distance_cells <- 0; base$maximum_donor_distance_km <- 0; return(base)
  }
  for (radius in seq_len(maximum_donor_radius_cells)) {
    candidates <- era5land_ring_cells(template, target_cell, radius, exclude = component_cells)
    base$target_donor_cells_considered <- unique(c(base$target_donor_cells_considered, candidates)); base$target_ring_radius_searched <- radius
    if (!length(candidates)) next
    bilinear_values <- era5land_pool_values(bilinear_pool, candidates); nearest_values <- era5land_pool_values(nearest_pool, candidates)
    base$candidate_diagnostics <- lapply(seq_along(candidates), function(j) list(target_cell = target_cell, candidate_cell = candidates[[j]], candidate_row = era5land_row_col_matrix(template, candidates[[j]])[1L, 1L], candidate_column = era5land_row_col_matrix(template, candidates[[j]])[1L, 2L], template_inside = isTRUE(bilinear_pool$inside[candidates[[j]]]), bilinear_value = bilinear_values[[j]], nearest_value = nearest_values[[j]], candidate_in_bilinear_donor_pool = candidates[[j]] %in% bilinear_pool$cells, candidate_in_nearest_donor_pool = candidates[[j]] %in% nearest_pool$cells))
    bilinear_ok <- vapply(bilinear_values, era5land_donor_is_valid, logical(1), source_range = source_range)
    nearest_ok <- vapply(nearest_values, era5land_donor_is_valid, logical(1), source_range = source_range)
    use_bilinear <- any(bilinear_ok); valid <- if (use_bilinear) bilinear_ok else nearest_ok
    valid_cells <- candidates[valid]; if (!length(valid_cells)) next
    distances_cells <- era5land_ring_distance(template, target_cell, valid_cells); distances_km <- era5land_cell_distances(template, target_cell, valid_cells)
    order_index <- order(distances_km, valid_cells); valid_cells <- valid_cells[order_index]; distances_cells <- distances_cells[order_index]; distances_km <- distances_km[order_index]
    valid_cells <- head(valid_cells, maximum_donor_count); distances_cells <- head(distances_cells, maximum_donor_count); distances_km <- head(distances_km, maximum_donor_count)
    donor_values <- if (use_bilinear) era5land_pool_values(bilinear_pool, valid_cells) else era5land_pool_values(nearest_pool, valid_cells)
    weights <- 1 / pmax(distances_km, .Machine$double.eps)
    base$value <- if (length(donor_values) == 1L) donor_values[[1L]] else sum(donor_values * weights) / sum(weights)
    base$method <- paste0("target_ring_idw_radius_", radius); base$donor_cells <- valid_cells; base$donor_values <- as.numeric(donor_values)
    base$local_bilinear_donor_count <- if (use_bilinear) length(valid_cells) else 0L; base$local_nearest_donor_count <- if (use_bilinear) 0L else length(valid_cells)
    base$maximum_donor_distance_cells <- max(distances_cells); base$maximum_donor_distance_km <- max(distances_km); base$failure_reason <- NULL; return(base)
  }
  fallback <- era5land_source_footprint_donor(target_cell, source, template, source_range, maximum_source_buffer_km)
  if (!is.null(fallback$method)) {
    base[names(fallback)] <- fallback; base$failure_reason <- NULL
  } else base$failure_reason <- fallback$failure_reason
  base
}

era5land_source_gap_classification <- function(cell, source, template, bilinear_value, nearest_value) {
  if (is.finite(nearest_value)) return("projection_created_gap")
  point <- tryCatch(terra::xyFromCell(template, cell), error = function(e) NULL); if (is.null(point)) return("unknown_gap")
  source_point <- tryCatch(terra::project(terra::vect(point, crs = terra::crs(template)), terra::crs(source)), error = function(e) NULL); if (is.null(source_point)) return("unknown_gap")
  source_cell <- tryCatch(terra::cellFromXY(source, terra::crds(source_point)), error = function(e) NA_integer_); source_extent <- terra::ext(source); source_xy <- terra::crds(source_point)
  if (source_xy[1L] < source_extent$xmin || source_xy[1L] > source_extent$xmax || source_xy[2L] < source_extent$ymin || source_xy[2L] > source_extent$ymax || !length(source_cell) || is.na(source_cell)) return("outside_source_support")
  neighbours <- coverage_cell_neighbors(source, source_cell); source_values <- terra::values(source, mat = FALSE)
  if (is.na(source_values[[source_cell]]) || anyNA(source_values[neighbours])) "source_land_mask_gap" else "projection_created_gap"
}

era5land_write_repair_diagnostics <- function(template, missing_pre, repaired, missing_post, outside_mask, diagnostic_dir, date, prefix, component_records, structural_support_exclusion = rep(FALSE, terra::ncell(template)), unexpected_post_repair_missing = missing_post) {
  if (is.null(diagnostic_dir)) return(character()); fs::dir_create(diagnostic_dir, recurse = TRUE)
  stem <- paste0(prefix %||% "daily", "_", format(as.Date(date), "%Y-%m-%d")); masks <- list(missing_inside_pre_repair = missing_pre, repaired_cells = repaired, missing_inside_post_repair = missing_post, outside_mask = outside_mask, structural_support_exclusion = structural_support_exclusion, unexpected_post_repair_missing = unexpected_post_repair_missing)
  paths <- vapply(names(masks), function(name) file.path(diagnostic_dir, paste0(stem, "_", name, ".tif")), character(1))
  for (name in names(masks)) { r <- template; terra::values(r) <- ifelse(masks[[name]], 1, NA); terra::writeRaster(r, paths[[name]], overwrite = TRUE) }
  component_path <- file.path(diagnostic_dir, paste0("repair_components_", prefix %||% "daily", "_", format(as.Date(date), "%Y-%m-%d"), ".csv"))
  component_df <- if (length(component_records)) do.call(rbind, lapply(component_records, function(x) { x$donor_method <- x$donor_method %||% NA_character_; x$repair_failure_reason <- x$repair_failure_reason %||% NA_character_; as.data.frame(x, stringsAsFactors = FALSE) })) else data.frame()
  utils::write.csv(component_df, component_path, row.names = FALSE); c(paths, component_csv = component_path)
}

analyze_template_coverage <- function(bilinear, nearest, source, template, mask_template = TRUE, maximum_repair_count = 4L, maximum_repair_fraction = 0.0005,
                                      maximum_component_size = 4L, maximum_donor_radius_cells = 2L, maximum_donor_radius_km = NULL, donor_count = 8L,
                                      maximum_source_buffer_km = 35, source_range = c(-Inf, Inf), diagnostics_dir = NULL, date = NULL, prefix = NULL, support_mask = NULL) {
  bilinear_unmasked <- bilinear; nearest_unmasked <- nearest
  if (!is.null(support_mask) && !isTRUE(terra::compareGeom(support_mask, template, stopOnError = FALSE, messages = FALSE))) stop("ERA5-Land support mask geometry does not match template", call. = FALSE)
  template_values <- as.numeric(terra::values(template, mat = FALSE)); master_template_valid <- !is.na(template_values)
  support_values <- if (is.null(support_mask)) template_values else as.numeric(terra::values(support_mask, mat = FALSE)); template_valid <- master_template_valid & !is.na(support_values)
  structural_support_exclusion <- master_template_valid & !template_valid
  output_masked <- if (!is.null(support_mask)) terra::mask(bilinear_unmasked, support_mask) else if (mask_template) terra::mask(bilinear_unmasked, template) else bilinear_unmasked
  bilinear_values <- as.numeric(terra::values(bilinear_unmasked, mat = FALSE)); nearest_values <- as.numeric(terra::values(nearest_unmasked, mat = FALSE)); output_values <- as.numeric(terra::values(output_masked, mat = FALSE))
  master_missing <- master_template_valid & !is.finite(output_values); missing <- template_valid & !is.finite(output_values); missing_cells <- which(missing); components <- coverage_component_sets(template, missing_cells)
  donor_template <- if (is.null(support_mask)) template else support_mask
  bilinear_pool <- era5land_donor_pool(bilinear_unmasked, donor_template, source_range); nearest_pool <- era5land_donor_pool(nearest_unmasked, donor_template, source_range)
  donor_geometry <- list(bilinear = era5land_geometry_diagnostic(bilinear_unmasked, template, "bilinear"), nearest = era5land_geometry_diagnostic(nearest_unmasked, template, "nearest"))
  if (!isTRUE(donor_geometry$bilinear$compare_geom) || !isTRUE(donor_geometry$nearest$compare_geom)) stop("Projected donor raster geometry does not match template", call. = FALSE)
  if (length(template_values) != length(bilinear_values) || length(template_values) != length(nearest_values)) stop("Template and donor value vectors must have equal full lengths", call. = FALSE)
  details <- list(); component_records <- list(); proposed_by_component <- vector("list", length(components))
  for (component_id in seq_along(components)) {
    component_cells <- components[[component_id]]; proposals <- vector("list", length(component_cells)); failure_reasons <- character(); attempted <- length(component_cells) <= maximum_component_size
    for (k in seq_along(component_cells)) {
      cell <- component_cells[[k]]
      donor <- if (attempted) era5land_component_donors(cell, component_cells, bilinear_pool, nearest_pool, source, template, source_range, maximum_donor_radius_cells, donor_count, maximum_source_buffer_km) else list(value = NA_real_, method = NULL, donor_cells = integer(), donor_values = numeric(), target_donor_cells_considered = integer(), target_ring_radius_searched = 0L, exact_bilinear_donor_count = 0L, exact_nearest_donor_count = 0L, local_bilinear_donor_count = 0L, local_nearest_donor_count = 0L, maximum_donor_distance_cells = NA_real_, maximum_donor_distance_km = NA_real_, source_cell_count = 0L, source_footprint_donor_count = 0L, source_buffer_donor_count = 0L, minimum_source_distance_km = NA_real_, maximum_source_distance_km = NA_real_, source_minimum = NA_real_, source_maximum = NA_real_, failure_reason = "component_exceeds_configured_maximum")
      if (!is.null(donor$failure_reason)) failure_reasons <- c(failure_reasons, donor$failure_reason); if (!is.finite(donor$value)) failure_reasons <- c(failure_reasons, "no_finite_candidate_value"); proposals[[k]] <- donor
      target_neighbors <- setdiff(coverage_cell_neighbors(template, cell), cell); target_coords <- terra::xyFromCell(template, target_neighbors); cell_xy <- terra::xyFromCell(template, cell); target_distances <- if (length(target_neighbors)) sqrt(rowSums((target_coords - matrix(cell_xy, nrow = nrow(target_coords), ncol = 2, byrow = TRUE))^2)) else numeric(); target_values <- if (length(target_neighbors)) bilinear_values[target_neighbors] else numeric(); masked_target_values <- if (length(target_neighbors)) output_values[target_neighbors] else numeric(); nearest_target_values <- if (length(target_neighbors)) nearest_values[target_neighbors] else numeric()
      classification <- era5land_source_gap_classification(cell, source, template, bilinear_values[[cell]], nearest_values[[cell]]); legacy_classification <- if (classification == "outside_source_support") "outside_source_support" else if (is.finite(nearest_values[[cell]])) "bilinear_interpolation_artifact" else if (classification == "source_land_mask_gap" && length(component_cells) == 1L && sum(is.finite(target_values)) >= 4L) "isolated_land_mask_mismatch" else "source_nodata"
      details[[length(details) + 1L]] <- list(cell_id = cell, component_id = component_id, row = terra::rowFromCell(template, cell), column = terra::colFromCell(template, cell), bilinear_value = bilinear_values[[cell]], nearest_value = nearest_values[[cell]], template_inside = template_valid[[cell]], classification = legacy_classification, gap_type = if (is.finite(nearest_values[[cell]])) "bilinear_missing_nearest_same_cell_valid" else if (!is.null(donor$method)) "bilinear_missing_nearest_same_cell_missing_local_donor" else "bilinear_missing_no_local_donor", source_gap_type = classification, exact_bilinear_donor_count = donor$exact_bilinear_donor_count, exact_nearest_donor_count = donor$exact_nearest_donor_count, local_bilinear_donor_count = donor$local_bilinear_donor_count, local_nearest_donor_count = donor$local_nearest_donor_count, maximum_donor_distance_cells = donor$maximum_donor_distance_cells, maximum_donor_distance_km = donor$maximum_donor_distance_km, donor_method = donor$method, donor_cells = donor$donor_cells, donor_values = donor$donor_values, candidate_diagnostics = donor$candidate_diagnostics, source_diagnostics = donor$source_diagnostics, target_donor_cells_considered = donor$target_donor_cells_considered, target_ring_radius_searched = donor$target_ring_radius_searched, target_donor_count = length(donor$donor_cells), source_cell_count = donor$source_cell_count, source_footprint_donor_count = donor$source_footprint_donor_count, source_buffer_donor_count = donor$source_buffer_donor_count, minimum_source_distance_km = donor$minimum_source_distance_km, maximum_source_distance_km = donor$maximum_source_distance_km, selected_value = donor$value, source_minimum = donor$source_minimum, source_maximum = donor$source_maximum, missing_component_size = length(component_cells), target_neighbor_cell_ids = target_neighbors, target_neighbor_distances = target_distances, target_neighbor_values = target_values, masked_output_neighbor_values = masked_target_values, unmasked_bilinear_neighbor_finite_count = sum(is.finite(target_values)), unmasked_bilinear_neighbor_na_count = sum(!is.finite(target_values), na.rm = TRUE), masked_output_neighbor_finite_count = sum(is.finite(masked_target_values)), masked_output_neighbor_na_count = sum(!is.finite(masked_target_values), na.rm = TRUE), unmasked_nearest_neighbor_finite_count = sum(is.finite(nearest_target_values)), unmasked_nearest_neighbor_na_count = sum(!is.finite(nearest_target_values), na.rm = TRUE), target_finite_neighbor_count = sum(is.finite(target_values)), target_na_neighbor_count = sum(!is.finite(target_values), na.rm = TRUE))
    }
    component_repairable <- attempted && all(vapply(proposals, function(x) is.finite(x$value), logical(1)))
    component_reason <- if (!attempted) "component_exceeds_configured_maximum" else if (!component_repairable) failure_reasons[[1L]] %||% "no_source_land_support" else NULL
    proposed_by_component[[component_id]] <- proposals
    all_target_considered <- unique(unlist(lapply(proposals, `[[`, "target_donor_cells_considered"), use.names = FALSE)); all_methods <- unique(na.omit(vapply(proposals, function(x) x$method %||% NA_character_, character(1)))); source_distances <- vapply(proposals, function(x) x$maximum_source_distance_km %||% NA_real_, numeric(1)); source_minimums <- vapply(proposals, function(x) x$source_minimum %||% NA_real_, numeric(1)); source_maximums <- vapply(proposals, function(x) x$source_maximum %||% NA_real_, numeric(1))
    component_records[[component_id]] <- list(component_id = component_id, component_size = length(component_cells), target_cells = paste(component_cells, collapse = ";"), target_donor_cells_considered = paste(all_target_considered, collapse = ";"), target_ring_radius_searched = if (length(proposals)) max(vapply(proposals, `[[`, numeric(1), "target_ring_radius_searched")) else 0, target_donor_count = sum(vapply(proposals, function(x) length(x$donor_cells), integer(1))), exact_bilinear_donor_count = sum(vapply(proposals, `[[`, integer(1), "exact_bilinear_donor_count")), exact_nearest_donor_count = sum(vapply(proposals, `[[`, integer(1), "exact_nearest_donor_count")), local_bilinear_donor_count = sum(vapply(proposals, `[[`, integer(1), "local_bilinear_donor_count")), local_nearest_donor_count = sum(vapply(proposals, `[[`, integer(1), "local_nearest_donor_count")), source_footprint_donor_count = sum(vapply(proposals, `[[`, integer(1), "source_footprint_donor_count")), source_buffer_donor_count = sum(vapply(proposals, `[[`, integer(1), "source_buffer_donor_count")), source_cell_count = sum(vapply(proposals, `[[`, integer(1), "source_cell_count")), minimum_source_distance_km = if (all(!is.finite(source_distances))) NA_real_ else min(source_distances, na.rm = TRUE), maximum_source_distance_km = if (all(!is.finite(source_distances))) NA_real_ else max(source_distances, na.rm = TRUE), source_minimum = if (all(!is.finite(source_minimums))) NA_real_ else min(source_minimums, na.rm = TRUE), source_maximum = if (all(!is.finite(source_maximums))) NA_real_ else max(source_maximums, na.rm = TRUE), repair_eligible = length(component_cells) <= maximum_component_size, repair_attempted = attempted, repaired_cell_count = 0L, donor_method = paste(all_methods, collapse = ";"), repair_failure_reason = component_reason, repaired = FALSE)
  }
  repairable_components <- vapply(component_records, function(x) isTRUE(x$repair_eligible) && is.null(x$repair_failure_reason), logical(1)); candidate_cells <- if (any(repairable_components)) unlist(components[repairable_components], use.names = FALSE) else integer(); candidate_fraction <- if (sum(template_valid)) length(candidate_cells) / sum(template_valid) else 0; global_failure <- if (length(candidate_cells) > maximum_repair_count) "maximum_repair_count_exceeded" else if (candidate_fraction > maximum_repair_fraction) "maximum_repair_fraction_exceeded" else NULL
  repaired_cells <- if (is.null(global_failure)) candidate_cells else integer(); if (length(repaired_cells)) for (component_id in which(repairable_components)) { cells <- components[[component_id]]; proposals <- proposed_by_component[[component_id]]; for (k in seq_along(cells)) output_values[[cells[[k]]] ] <- proposals[[k]]$value; component_records[[component_id]]$repaired_cell_count <- length(cells); component_records[[component_id]]$repaired <- TRUE }
  if (!is.null(global_failure)) for (component_id in which(repairable_components)) { component_records[[component_id]]$repair_failure_reason <- global_failure; component_records[[component_id]]$repaired <- FALSE }
  missing_post <- template_valid & !is.finite(output_values); outside_mask <- !master_template_valid & is.finite(output_values); outside_support_finite <- !template_valid & is.finite(output_values); repaired_mask <- rep(FALSE, length(output_values)); repaired_mask[repaired_cells] <- TRUE
  if (sum(repaired_mask, na.rm = TRUE) != sum(missing) - sum(missing_post)) stop("Coverage repair invariant failed: repaired_cells != pre_missing - post_missing", call. = FALSE)
  diagnostics_paths <- if (!is.null(date)) era5land_write_repair_diagnostics(template, master_missing, repaired_mask, missing_post, outside_mask, diagnostics_dir, date, prefix, component_records, structural_support_exclusion, missing_post) else character(); component_json <- lapply(component_records, function(x) { x$donor_method <- x$donor_method %||% NA_character_; x$repair_failure_reason <- x$repair_failure_reason %||% NA_character_; x }); classification_counts <- table(vapply(details, `[[`, character(1), "classification")); source_values <- terra::values(source, mat = FALSE)
  legacy_local_idw <- any(vapply(details, function(x) identical(x$classification, "isolated_land_mask_mismatch"), logical(1)))
  methods <- if (length(details)) vapply(details, function(x) x$donor_method %||% "", character(1)) else character()
  target_grid_supported <- grepl("^(same_cell_nearest|target_ring_idw_radius_)", methods)
  radius_one_supported <- sum(methods == "target_ring_idw_radius_1")
  radius_two_supported <- sum(methods == "target_ring_idw_radius_2")
  source_fallback_attempted <- sum(grepl("^source_", methods) | vapply(details, function(x) is.null(x$donor_method) && x$source_footprint_donor_count + x$source_buffer_donor_count == 0L, logical(1)))
  diagnostic_summary <- list(donor_geometry = donor_geometry, full_value_vector_lengths = c(template = length(template_values), bilinear = length(bilinear_values), nearest = length(nearest_values)), target_grid_supported_count = sum(target_grid_supported), target_ring_radius_1_supported_count = radius_one_supported, target_ring_radius_2_supported_count = radius_two_supported, source_fallback_attempted_count = source_fallback_attempted, source_range = source_range)
  diagnostic_summary <- c(diagnostic_summary, list(master_template_cells = sum(master_template_valid), era5land_supported_cells = sum(template_valid), structurally_unsupported_cells = sum(structural_support_exclusion), structural_support_exclusion_count = sum(structural_support_exclusion), pre_repair_missing_cells = sum(master_missing), pre_repair_missing_supported_cells = sum(missing), post_repair_unexpected_missing_cells = sum(missing_post), outside_support_finite_cells = sum(outside_support_finite), outside_mask_finite_cells = sum(outside_mask)))
  result <- list(raster = { terra::values(output_masked) <- output_values; output_masked }, diagnostics = c(diagnostic_summary, list(details = details, component_records = component_json, template_non_na = sum(template_valid), missing_inside_count = sum(missing), missing_inside_pre_repair_count = sum(master_missing), missing_inside_pre_repair_supported_count = sum(missing), missing_inside_post_repair_count = sum(missing_post), outside_mask_count = sum(outside_mask), outside_support_finite_count = sum(outside_support_finite), repair_applied = length(repaired_cells) > 0L, repair_method = if (legacy_local_idw) "local_final_grid_idw" else "bounded_local_donor_with_source_footprint_fallback", repair_count = length(repaired_cells), repair_fraction = if (sum(template_valid)) length(repaired_cells) / sum(template_valid) else 0, repaired_cell_ids = repaired_cells, unresolved_count = sum(missing_post), eligible = any(repairable_components) && is.null(global_failure), source_cell_count = terra::ncell(source), source_non_na_count = sum(vapply(source_values, is.finite, logical(1))), source_na_count = sum(!vapply(source_values, is.finite, logical(1))), source_na_fraction = mean(!vapply(source_values, is.finite, logical(1))), classification_counts = as.list(classification_counts), source_nodata_count = sum(vapply(details, function(x) x$classification %in% c("source_nodata", "isolated_land_mask_mismatch"), logical(1))), projection_created_nodata_count = sum(vapply(details, function(x) identical(x$classification, "bilinear_interpolation_artifact"), logical(1))), repairable_count = length(repaired_cells), unrepairable_count = sum(missing_post), maximum_component_size = maximum_component_size, maximum_donor_radius_cells = maximum_donor_radius_cells, maximum_source_buffer_km = maximum_source_buffer_km, component_sizes = vapply(components, length, integer(1)), coverage_diagnostic_paths = diagnostics_paths)), details = details, repaired = length(repaired_cells) > 0L, template_non_na = sum(template_valid), missing_inside_count = sum(missing), missing_inside_pre_repair_count = sum(master_missing), missing_inside_post_repair_count = sum(missing_post), outside_mask_count = sum(outside_mask), outside_support_finite_count = sum(outside_support_finite), repair_applied = length(repaired_cells) > 0L, repair_count = length(repaired_cells), repair_fraction = if (sum(template_valid)) length(repaired_cells) / sum(template_valid) else 0, repaired_cell_ids = repaired_cells, unresolved_count = sum(missing_post), eligible = any(repairable_components) && is.null(global_failure), component_records = component_json, source_cell_count = terra::ncell(source), source_non_na_count = sum(vapply(source_values, is.finite, logical(1))), source_na_count = sum(!vapply(source_values, is.finite, logical(1))), source_na_fraction = mean(!vapply(source_values, is.finite, logical(1))), coverage_diagnostic_paths = diagnostics_paths)
  result
}

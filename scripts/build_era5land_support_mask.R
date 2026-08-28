args <- commandArgs(trailingOnly = TRUE)
value <- function(flag, default) {
  i <- match(flag, args)
  if (is.na(i) || i == length(args)) default else args[[i + 1L]]
}
root <- normalizePath(value("--root", "."), winslash = "/", mustWork = TRUE)
template_path <- value("--template", file.path(root, "spatial_domain", "study_area_raster.tif"))
audit_path <- value("--audit", file.path(root, "spatial_domain", "derived", "era5land_unsupported_cells.csv"))
output_path <- value("--output", file.path(root, "spatial_domain", "derived", "era5land_support_mask.tif"))
if (!requireNamespace("terra", quietly = TRUE)) stop("terra is required", call. = FALSE)
template <- terra::rast(template_path)
audit <- utils::read.csv(audit_path, stringsAsFactors = FALSE)
required <- c("cell", "reason", "source_request_hash", "representative_date", "support_decision_method")
if (!all(required %in% names(audit))) stop("Support audit is missing required columns", call. = FALSE)
cells <- as.integer(audit$cell)
if (!length(cells) || anyNA(cells) || anyDuplicated(cells) || any(cells < 1L | cells > terra::ncell(template))) stop("Support audit cell IDs are invalid", call. = FALSE)
template_values <- terra::values(template, mat = FALSE)
if (any(is.na(template_values[cells]))) stop("Support audit cells must be inside the master template support", call. = FALSE)
mask <- template
mask_values <- rep(1, terra::ncell(template))
mask_values[is.na(template_values)] <- NA_real_
mask_values[cells] <- NA_real_
terra::values(mask) <- mask_values
fs::dir_create(dirname(output_path), recurse = TRUE)
terra::writeRaster(mask, output_path, overwrite = TRUE, wopt = list(datatype = "FLT4S", NAflag = -9999))
cat(sprintf("wrote %s\nunsupported_cells=%d\n", normalizePath(output_path, winslash = "/", mustWork = TRUE), length(cells)))

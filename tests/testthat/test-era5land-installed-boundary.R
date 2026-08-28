test_that("ERA5-Land debug runner resolves internal helpers explicitly", {
  script <- paste(readLines(package_file("scripts", "debug_era5land_slice.R"), warn = FALSE), collapse = "\n")
  expect_match(script, "support_mask_info <- getFromNamespace\\(\\\"era5land_support_mask_info\\\", \\\"cdsdatagrab\\\"\\)")
  expect_false(grepl("(?m)^\\s*support_info\\s*<-\\s*era5land_support_mask_info\\s*\\(", script, perl = TRUE))
})

test_that("installed package keeps the support helper internal and resolvable", {
  installed_roots <- .libPaths()[file.exists(file.path(.libPaths(), "cdsdatagrab", "DESCRIPTION"))]
  installed_from_library <- length(installed_roots) > 0L
  skip_if(!installed_from_library, "cdsdatagrab is not installed in this test environment")
  installed <- file.path(installed_roots[[1L]], "cdsdatagrab")
  rscript <- file.path(R.home("bin"), if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
  probe <- tempfile("cdsdatagrab-namespace-probe-", fileext = ".R")
  on.exit(unlink(probe), add = TRUE)
  writeLines(c(
    "library(cdsdatagrab)",
    "stopifnot(exists('era5land_support_mask_info', envir = asNamespace('cdsdatagrab'), inherits = FALSE))",
    "stopifnot(!('era5land_support_mask_info' %in% getNamespaceExports('cdsdatagrab')))",
    "stopifnot(is.function(getFromNamespace('era5land_support_mask_info', 'cdsdatagrab')))"
  ), probe)
  old_libs <- Sys.getenv(c("R_LIBS", "R_LIBS_USER"), unset = NA_character_)
  on.exit({
    if (is.na(old_libs[["R_LIBS"]])) Sys.unsetenv("R_LIBS") else Sys.setenv(R_LIBS = old_libs[["R_LIBS"]])
    if (is.na(old_libs[["R_LIBS_USER"]])) Sys.unsetenv("R_LIBS_USER") else Sys.setenv(R_LIBS_USER = old_libs[["R_LIBS_USER"]])
  }, add = TRUE)
  Sys.setenv(R_LIBS = dirname(installed), R_LIBS_USER = dirname(installed))
  output <- system2(rscript, c("--vanilla", probe), stdout = TRUE, stderr = TRUE)
  expect_null(attr(output, "status"), info = paste(output, collapse = "\n"))
})

test_that("Rscript heredocs include the stdin filename marker", {
  files <- c(package_file("README.md"), package_file("hpc", "lib", "cds_datagrab_env.sh"))
  text <- paste(unlist(lapply(files, readLines, warn = FALSE)), collapse = "\n")
  expect_false(grepl("Rscript[[:space:]]+<<'RS'", text))
  expect_true(grepl("Rscript[[:space:]]+-[[:space:]]*<<'RS'", text) || grepl("Rscript[[:space:]]+--vanilla[[:space:]]+-[[:space:]]+[^\n]+<<'RS'", text))
})

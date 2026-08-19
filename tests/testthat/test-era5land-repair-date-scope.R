test_that("ERA5-Land provenance repair date limits scope TIFF examination and writes", {
  script <- parse(file = package_file("scripts", "repair_era5land_daily_sidecar_provenance.R"))
  helper_env <- new.env(parent = asNamespace("cdsdatagrab"))
  eval(script[[1L]], envir = helper_env)
  select_tif <- helper_env$era5land_repair_tif_selection

  base <- file.path(getwd(), ".test-era5land-repair-date-scope")
  unlink(base, recursive = TRUE, force = TRUE)
  dir.create(base, recursive = TRUE)
  on.exit(unlink(base, recursive = TRUE, force = TRUE), add = TRUE)
  spec <- get_variable_spec("era5land_tmean")
  paths <- file.path(base, paste0(spec$daily_filename_prefix, "_", c("2022-01-01", "2022-01-02", "2022-02-01"), ".tif"))
  for (path in paths) {
    file.create(path)
    jsonlite::write_json(list(request_hash = "wrong", source_member = "wrong.nc", source_archive_path = "wrong.zip", scientific = list(keep = TRUE)), paste0(path, ".json"), auto_unbox = TRUE, pretty = TRUE)
  }

  request <- function(date, hash) list(source_family_id = "era5land_daily_mean_utc06", request_hash = hash,
    request_start = date, request_end = date, raw_request_dates = date, time_zone = "utc-06:00", frequency = "1_hourly", daily_statistic = "daily_mean")
  requests <- list(request("2022-01-01", "jan-hash"), request("2022-02-01", "feb-hash"))
  members <- list(
    `jan-hash` = list(member_name = "jan.nc", environmental_variable_alias = "t2m", archive_path = "jan.zip", source_map_rows = 1L),
    `feb-hash` = list(member_name = "feb.nc", environmental_variable_alias = "t2m", archive_path = "feb.zip", source_map_rows = 1L)
  )
  scan <- function(start, end, apply = FALSE) {
    rows <- list()
    for (path in paths) {
      selected <- select_tif(path, spec$daily_filename_prefix, start, end)
      if (!isTRUE(selected$examine)) next
      matches <- vapply(requests, function(x) selected$date_iso %in% cdsdatagrab:::canonical_iso_dates(x$raw_request_dates, "request dates"), logical(1))
      if (sum(matches) != 1L) {
        rows[[length(rows) + 1L]] <- data.frame(date = selected$date_iso, tif_path = path, status = "ambiguous", stringsAsFactors = FALSE)
        next
      }
      current <- requests[[which(matches)]]
      repaired <- cdsdatagrab:::era5land_repair_product_sidecar(paste0(path, ".json"), spec, current, members[[current$request_hash]], apply = apply)
      rows[[length(rows) + 1L]] <- data.frame(date = selected$date_iso, tif_path = path, status = repaired$status, stringsAsFactors = FALSE)
    }
    if (length(rows)) do.call(rbind, rows) else data.frame(date = character(), tif_path = character(), status = character())
  }
  sidecar_hash <- function() vapply(paste0(paths, ".json"), function(path) digest::digest(file = path, algo = "sha256"), character(1))
  tif_hash_before <- vapply(paths, function(path) digest::digest(file = path, algo = "sha256"), character(1))
  tif_mtime_before <- file.info(paths)$mtime
  sidecar_before <- sidecar_hash()

  dry_run <- scan("2022-01-01", "2022-01-02", apply = FALSE)
  expect_equal(nrow(dry_run), 2L)
  expect_setequal(dry_run$date, c("2022-01-01", "2022-01-02"))
  expect_false(paths[[3L]] %in% dry_run$tif_path)
  expect_equal(sum(dry_run$status == "ambiguous"), 1L)
  expect_identical(dry_run$date[dry_run$status == "ambiguous"], "2022-01-02")
  expect_identical(sidecar_hash(), sidecar_before)

  applied <- scan("2022-01-01", "2022-01-02", apply = TRUE)
  expect_identical(applied$status[applied$date == "2022-01-01"], "repaired")
  sidecar_after <- sidecar_hash()
  expect_false(identical(sidecar_after[[1L]], sidecar_before[[1L]]))
  expect_identical(sidecar_after[2:3], sidecar_before[2:3])
  expect_identical(jsonlite::read_json(paste0(paths[[1L]], ".json"), simplifyVector = TRUE)$request_hash, "jan-hash")

  second_apply <- scan("2022-01-01", "2022-01-02", apply = TRUE)
  expect_identical(second_apply$status[second_apply$date == "2022-01-01"], "already_correct")
  expect_identical(sidecar_hash(), sidecar_after)
  expect_identical(vapply(paths, function(path) digest::digest(file = path, algo = "sha256"), character(1)), tif_hash_before)
  expect_identical(file.info(paths)$mtime, tif_mtime_before)

  full_period <- scan("2022-01-01", "2022-02-01", apply = FALSE)
  expect_equal(nrow(full_period), 3L)
  expect_setequal(full_period$date, c("2022-01-01", "2022-01-02", "2022-02-01"))
})

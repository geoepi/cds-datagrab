test_that("production portfolio has five source workflows and twelve products", {
  definition <- portfolio_read_definition(package_file("config", "production_portfolio.yml"))
  expect_length(definition$source_workflows, 5)
  expect_length(definition$source_workflow_ids, 5)
  expect_length(definition$product_ids, 12)
  expect_identical(definition$source_workflow_ids, portfolio_source_workflow_ids())
  expect_identical(definition$product_ids, portfolio_product_ids())
  expect_length(definition$source_workflows[[5]]$products, 8)
})

test_that("latest-common uses the minimum configured source endpoint", {
  definition <- portfolio_read_definition(package_file("config", "production_portfolio.yml"))
  attr(definition, "config_path") <- package_file("config", "production_portfolio.yml")
  plan <- portfolio_resolve_plan(definition, through = "latest-common")
  expect_identical(plan$common_end, "2026-07-26")
  expect_length(plan$availability$source_workflow, 5)
})

test_that("explicit endpoint beyond observed_end is allowed within hard horizons", {
  definition <- portfolio_read_definition(package_file("config", "production_portfolio.yml"))
  attr(definition, "config_path") <- package_file("config", "production_portfolio.yml")
  plan <- portfolio_resolve_plan(definition, through = "explicit", explicit_end = "2026-07-27")
  expect_identical(plan$endpoint_policy, "explicit")
  expect_identical(plan$requested_end, "2026-07-27")
  expect_identical(plan$effective_requested_end, "2026-07-27")
  expect_identical(plan$common_end, "2026-07-27")
  expect_identical(plan$incremental_work_end, "2026-07-27")
  expect_identical(plan$portfolio_inventory_start, "2022-01-01")
  expect_identical(plan$portfolio_inventory_end, "2026-07-27")
  expect_equal(plan$incremental_complete_iso_week_count, length(plan$complete_iso_weeks))
  expect_equal(plan$cumulative_complete_iso_week_count, length(plan$cumulative_complete_iso_weeks))
  expect_true(all(plan$availability$known_observed_end == "2026-07-26"))
  expect_true(all(plan$availability$availability_status == "unverified explicit target"))
  expect_error(portfolio_resolve_plan(definition, through = "explicit", explicit_end = "2027-01-01"), "hard temporal horizon")
})

test_that("explicit endpoint validation is strict and does not use observed_end as a ceiling", {
  definition <- portfolio_read_definition(package_file("config", "production_portfolio.yml"))
  attr(definition, "config_path") <- package_file("config", "production_portfolio.yml")
  expect_error(portfolio_resolve_plan(definition, through = "explicit", explicit_end = "2026-02-30"), "ISO")
  expect_error(portfolio_resolve_plan(definition, through = "explicit", explicit_end = "2026-7-26"), "ISO")
})

test_that("a lagging configured source constrains latest-common", {
  temp <- withr::local_tempdir()
  source_files <- file.path(temp, paste0("source-", seq_len(5), ".yml"))
  original <- portfolio_read_definition(package_file("config", "production_portfolio.yml"))
  for (i in seq_along(original$source_workflows)) {
    cfg <- yaml::read_yaml(package_file(original$source_workflows[[i]]$config))
    if (i == 4L) cfg$temporal$observed_end <- "2026-07-09"
    yaml::write_yaml(cfg, source_files[[i]])
    original$source_workflows[[i]]$config <- source_files[[i]]
  }
  original$source_workflow_ids <- vapply(original$source_workflows, `[[`, character(1), "id")
  attr(original, "config_path") <- file.path(temp, "portfolio.yml")
  plan <- portfolio_resolve_plan(original, through = "latest-common", repo_root = temp)
  expect_identical(plan$common_end, "2026-07-09")
})

test_that("portfolio synchronization reports missing and extra daily dates and weeks", {
  records <- lapply(portfolio_product_ids(), function(id) list(
    product_id = id,
    daily_dates = as.character(as.Date("2026-07-06") + c(0:4, 6)),
    weekly_ids = c("2026-W28", "2026-W29")
  ))
  result <- portfolio_validate_synchronization(records, "2026-07-06", "2026-07-12")
  expect_identical(result$status, "failed")
  expect_true(all(vapply(result$products, function(x) "2026-07-11" %in% x$daily_missing, logical(1))))
  expect_true(all(vapply(result$products, function(x) "2026-W29" %in% x$weekly_extra, logical(1))))
})

test_that("portfolio synchronization validates cumulative inventory separately from incremental work", {
  inventory_start <- as.Date("2022-01-01")
  inventory_end <- as.Date("2026-07-26")
  daily <- safe_date_sequence(inventory_start, inventory_end)
  weeks <- portfolio_complete_iso_weeks(inventory_start, inventory_end)
  records <- lapply(portfolio_product_ids(), function(id) list(product_id=id,
    daily_dates=as.character(daily), weekly_ids=weeks))
  result <- portfolio_validate_synchronization(records, "2026-07-13", "2026-07-26", inventory_start, inventory_end)
  expect_identical(result$status, "success")
  expect_identical(result$incremental_work_start, "2026-07-13")
  expect_identical(result$portfolio_inventory_start, "2022-01-01")
  expect_identical(result$portfolio_inventory_end, "2026-07-26")
  expect_equal(result$complete_iso_week_count, length(weeks))
  expect_true(all(vapply(result$products, function(x) length(x$daily_extra) == 0L && length(x$weekly_extra) == 0L, logical(1))))
  expect_true(all(vapply(result$products, function(x) x$incremental_daily_present == 14L, logical(1))))
})

test_that("portfolio cumulative validation reports only true extras and historical gaps", {
  inventory_start <- as.Date("2022-01-01")
  inventory_end <- as.Date("2026-07-26")
  daily <- safe_date_sequence(inventory_start, inventory_end)
  weeks <- portfolio_complete_iso_weeks(inventory_start, inventory_end)
  base_records <- function(dates=daily, week_ids=weeks) lapply(portfolio_product_ids(), function(id) list(product_id=id,
    daily_dates=as.character(dates), weekly_ids=week_ids))

  extra <- portfolio_validate_synchronization(base_records(c(daily, as.Date("2026-07-27"))), "2026-07-13", "2026-07-26", inventory_start, inventory_end)
  expect_identical(extra$status, "failed")
  expect_true(all(vapply(extra$products, function(x) identical(x$daily_extra, "2026-07-27"), logical(1))))

  missing_day <- portfolio_validate_synchronization(base_records(daily[-match(as.Date("2022-05-10"), daily)]), "2026-07-13", "2026-07-26", inventory_start, inventory_end)
  expect_identical(missing_day$status, "failed")
  expect_true(all(vapply(missing_day$products, function(x) identical(x$daily_missing, "2022-05-10"), logical(1))))
  expect_true(all(vapply(missing_day$products, function(x) length(x$daily_extra) == 0L, logical(1))))

  missing_week <- portfolio_validate_synchronization(base_records(daily, weeks[-1L]), "2026-07-13", "2026-07-26", inventory_start, inventory_end)
  expect_identical(missing_week$status, "failed")
  expect_true(all(vapply(missing_week$products, function(x) length(x$weekly_missing) == 1L, logical(1))))
  expect_true(all(vapply(missing_week$products, function(x) length(x$weekly_extra) == 0L, logical(1))))
})

test_that("final portfolio validation uses the cumulative inventory scope for a one-day rerun", {
  definition_path <- package_file("config", "production_portfolio.yml")
  definition <- portfolio_read_definition(definition_path)
  attr(definition, "config_path") <- definition_path
  output_root <- withr::local_tempdir()
  plan <- portfolio_resolve_plan(definition, through = "explicit", explicit_end = "2026-07-26", output_root = output_root)
  expect_identical(plan$incremental_work_start, "2022-01-01")
  plan$common_start <- "2026-07-26"
  plan$incremental_work_start <- "2026-07-26"
  plan$incremental_work_end <- "2026-07-26"
  expect_identical(plan$portfolio_inventory_start, "2022-01-01")
  expect_identical(plan$portfolio_inventory_end, "2026-07-26")
  expect_equal(plan$cumulative_complete_iso_week_count, 238L)

  result <- portfolio_validate_output_root(plan, output_root, repo_root = package_root())
  expect_identical(result$status, "failed")
  expect_identical(result$portfolio_inventory_start, "2022-01-01")
  expect_identical(result$portfolio_inventory_end, "2026-07-26")
  expect_equal(result$complete_iso_week_count, 238L)
  expect_false(any(vapply(result$products, function(x) grepl("object 'inventory_start' not found", x$failure_message %||% "", fixed = TRUE), logical(1))))
})

test_that("portfolio wrapper exposes read-only plan and dependency structure", {
  script <- paste(readLines(package_file("hpc", "submit_all_products.sh"), warn = FALSE), collapse = "\n")
  expect_true(grepl("--through latest-common|YYYY-MM-DD", script, fixed = TRUE))
  expect_match(script, "MODE=\\\"plan\\\"")
  expect_match(script, "production outputs modified: false")
  expect_match(script, "source_dependency_ids")
  expect_match(script, "--dependency=\\\"\\$dependency\\\"")
  expect_match(script, "afterok:")
  expect_match(script, "run_portfolio_validate.slurm")
  expect_true(grepl('validation_job="$(sbatch --parsable --dependency="$aggregation_dependency"', script, fixed = TRUE))
})

test_that("explicit plan provenance distinguishes known and requested endpoints", {
  definition <- portfolio_read_definition(package_file("config", "production_portfolio.yml"))
  attr(definition, "config_path") <- package_file("config", "production_portfolio.yml")
  latest <- portfolio_resolve_plan(definition, through = "latest-common")
  explicit <- portfolio_resolve_plan(definition, through = "explicit", explicit_end = "2026-07-27")
  expect_identical(latest$common_end, "2026-07-26")
  expect_identical(latest$endpoint_policy, "latest-common")
  expect_identical(latest$effective_requested_end, "2026-07-26")
  expect_identical(explicit$common_end, "2026-07-27")
  expect_true(all(explicit$availability$known_observed_end < explicit$effective_requested_end))
  expect_true(all(explicit$availability$availability_status == "unverified explicit target"))
})

test_that("portfolio planning is side-effect free", {
  definition_path <- package_file("config", "production_portfolio.yml")
  definition <- portfolio_read_definition(definition_path)
  attr(definition, "config_path") <- definition_path
  before <- unname(tools::md5sum(definition_path))
  plan <- portfolio_resolve_plan(definition, through = "explicit", explicit_end = "2026-07-27")
  expect_identical(plan$common_end, "2026-07-27")
  expect_identical(unname(tools::md5sum(definition_path)), before)
})

test_that("portfolio manifest records explicit endpoint provenance and source outcomes", {
  definition <- portfolio_read_definition(package_file("config", "production_portfolio.yml"))
  attr(definition, "config_path") <- package_file("config", "production_portfolio.yml")
  plan <- portfolio_resolve_plan(definition, through = "explicit", explicit_end = "2026-07-27")
  manifest <- portfolio_new_manifest(plan, withr::local_tempdir(), run_id = "test_portfolio")
  expect_identical(manifest$endpoint_policy, "explicit")
  expect_identical(manifest$requested_end, "2026-07-27")
  expect_identical(manifest$effective_requested_end, "2026-07-27")
  expect_identical(manifest$known_observed_end$era5_mintemp, "2026-07-26")
  expect_identical(manifest$availability_status$era5_mintemp, "unverified explicit target")
  expect_identical(manifest$incremental_work_start, "2022-01-01")
  expect_identical(manifest$portfolio_inventory_start, "2022-01-01")
  expect_identical(manifest$portfolio_inventory_end, "2026-07-27")
  expect_true("source_job_outcomes" %in% names(manifest))
})

test_that("portfolio source commands use each wrapper's full execution path", {
  script <- paste(readLines(package_file("hpc", "submit_all_products.sh"), warn = FALSE), collapse = "\n")
  definition <- portfolio_read_definition(package_file("config", "production_portfolio.yml"))
  standalone_wrappers <- c(
    "submit_era5_mintemp.sh",
    "submit_era5_soilmoist.sh",
    "submit_era5_lai_low.sh",
    "submit_agera5_relhum_min.sh"
  )
  for (wrapper in standalone_wrappers) {
    wrapper_script <- paste(readLines(package_file("hpc", wrapper), warn = FALSE), collapse = "\n")
    expect_match(wrapper_script, "run_era5_variable.slurm")
    expect_match(wrapper_script, "submit_era5_variable.sh")
  }
  expect_match(script, "MODE=full DRY_RUN=false")
  expect_false(grepl("MODE=process", script, fixed = TRUE))
  expect_false(grepl("run_portfolio_era5_variable_daily.slurm", script, fixed = TRUE))
  expect_identical(definition$source_workflows[[5]]$wrapper, "hpc/submit_era5land_daily_mean.sh")
  expect_match(script, "run_era5land_daily_mean.slurm")
  expect_match(script, "--execute")
})

test_that("ERA5-Land aggregation preserves the complete product family through Slurm export", {
  definition <- portfolio_read_definition(package_file("config", "production_portfolio.yml"))
  family <- definition$source_workflows[[5L]]
  expect_identical(family$id, "era5land_daily_mean_utc06")
  expect_identical(family$products, era5land_family_product_ids())
  script <- paste(readLines(package_file("hpc", "submit_all_products.sh"), warn = FALSE), collapse = "\n")
  expect_true(grepl('PRODUCT_IDS="$products" START_DATE=', script, fixed = TRUE))
  expect_true(grepl('--export=ALL "$REPO_DIR/hpc/run_portfolio_aggregate_era5land.slurm"', script, fixed = TRUE))
  expect_false(grepl('--export=ALL,REPO_DIR,CONFIG="$config",PRODUCT_IDS="$products"', script, fixed = TRUE))
})

test_that("portfolio validation exposes exact missing daily and weekly sidecars", {
  definition_path <- package_file("config", "production_portfolio.yml")
  definition <- portfolio_read_definition(definition_path)
  attr(definition, "config_path") <- definition_path
  output_root <- withr::local_tempdir()
  plan <- portfolio_resolve_plan(definition, through = "explicit", explicit_end = "2026-07-26", output_root = output_root)
  plan$products <- list(plan$products[[which(vapply(plan$products, function(x) identical(x$product_id, "era5_mintemp"), logical(1)))[[1L]]]])
  plan$portfolio_inventory_start <- "2026-07-20"
  plan$portfolio_inventory_end <- "2026-07-26"
  plan$cumulative_complete_iso_weeks <- "2026-W30"

  spec <- get_variable_spec("era5_mintemp")
  daily_dir <- file.path(output_root, "data", "production", "era5_mintemp", "daily")
  weekly_dir <- file.path(output_root, "data", "production", "era5_mintemp", "weekly")
  dir.create(daily_dir, recursive = TRUE)
  dir.create(weekly_dir, recursive = TRUE)
  daily_paths <- file.path(daily_dir, vapply(as.Date("2026-07-20") + 0:6,
    function(date) daily_output_filename(spec, date), character(1)))
  weekly_path <- file.path(weekly_dir, weekly_output_filename(spec, 2026L, 30L))
  for (path in daily_paths[-7L]) jsonlite::write_json(list(valid = TRUE), paste0(path, ".json"), auto_unbox = TRUE)

  result <- portfolio_validate_output_root(plan, output_root, repo_root = package_root())
  product <- result$products[[1L]]
  expect_identical(product$daily_sidecars_missing, paste0(daily_paths[[7L]], ".json"))
  expect_identical(product$weekly_sidecars_missing, paste0(weekly_path, ".json"))
  expect_identical(product$daily_sidecars_invalid, character())
  expect_identical(product$weekly_sidecars_invalid, character())
})

test_that("portfolio sidecar diagnostics distinguish complete and invalid sidecars", {
  temp <- withr::local_tempdir()
  paths <- file.path(temp, c("daily.tif", "weekly.tif"))
  jsonlite::write_json(list(valid = TRUE), paste0(paths[[1L]], ".json"), auto_unbox = TRUE)
  jsonlite::write_json(list(valid = TRUE), paste0(paths[[2L]], ".json"), auto_unbox = TRUE)
  complete <- portfolio_sidecar_diagnostics(paths)
  expect_true(complete$valid)
  expect_identical(complete$missing, character())
  expect_identical(complete$invalid, character())

  writeLines("not-json", paste0(paths[[2L]], ".json"))
  invalid <- portfolio_sidecar_diagnostics(paths)
  expect_false(invalid$valid)
  expect_identical(invalid$invalid, paste0(paths[[2L]], ".json"))
})

test_that("portfolio updates do not request overwrite", {
  scripts <- vapply(c("submit_all_products.sh", "run_portfolio_aggregate_product.slurm", "run_portfolio_aggregate_era5land.slurm"), function(x) paste(readLines(package_file("hpc", x), warn = FALSE), collapse = "\n"), character(1))
  expect_false(any(grepl("--overwrite", scripts, fixed = TRUE)))
})

test_that("portfolio Slurm state classification distinguishes submitted, running, failed, and cancelled", {
  expect_identical(portfolio_classify_job_state("PENDING"), "submitted")
  expect_identical(portfolio_classify_job_state("RUNNING"), "running")
  expect_identical(portfolio_classify_job_state("FAILED"), "failed")
  expect_identical(portfolio_classify_job_state("CANCELLED+"), "cancelled")
  expect_identical(portfolio_classify_job_state("COMPLETED"), "success")
})

test_that("cancelled validator reconciliation records failed dependency chains", {
  manifest <- list(
    status = "validation_submitted",
    source_job_ids = list(era5_mintemp = "101"),
    aggregation_job_ids = list(era5_mintemp = "201"),
    validation_job_id = "301",
    completed_at = NULL
  )
  states <- c("101" = "FAILED", "201" = "CANCELLED", "301" = "CANCELLED+DEPENDENCY_NEVER_SATISFIED")
  result <- portfolio_reconcile_manifest(manifest, states)
  expect_true(result$changed)
  expect_identical(result$manifest$status, "cancelled")
  expect_identical(result$manifest$failure_stage, "source")
  expect_match(result$manifest$failure_message, "source job era5_mintemp")
  expect_true(nzchar(result$manifest$completed_at))
  expect_identical(result$manifest$scheduler_states[["301"]]$state_class, "cancelled")
})

test_that("validation submission becomes running only after Slurm starts it", {
  manifest <- list(status = "validation_submitted", validation_job_id = "301")
  result <- portfolio_reconcile_manifest(manifest, c("301" = "RUNNING"))
  expect_true(result$changed)
  expect_identical(result$manifest$status, "validation_running")
  expect_null(result$manifest$completed_at)
})

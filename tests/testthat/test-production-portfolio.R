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
  expect_identical(plan$common_end, "2026-07-12")
  expect_length(plan$availability$source_workflow, 5)
})

test_that("explicit endpoint is resolved identically for all source children", {
  definition <- portfolio_read_definition(package_file("config", "production_portfolio.yml"))
  attr(definition, "config_path") <- package_file("config", "production_portfolio.yml")
  plan <- portfolio_resolve_plan(definition, through = "explicit", explicit_end = "2026-07-10")
  expect_identical(plan$common_end, "2026-07-10")
  expect_true(all(vapply(plan$source_workflows, function(x) plan$common_end == "2026-07-10", logical(1))))
  expect_error(portfolio_resolve_plan(definition, through = "explicit", explicit_end = "2026-07-13"), "unsupported")
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

test_that("portfolio wrapper exposes read-only plan and dependency structure", {
  script <- paste(readLines(package_file("hpc", "submit_all_products.sh"), warn = FALSE), collapse = "\n")
  expect_true(grepl("--through latest-common|YYYY-MM-DD", script, fixed = TRUE))
  expect_match(script, "MODE=\\\"plan\\\"")
  expect_match(script, "production outputs modified: false")
  expect_match(script, "source_dependency_ids")
  expect_match(script, "--dependency=\\\"\\$dependency\\\"")
  expect_match(script, "afterok:")
  expect_match(script, "run_portfolio_validate.slurm")
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

test_that("portfolio updates do not request overwrite", {
  scripts <- vapply(c("submit_all_products.sh", "run_portfolio_aggregate_product.slurm", "run_portfolio_aggregate_era5land.slurm"), function(x) paste(readLines(package_file("hpc", x), warn = FALSE), collapse = "\n"), character(1))
  expect_false(any(grepl("--overwrite", scripts, fixed = TRUE)))
})

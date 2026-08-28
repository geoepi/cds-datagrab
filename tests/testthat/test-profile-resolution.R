profile_test_bash <- function() {
  bash <- Sys.which("bash")
  if (!nzchar(bash) && identical(.Platform$OS.type, "windows")) {
    candidate <- file.path(Sys.getenv("ProgramFiles", "C:/Program Files"), "Git", "bin", "bash.exe")
    if (file.exists(candidate)) bash <- candidate
  }
  if (!nzchar(bash) || !file.exists(bash)) testthat::skip("bash is not available for shell-level profile tests")
  bash
}

profile_test_bash_path <- function(path) {
  path <- normalizePath(path, winslash = "/", mustWork = FALSE)
  if (identical(.Platform$OS.type, "windows") && grepl("^[A-Za-z]:/", path)) {
    paste0("/", tolower(substr(path, 1L, 1L)), substring(path, 3L))
  } else path
}

profile_test_quote <- function(value) shQuote(as.character(value), type = "sh")

run_profile_environment <- function(config, profile = NULL, absolute = FALSE) {
  bash <- profile_test_bash()
  repo <- profile_test_bash_path(package_root())
  config_value <- if (absolute) profile_test_bash_path(config) else config
  root <- paste0("/tmp/cds-datagrab-profile-test-", Sys.getpid(), "-", sample.int(1e6, 1L))
  r_bin <- profile_test_bash_path(R.home("bin"))
  profile_assignment <- if (is.null(profile)) "unset PROFILE" else paste0("PROFILE=", profile_test_quote(profile), "; export PROFILE")
  script <- paste(
    "set -euo pipefail",
    paste0("export PATH=/usr/bin:/bin:", profile_test_quote(r_bin), ":", profile_test_quote(dirname(r_bin)), ":$PATH"),
    paste0("REPO_DIR=", profile_test_quote(repo)),
    paste0("CONFIG=", profile_test_quote(config_value)),
    paste0("CDS_DATAGRAB_ROOT=", profile_test_quote(root)),
    "CDS_DATAGRAB_R_LIB=/tmp/cds-datagrab-test-r-library",
    "export REPO_DIR CONFIG CDS_DATAGRAB_ROOT CDS_DATAGRAB_R_LIB",
    profile_assignment,
    "source \"$REPO_DIR/hpc/lib/cds_datagrab_env.sh\"",
    "cds_datagrab_prepare_environment",
    "printf 'profile=%s\\nconfig=%s\\n' \"$PROFILE\" \"$CONFIG\"",
    sep = "; "
  )
  script_file <- tempfile("profile-runner-", tmpdir = package_root(), fileext = ".sh")
  writeLines(script, script_file)
  withr::defer(unlink(script_file, force = TRUE))
  system2(bash, script_file, stdout = TRUE, stderr = TRUE)
}

test_that("all tracked YAML configurations use project.profile and both YAML styles are present", {
  files <- list.files(package_file("config"), pattern = "[.]ya?ml$", full.names = TRUE)
  configs <- lapply(files, yaml::read_yaml)
  profiles <- vapply(configs, function(x) {
    if (is.null(x$project$profile)) NA_character_ else as.character(x$project$profile)
  }, character(1))
  expect_true(all(profiles %in% c("smoke", "production")))
  expect_true(all(vapply(configs, function(x) !is.null(x$project$profile), logical(1))))
  text <- vapply(files, function(x) paste(readLines(x, warn = FALSE), collapse = "\n"), character(1))
  expect_true(any(grepl("(?m)^project:[[:space:]]*\\{", text, perl = TRUE)))
  expect_true(any(grepl("(?m)^project:[[:space:]]*$", text, perl = TRUE)))
})
test_that("structured profile resolution handles family configs, paths, normalization, and misleading filenames", {
  smoke <- package_file("config", "era5land_daily_mean_utc06_smoke.yml")
  weekly <- package_file("config", "era5land_daily_mean_utc06_weekly_smoke.yml")
  production <- package_file("config", "era5land_daily_mean_utc06_production.yml")
  expect_match(paste(run_profile_environment("config/era5land_daily_mean_utc06_smoke.yml"), collapse = "\n"), "profile=smoke")
  expect_match(paste(run_profile_environment(weekly, absolute = TRUE), collapse = "\n"), "profile=smoke")
  expect_match(paste(run_profile_environment(production, profile = "production", absolute = TRUE), collapse = "\n"), "profile=production")

  block <- tempfile("profile-block-", tmpdir = package_root(), fileext = "-production.yml")
  inline <- tempfile("profile-inline-smoke-", tmpdir = package_root(), fileext = ".yml")
  misleading_smoke <- tempfile("filename-smoke-", tmpdir = package_root(), fileext = "-production.yml")
  misleading_production <- tempfile("filename-production-", tmpdir = package_root(), fileext = "-smoke.yml")
  withr::defer(unlink(c(block, inline, misleading_smoke, misleading_production), force = TRUE))
  writeLines(c("project:", "  profile: '  PrOdUcTiOn  '", "  dataset_id: test"), block)
  writeLines("project: {profile: ' SmOkE ', dataset_id: test}", inline)
  writeLines("project: {profile: production, dataset_id: test}", misleading_smoke)
  writeLines("project: {profile: smoke, dataset_id: test}", misleading_production)
  expect_match(paste(run_profile_environment(block, absolute = TRUE), collapse = "\n"), "profile=production")
  expect_match(paste(run_profile_environment(inline, absolute = TRUE), collapse = "\n"), "profile=smoke")
  expect_match(paste(run_profile_environment(misleading_smoke, absolute = TRUE), collapse = "\n"), "profile=production")
  expect_match(paste(run_profile_environment(misleading_production, absolute = TRUE), collapse = "\n"), "profile=smoke")
})
test_that("explicit profile conflicts and malformed profiles fail clearly", {
  smoke <- package_file("config", "era5land_daily_mean_utc06_smoke.yml")
  production <- package_file("config", "era5land_daily_mean_utc06_production.yml")
  conflict <- suppressWarnings(run_profile_environment(smoke, profile = "production", absolute = TRUE))
  expect_true(length(attr(conflict, "status")) == 1L)
  expect_match(paste(conflict, collapse = "\n"), "PROFILE='production'.*configuration profile='smoke'.*era5land_daily_mean_utc06_smoke", perl = TRUE)
  conflict <- suppressWarnings(run_profile_environment(production, profile = " smoke ", absolute = TRUE))
  expect_true(length(attr(conflict, "status")) == 1L)
  expect_match(paste(conflict, collapse = "\n"), "PROFILE=' smoke '.+configuration profile='production'", perl = TRUE)

  missing <- tempfile("profile-missing-", tmpdir = package_root(), fileext = ".yml")
  unsupported <- tempfile("profile-unsupported-", tmpdir = package_root(), fileext = ".yml")
  withr::defer(unlink(c(missing, unsupported), force = TRUE))
  writeLines(c("project:", "  dataset_id: test"), missing)
  writeLines("project: {profile: development, dataset_id: test}", unsupported)
  missing_result <- suppressWarnings(run_profile_environment(missing, absolute = TRUE))
  unsupported_result <- suppressWarnings(run_profile_environment(unsupported, absolute = TRUE))
  expect_true(length(attr(missing_result, "status")) == 1L)
  expect_true(length(attr(unsupported_result, "status")) == 1L)
  expect_match(paste(missing_result, collapse = "\n"), "Could not resolve project.profile")
  expect_match(paste(unsupported_result, collapse = "\n"), "Unsupported configuration profile")
})

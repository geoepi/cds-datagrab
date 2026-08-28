era5land_submit_cli_bash <- function() {
  bash <- Sys.which("bash")
  if (!nzchar(bash) && identical(.Platform$OS.type, "windows")) {
    candidate <- file.path(Sys.getenv("ProgramFiles", "C:/Program Files"), "Git", "bin", "bash.exe")
    if (file.exists(candidate)) bash <- candidate
  }
  if (!nzchar(bash) || !file.exists(bash)) testthat::skip("bash is not available for shell-level CLI tests")
  bash
}

era5land_submit_cli_bash_path <- function(path) {
  path <- normalizePath(path, winslash = "/", mustWork = FALSE)
  if (identical(.Platform$OS.type, "windows") && grepl("^[A-Za-z]:/", path)) {
    paste0("/", tolower(substr(path, 1L, 1L)), substring(path, 3L))
  } else path
}

era5land_submit_cli_quote <- function(value) shQuote(as.character(value), type = "sh")

era5land_submit_cli_stub_rscript <- function(directory) {
  path <- file.path(directory, "Rscript")
  writeLines(c(
    "#!/usr/bin/env bash",
    "set -euo pipefail",
    "if [[ \" $* \" == *\" - \"* ]]; then echo smoke; exit 0; fi",
    "if [[ \"$*\" == *plan_era5land_daily_mean.R* ]]; then",
    "  cat <<'EOF'",
    "CONFIG=weekly-config",
    "PROFILE=smoke",
    "OUTPUT_ROOT=planned-root",
    "START_DATE=2026-02-02",
    "END_DATE=2026-02-08",
    "PRODUCT_COUNT=8",
    "PRODUCTS=era5land_tmean,era5land_soiltemp_l1_mean,era5land_soiltemp_l2_mean,era5land_soilwater_l1_mean,era5land_soilwater_l2_mean,era5land_surface_pressure_mean,era5land_lai_high_mean,era5land_lai_low_mean",
    "DAILY_EXPECTED=56",
    "COMPLETE_WEEKS=1",
    "WEEKLY_EXPECTED=8",
    "SOURCE_REQUEST_COUNT=1",
    "REQUEST_HASHES=016f79fb",
    "REQUEST_1=hash=016f79fb;start=2026-02-02;end=2026-02-08;days=2026-02-02,2026-02-03,2026-02-04,2026-02-05,2026-02-06,2026-02-07,2026-02-08",
    "EOF",
    "  exit 0",
    "fi",
    "exit 0"
  ), path)
  Sys.chmod(path, "0755")
  path
}

era5land_submit_cli_stub_sbatch <- function(directory) {
  path <- file.path(directory, "sbatch")
  writeLines(c(
    "#!/usr/bin/env bash",
    "set -euo pipefail",
    "if [[ -n \"${MOCK_SBATCH_LOG:-}\" ]]; then printf '%s\\n' \"$*\" > \"$MOCK_SBATCH_LOG\"; fi",
    "echo 98765"
  ), path)
  Sys.chmod(path, "0755")
  path
}

era5land_submit_cli_run <- function(arguments, mock_sbatch = FALSE) {
  bash <- era5land_submit_cli_bash()
  repo <- era5land_submit_cli_bash_path(package_root())
  mock_bin <- tempfile("era5land-cli-mock-", tmpdir = package_root())
  dir.create(mock_bin)
  withr::defer(unlink(mock_bin, recursive = TRUE, force = TRUE))
  era5land_submit_cli_stub_rscript(mock_bin)
  log_path <- file.path(mock_bin, "sbatch.log")
  if (mock_sbatch) era5land_submit_cli_stub_sbatch(mock_bin)
  root <- paste0("/tmp/cds datagrab cli ", Sys.getpid(), "-", sample.int(1e6, 1L))
  script <- paste(
    "set -euo pipefail",
    paste0("export PATH=", era5land_submit_cli_quote(era5land_submit_cli_bash_path(mock_bin)), ":/usr/bin:/bin:$PATH"),
    paste0("export REPO_DIR=", era5land_submit_cli_quote(repo)),
    paste0("export CDS_DATAGRAB_R_LIB=", era5land_submit_cli_quote(file.path("/tmp", "cds-datagrab-test-r-library"))),
    paste0("export MOCK_SBATCH_LOG=", era5land_submit_cli_quote(era5land_submit_cli_bash_path(log_path))),
    paste0("bash \"$REPO_DIR/hpc/submit_era5land_daily_mean.sh\" ", paste(vapply(arguments, era5land_submit_cli_quote, character(1)), collapse = " ")),
    sep = "; "
  )
  script_file <- tempfile("era5land-cli-runner-", tmpdir = package_root(), fileext = ".sh")
  writeLines(script, script_file)
  withr::defer(unlink(script_file, force = TRUE))
  result <- system2(bash, script_file, stdout = TRUE, stderr = TRUE)
  sbatch_log <- if (file.exists(log_path)) readLines(log_path, warn = FALSE) else character()
  list(output = result, status = attr(result, "status"), root = root, sbatch_log = sbatch_log)
}

test_that("ERA5-Land submission CLI enforces the named interface and renders the weekly plan", {
  weekly <- "config/era5land_daily_mean_utc06_weekly_smoke.yml"
  dry <- era5land_submit_cli_run(c("--config", weekly, "--output-root", "/tmp/cds datagrab explicit root", "--dry-run", "--overwrite", "--rebuild-all-weeks"))
  text <- paste(dry$output, collapse = "\n")
  expect_null(dry$status)
  expect_match(text, "configuration: .+era5land_daily_mean_utc06_weekly_smoke.yml")
  expect_match(text, "execution mode: dry-run")
  expect_match(text, "effective dates: 2026-02-02 through 2026-02-08")
  expect_match(text, "products \\(8\\): era5land_tmean")
  expect_match(text, "daily outputs expected: 56")
  expect_match(text, "complete ISO weeks: 1")
  expect_match(text, "weekly outputs expected: 8")
  expect_match(text, "source request count: 1")
  expect_match(text, "--mode plan")
  expect_match(text, "--overwrite")
  expect_match(text, "--rebuild-all-weeks")
  expect_match(text, "CDS contacted: false")
  expect_match(text, "Slurm job submitted: false")
  expect_length(dry$sbatch_log, 0L)

  executed <- era5land_submit_cli_run(c("--config", weekly, "--output-root", "/tmp/cds datagrab execute root", "--execute"), mock_sbatch = TRUE)
  executed_text <- paste(executed$output, collapse = "\n")
  expect_null(executed$status)
  expect_match(executed_text, "execution mode: execute")
  expect_match(executed_text, "--mode full")
  expect_match(executed_text, "submitted job ID: 98765")
  expect_length(executed$sbatch_log, 1L)
  expect_match(paste(executed$sbatch_log, collapse = "\n"), "run_era5land_daily_mean[.]slurm")

  for (mode in c("stage-requests", "retrieve-requests", "process")) {
    routed <- era5land_submit_cli_run(c("--config", weekly, "--output-root", paste0("/tmp/cds datagrab ", mode), paste0("--", mode)), mock_sbatch = TRUE)
    routed_text <- paste(routed$output, collapse = "\n")
    expect_null(routed$status)
    expect_match(routed_text, paste0("--mode ", mode))
    expect_match(paste(routed$sbatch_log, collapse = "\n"), paste0("run_era5land_daily_mean_", sub("-requests", "", mode), "[.]slurm"))
  }

  for (bad in list(
    c("--dry-run", "--execute"),
    c("--dry-run", "--unknown"),
    c("--config"),
    character()
  )) {
    result <- suppressWarnings(era5land_submit_cli_run(bad))
    expect_true(length(result$status) == 1L)
  }
})

test_that("ERA5-Land submission inventory is family-scoped", {
  script <- paste(readLines(package_file("hpc", "submit_era5land_daily_mean.sh"), warn = FALSE), collapse = "\n")
  expect_match(script, "era5land_inventory_counts")
  expect_match(script, "data/\\$PROFILE/\\$product/daily")
  expect_false(grepl("era5_mintemp", script, fixed = TRUE))
})

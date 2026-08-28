era5land_lifecycle_execution <- function(product_id, status = "success", failure_stage = NULL, failure_message = NULL, reused = FALSE) {
  result <- list(
    product_id = product_id,
    status = status,
    successful_dates = if (identical(status, "success")) as.character(as.Date("2026-02-02") + 0:6) else character(),
    failed_dates = if (identical(status, "success")) character() else "2026-02-04",
    daily_outputs_written = if (reused) 0L else 7L,
    daily_outputs_reused = if (reused) 7L else 0L,
    weekly = list(status = "success", reused = reused),
    raw_reused = reused,
    CDS_contacted = FALSE,
    coverage_metrics_source = if (reused) "existing_output_metadata" else "recomputed"
  )
  if (!is.null(failure_stage)) {
    result$failure_stage <- failure_stage
    result$failure_message <- failure_message
  }
  list(result = result, failure = if (identical(status, "success")) NULL else result)
}

era5land_collect_lifecycle_fixture <- function(executions) {
  state <- list(results = list(), failures = list())
  for (product_id in names(executions)) {
    collected <- cdsdatagrab:::era5land_collect_product_execution(
      state$results,
      state$failures,
      product_id,
      executions[[product_id]]
    )
    state$results <- collected$results
    state$failures <- collected$failures
    state$collection_error <- c(if (is.null(state$collection_error)) list() else state$collection_error, list(collected$collection_error))
  }
  state$status <- cdsdatagrab:::era5land_family_status(state$results, state$failures)
  state
}

test_that("successful complete-week results are retained and status is success", {
  state <- era5land_collect_lifecycle_fixture(list(
    era5land_tmean = era5land_lifecycle_execution("era5land_tmean"),
    era5land_soiltemp_l1_mean = era5land_lifecycle_execution("era5land_soiltemp_l1_mean")
  ))
  expect_identical(state$status, "success")
  expect_length(state$results, 2L)
  expect_length(state$failures, 0L)
  expect_true(all(vapply(state$results, function(x) identical(x$status, "success") && identical(x$weekly$status, "success"), logical(1))))
  expect_true(all(vapply(state$collection_error, is.null, logical(1))))
  expect_false(any(grepl("object '(results|failures)' not found", capture.output(str(state)), perl = TRUE)))
})

test_that("complete reuse retains reuse metrics and succeeds without CDS", {
  state <- era5land_collect_lifecycle_fixture(list(
    era5land_tmean = era5land_lifecycle_execution("era5land_tmean", reused = TRUE),
    era5land_soiltemp_l1_mean = era5land_lifecycle_execution("era5land_soiltemp_l1_mean", reused = TRUE)
  ))
  expect_identical(state$status, "success")
  expect_length(state$failures, 0L)
  expect_true(all(vapply(state$results, function(x) x$daily_outputs_written == 0L && x$daily_outputs_reused == 7L && isTRUE(x$raw_reused) && isFALSE(x$CDS_contacted), logical(1))))
  expect_true(all(vapply(state$results, function(x) identical(x$coverage_metrics_source, "existing_output_metadata"), logical(1))))
})

test_that("mixed outcomes retain the original failure and are partial_failure", {
  state <- era5land_collect_lifecycle_fixture(list(
    era5land_tmean = era5land_lifecycle_execution("era5land_tmean"),
    era5land_soiltemp_l1_mean = era5land_lifecycle_execution("era5land_soiltemp_l1_mean", "failed", "process", "original date processing error")
  ))
  expect_identical(state$status, "partial_failure")
  expect_identical(state$results[["era5land_tmean"]]$status, "success")
  expect_identical(state$failures[["era5land_soiltemp_l1_mean"]]$failure_stage, "process")
  expect_identical(state$failures[["era5land_soiltemp_l1_mean"]]$failure_message, "original date processing error")
  expect_true(all(vapply(state$collection_error, is.null, logical(1))))
})

test_that("total failures retain all original failures and are failed", {
  state <- era5land_collect_lifecycle_fixture(list(
    era5land_tmean = era5land_lifecycle_execution("era5land_tmean", "failed", "process", "first original error"),
    era5land_soiltemp_l1_mean = era5land_lifecycle_execution("era5land_soiltemp_l1_mean", "failed", "process", "second original error")
  ))
  expect_identical(state$status, "failed")
  expect_length(state$results, 2L)
  expect_length(state$failures, 2L)
  expect_identical(state$failures[["era5land_tmean"]]$failure_message, "first original error")
  expect_identical(state$failures[["era5land_soiltemp_l1_mean"]]$failure_message, "second original error")
  expect_true(all(vapply(state$collection_error, is.null, logical(1))))
})

test_that("family lifecycle uses ordinary collection assignment", {
  source <- paste(readLines(package_file("R", "era5land_family.R"), warn = FALSE), collapse = "\n")
  expect_false(grepl("results\\[\\[.*<<-|failures\\[\\[.*<<-", source, perl = TRUE))
  expect_match(source, "results\\[\\[product_id\\]\\] <- product_execution\\$result")
  expect_match(source, "failures\\[\\[product_id\\]\\] <- product_execution\\$failure")
  expect_false(grepl("object '(results|failures)' not found", source, fixed = FALSE))
})

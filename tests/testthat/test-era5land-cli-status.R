test_that("pending execute status fails the source job gate", {
  status_success <- cdsdatagrab:::era5land_cli_status_success

  expect_true(status_success("execute", FALSE, "success"))
  expect_true(status_success("execute", FALSE, "success_noop"))
  expect_false(status_success("execute", FALSE, "execute_pending"))
  expect_false(status_success("full", FALSE, "execute_pending"))
})

test_that("retrieval pending remains an accepted asynchronous retrieval state", {
  expect_true(cdsdatagrab:::era5land_cli_status_success("retrieve-requests", FALSE, "retrieval_pending"))
})

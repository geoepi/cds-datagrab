era5land_cli_status_success <- function(mode, dry_run, status) {
  if (mode == "plan") return(identical(status, "planned"))
  if (isTRUE(dry_run)) return(status %in% c("planned", "downloaded"))
  if (mode == "retrieve-requests") return(status %in% c("retrieved", "retrieval_pending", "success", "success_noop"))
  if (mode == "stage-requests") return(identical(status, "staged"))
  if (mode %in% c("execute", "full")) return(status %in% c("success", "success_noop"))
  status %in% c("success", "success_noop")
}

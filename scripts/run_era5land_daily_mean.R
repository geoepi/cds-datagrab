#!/usr/bin/env Rscript
args <- commandArgs(trailingOnly=TRUE)
if ("--help" %in% args) {
  cat("Usage: Rscript scripts/run_era5land_daily_mean.R [--mode plan|download|stage-requests|retrieve-requests|process|aggregate|execute|full] [--config PATH] [--output-root PATH] [--products ID[,ID...]] [--start-date YYYY-MM-DD] [--end-date YYYY-MM-DD] [--dry-run [true|false]] [--overwrite] [--rebuild-all-weeks]\n")
  quit(save="no", status=0L, runLast=FALSE)
}
value <- function(flag, default=NULL) { i <- match(flag,args); if (is.na(i)) default else if (i == length(args) || startsWith(args[[i+1L]], "--")) stop(flag, " requires a value", call.=FALSE) else args[[i+1L]] }
config <- value("--config", "config/era5land_daily_mean_utc06_smoke.yml")
mode <- value("--mode", "plan")
if ("--stage-requests" %in% args) mode <- "stage-requests"
if ("--retrieve-requests" %in% args) mode <- "retrieve-requests"
if ("--process" %in% args) mode <- "process"
if ("--execute" %in% args) mode <- "execute"
dry_index <- match("--dry-run", args)
dry_run <- if (is.na(dry_index)) "true" else if (dry_index == length(args) || startsWith(args[[dry_index + 1L]], "--")) "true" else args[[dry_index + 1L]]
start <- value("--start-date"); end <- value("--end-date"); root <- value("--output-root")
overwrite <- "--overwrite" %in% args
rebuild_all_weeks <- "--rebuild-all-weeks" %in% args
if (!mode %in% c("plan","download","stage-requests","retrieve-requests","process","aggregate","execute","full")) stop("Invalid ERA5-Land workflow mode: ", mode, call.=FALSE)
library(cdsdatagrab)
products <- value("--products", paste(era5land_family_product_ids(), collapse=","))
ids <- strsplit(products,",",fixed=TRUE)[[1L]]
dry <- tolower(dry_run) %in% c("true","1","yes")
ans <- run_era5land_daily_mean_family(config_path=config, mode=mode, dry_run=dry, start_date=start, end_date=end, output_root=root, product_ids=ids, overwrite=overwrite, rebuild_all_weeks=rebuild_all_weeks)
field <- function(x, name, default = NULL) if(!is.null(x[[name]])) x[[name]] else default
manifest <- field(ans, "manifest", list())
source <- field(ans, "source_diagnostic", list())
request_inventory <- field(ans, "request_inventory", list())
cat(sprintf("source family: era5land_daily_mean_utc06\nproducts: %s\nstatus: %s\nfamily status: %s\nrun directory: %s\nraw reused: %s\narchive members: %s\nsource map rows: %s\nrequested product-dates: %s\ndaily outputs written: %s\ndaily outputs reused: %s\nmaster-template cells: %s\nERA5-Land-supported cells: %s\nstructurally unsupported cells: %s\npre-repair missing cells: %s\npre-repair missing supported cells: %s\nrepaired supported cells: %s\npost-repair unexpected missing cells: %s\noutside-support finite cells: %s\nfailed products: %s\nfailed dates: %s\n",
  paste(ids,collapse=", "),ans$status,field(ans,"family_status",ans$status),if(is.null(ans$run_dir)) "" else ans$run_dir,
  field(source,"raw_reused",field(manifest,"raw_reused",NA)),field(source,"archive_member_count",NA),field(source,"source_map_rows",NA),
  length(field(manifest,"requested_product_dates",character())),field(manifest,"daily_outputs_written",0),field(manifest,"daily_outputs_reused",0),
  field(manifest,"master_template_cells",0),field(manifest,"era5land_supported_cells",0),field(manifest,"structurally_unsupported_cells",0),field(manifest,"pre_repair_missing_cells",0),field(manifest,"pre_repair_missing_supported_cells",0),field(manifest,"repaired_supported_cells",0),field(manifest,"post_repair_unexpected_missing_cells",0),field(manifest,"outside_support_finite_cells",0),
  paste(field(manifest,"failed_products",character()),collapse=","),paste(field(manifest,"failed_product_dates",character()),collapse=",")))
if (length(request_inventory)) cat(sprintf("source requests planned: %s\nraw archives valid: %s\nregistered pending CDS jobs: %s\nsubmitted CDS jobs: %s\nprocessing CDS jobs: %s\nfailed CDS jobs: %s\nexpired CDS jobs: %s\nnew CDS requests required: %s\nretrievals ready: %s\n",
  field(request_inventory,"source_requests_planned",0), field(request_inventory,"raw_archives_valid",0), field(request_inventory,"registered_pending_cds_jobs",0), field(request_inventory,"submitted_cds_jobs",0), field(request_inventory,"processing_cds_jobs",0), field(request_inventory,"failed_cds_jobs",0), field(request_inventory,"expired_cds_jobs",0), field(request_inventory,"new_cds_requests_required",0), field(request_inventory,"retrievals_ready",0)))
ok <- if (mode == "plan") identical(ans$status, "planned") else if (dry) ans$status %in% c("planned", "downloaded") else if (mode == "retrieve-requests") ans$status %in% c("retrieved", "retrieval_pending", "success") else if (mode == "stage-requests") ans$status == "staged" else if (mode %in% c("execute", "full")) ans$status %in% c("success", "execute_pending") else identical(ans$status,"success")
if(!ok) {
  failed <- field(manifest,"failed_product_dates",character())
  first <- field(manifest,"product_results",list())
  failed_results <- if(length(first)) Filter(function(x) identical(field(x,"status"), "failed"), first) else list()
  first_failure <- if(length(failed_results)) failed_results[[1L]] else if(length(first)) first[[1L]] else manifest
  cat(sprintf("ERA5-Land processing failed:\nproduct=%s\ndate=%s\nstage=%s\nmessage=%s\nfailed_product_dates=%d\n",
    field(first_failure,"product_id",NA_character_), field(first_failure,"failed_dates",NA_character_)[1L], field(first_failure,"failure_stage",field(manifest,"failure_stage",NA_character_)),
    field(first_failure,"failure_message",field(manifest,"failure_message",ans$status)), length(failed)), file=stderr())
  quit(save="no",status=1L,runLast=FALSE)
}
